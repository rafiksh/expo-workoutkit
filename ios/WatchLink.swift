import ExpoModulesCore
import Foundation
import HealthKit
import UIKit
import WatchConnectivity

// The phone's half of the Paceo watch link (monorepo docs/plans/apple-watch.md).
//
//   Live leg   HKWorkoutSession mirroring (iOS 17): the watch owns the
//              session and mirrors it here; it sends {"snapshot": session}
//              on every change, we send {"command": cmd} or {"hello": true}.
//   Everything else  WatchConnectivity: the plan cache out (application
//              context), thumbnails out (files), finished sessions in
//              (user info), acks out.
//
// Both handlers must exist before the system delivers anything, which can
// be at a background launch with no JS running, so this starts from the
// app delegate (WatchLinkAppDelegate) and buffers what it receives: the
// finished-session inbox lives on disk until JS saves and acks each one.
final class WatchLink: NSObject {
  static let shared = WatchLink()

  let store = HKHealthStore()
  private(set) var mirrored: HKWorkoutSession?
  /// The watch's latest session JSON while mirrored.
  private(set) var lastSnapshot: String?

  var onSnapshot: ((String) -> Void)?
  var onMirror: ((Bool) -> Void)?
  var onFinished: (() -> Void)?

  private let queue = DispatchQueue(label: "co.paceo.watchlink")

  func start() {
    if WCSession.isSupported() {
      WCSession.default.delegate = self
      WCSession.default.activate()
    }
    if #available(iOS 17.0, *) {
      store.workoutSessionMirroringStartHandler = { [weak self] session in
        self?.adoptMirror(session)
      }
    }
  }

  // MARK: status

  var status: [String: Any] {
    guard WCSession.isSupported() else { return ["supported": false] }
    let s = WCSession.default
    let active = s.activationState == .activated
    return [
      "supported": true,
      "paired": active && s.isPaired,
      "installed": active && s.isWatchAppInstalled,
      "reachable": active && s.isReachable,
      "mirroring": mirrored != nil,
    ]
  }

  // MARK: out

  /// Replaces the watch's plan cache. Latest wins, delivered when the watch wakes.
  func sendPlan(_ json: String) throws {
    guard WCSession.default.activationState == .activated, WCSession.default.isPaired else { return }
    try WCSession.default.updateApplicationContext(["plan": Data(json.utf8)])
  }

  /// A downsized exercise photo, keyed by exercise (exerciseId ?? name).
  func sendPoster(fileUri: String, key: String) {
    guard WCSession.default.activationState == .activated, WCSession.default.isWatchAppInstalled,
          let url = URL(string: fileUri) ?? Optional(URL(fileURLWithPath: fileUri)) else { return }
    WCSession.default.transferFile(url, metadata: ["posterKey": key])
  }

  /// Sends a SessionCommand (JSON) to the watch over the mirrored session.
  func sendCommand(_ json: String) -> Bool {
    guard #available(iOS 17.0, *), let session = mirrored,
          let cmd = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
          let data = try? JSONSerialization.data(withJSONObject: ["command": cmd]) else { return false }
    session.sendToRemoteWorkoutSession(data: data) { _, _ in }
    return true
  }

  /// Starts a built session on the watch, with the watch as its owner:
  /// launches the Paceo watch app (HealthKit can wake it even when it isn't
  /// open), then hands it the session once it's listening. Resolves true
  /// when the watch confirms it started.
  func startOnWatch(_ json: String, completion: @escaping (Bool) -> Void) {
    guard WCSession.default.activationState == .activated, WCSession.default.isWatchAppInstalled else {
      completion(false)
      return
    }
    // A built run (kind "cardio") launches the watch as a run, outdoors or
    // on a treadmill as the session says; anything else is strength.
    let data = Data(json.utf8)
    let built = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let isRun = built?["kind"] as? String == "cardio"
    let outdoor = built?["outdoor"] as? Bool ?? true
    let config = HKWorkoutConfiguration()
    if isRun {
      // Every cardio sport the watch app plays; a pool swim needs its
      // pool set for the launch to be accepted (the watch can change it).
      config.activityType = switch built?["sport"] as? String {
      case "walk": .walking
      case "hike": .hiking
      case "ride": .cycling
      case "swim": .swimming
      case "row": .rowing
      case "ski": .crossCountrySkiing
      case "run": .running
      default: .other
      }
      config.locationType = outdoor ? .outdoor : .indoor
      if config.activityType == .swimming {
        config.swimmingLocationType = outdoor ? .openWater : .pool
        if !outdoor { config.lapLength = HKQuantity(unit: .meter(), doubleValue: 25) }
      }
    } else {
      config.activityType = .traditionalStrengthTraining
      config.locationType = .indoor
    }
    let message: [String: Any] = isRun ? ["startRun": data, "outdoor": outdoor] : ["start": data]
    store.startWatchApp(with: config) { [weak self] launched, _ in
      guard launched else {
        completion(false)
        return
      }
      self?.deliverStart(message, attemptsLeft: 20, completion: completion)
    }
  }

  // The app takes a moment to launch and activate its session; retry for
  // ~10 s until it's reachable and answers.
  private func deliverStart(_ message: [String: Any], attemptsLeft: Int, completion: @escaping (Bool) -> Void) {
    let retry = { [weak self] in
      guard attemptsLeft > 1 else {
        completion(false)
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        self?.deliverStart(message, attemptsLeft: attemptsLeft - 1, completion: completion)
      }
    }
    guard WCSession.default.isReachable else {
      retry()
      return
    }
    WCSession.default.sendMessage(
      message,
      replyHandler: { reply in completion(reply["ok"] as? Bool == true) },
      errorHandler: { _ in retry() })
  }

  // MARK: finished sessions inbox

  private var inboxURL: URL {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("paceo-watch-inbox.json")
  }

  private func readInbox() -> [String: String] {
    guard let data = try? Data(contentsOf: inboxURL),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
    return dict
  }

  private func writeInbox(_ inbox: [String: String]) {
    guard let data = try? JSONSerialization.data(withJSONObject: inbox) else { return }
    try? data.write(to: inboxURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  /// Finished sessions waiting to be saved: [{logKey, json}].
  func pendingFinished() -> [[String: String]] {
    queue.sync { readInbox().map { ["logKey": $0.key, "json": $0.value] } }
  }

  /// Saved on our server: forget it here and tell the watch to forget it too.
  func ack(_ logKey: String) {
    queue.sync {
      var inbox = readInbox()
      inbox.removeValue(forKey: logKey)
      writeInbox(inbox)
    }
    if WCSession.default.activationState == .activated {
      WCSession.default.transferUserInfo(["ack": logKey])
    }
  }

  private func receiveFinished(_ userInfo: [String: Any]) {
    guard let data = userInfo["finished"] as? Data, let key = userInfo["logKey"] as? String,
          let json = String(data: data, encoding: .utf8) else { return }
    queue.sync {
      var inbox = readInbox()
      inbox[key] = json
      writeInbox(inbox)
    }
    onFinished?()
  }

  // MARK: mirroring

  @available(iOS 17.0, *)
  private func adoptMirror(_ session: HKWorkoutSession) {
    mirrored = session
    session.delegate = self
    onMirror?(true)
    // Ask for the current state rather than waiting for the next change.
    if let data = try? JSONSerialization.data(withJSONObject: ["hello": true]) {
      session.sendToRemoteWorkoutSession(data: data) { _, _ in }
    }
  }

  private func endMirror() {
    mirrored = nil
    onMirror?(false)
  }
}

extension WatchLink: WCSessionDelegate {
  func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
  func sessionDidBecomeInactive(_ session: WCSession) {}
  // Switching watches: activate again for the new one.
  func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }

  func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
    receiveFinished(userInfo)
  }
}

extension WatchLink: HKWorkoutSessionDelegate {
  func workoutSession(
    _ s: HKWorkoutSession, didChangeTo to: HKWorkoutSessionState, from: HKWorkoutSessionState, date: Date
  ) {
    if to == .ended || to == .stopped { endMirror() }
  }

  func workoutSession(_ s: HKWorkoutSession, didFailWithError error: Error) {}

  func workoutSession(_ s: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?) {
    endMirror()
  }

  func workoutSession(_ s: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
    for d in data {
      guard let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
            let snap = obj["snapshot"],
            let snapData = try? JSONSerialization.data(withJSONObject: snap),
            let json = String(data: snapData, encoding: .utf8) else { continue }
      lastSnapshot = json
      onSnapshot?(json)
    }
  }
}

/// Starts the link at launch, before JS, so a background launch for a
/// mirrored session or a delivered workout is never missed.
public class WatchLinkAppDelegate: ExpoAppDelegateSubscriber {
  public func application(
    _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    WatchLink.shared.start()
    return true
  }
}
