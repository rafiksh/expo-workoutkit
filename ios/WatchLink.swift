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
  /// (mirroring, ended): `ended` is true when the watch ended the workout
  /// itself, false when the link dropped and the workout carries on there.
  var onMirror: ((Bool, Bool) -> Void)?
  var onFinished: (() -> Void)?
  var onPermissions: (([String: Any]) -> Void)?
  /// The watch asked for the plan (it does each time its app comes to the
  /// front), with the photo keys it's missing (a reinstall empties its
  /// cache). `current`: it already holds the last plan this phone sent, so
  /// only a week that changed since needs sending.
  var onPlanWanted: (([String], Bool) -> Void)?
  /// The last ask no plan has answered yet. A watch can ask before JS is up
  /// (it wakes this app in the background), when the event above reaches no
  /// one: JS takes it from here once it's running.
  private var planWanted: [String: Any]?

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

  /// What the watch last said it's allowed to do (Health, location, Fitness
  /// Tracking), or nil before the Paceo watch app first reported.
  var lastPermissions: [String: Any]? {
    guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return nil }
    return WCSession.default.receivedApplicationContext["permissions"] as? [String: Any]
  }

  /// Asks the watch afresh when it's in reach; otherwise its last report.
  func checkPermissions(_ completion: @escaping ([String: Any]?) -> Void) {
    let s = WCSession.default
    guard WCSession.isSupported(), s.activationState == .activated, s.isReachable else {
      return completion(lastPermissions)
    }
    s.sendMessage(["permissions": true], replyHandler: { reply in
      completion(reply)
    }, errorHandler: { [weak self] _ in
      completion(self?.lastPermissions)
    })
  }

  // MARK: out

  /// Replaces the watch's plan cache. Latest wins, delivered when the watch
  /// wakes. Kept on disk too, so a watch asking for it gets an answer even
  /// when the phone was woken in the background with no JS running.
  func sendPlan(_ json: String) throws {
    let data = Data(json.utf8)
    try? data.write(to: planURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    queue.sync { planWanted = nil }
    try deliverPlan(data)
  }

  /// The plan into the application context, if the link is up. When it
  /// isn't yet (a plan built in the first moments of a launch, before the
  /// session activated, or before a watch was paired), nothing is lost:
  /// the copy on disk goes out as soon as it is (redeliverPlan).
  private func deliverPlan(_ data: Data) throws {
    guard WCSession.isSupported(), WCSession.default.activationState == .activated, WCSession.default.isPaired else { return }
    try WCSession.default.updateApplicationContext(["plan": data])
  }

  /// The plan on disk, offered to the watch again. The system sends a
  /// context only when it differs from the last one, so this costs nothing
  /// when the watch already has it.
  private func redeliverPlan() {
    guard let data = try? Data(contentsOf: planURL) else { return }
    try? deliverPlan(data)
  }

  /// When the plan on disk was built (its `sentAt`, Unix ms), 0 for none.
  private func planSentAt(_ data: Data) -> Double {
    ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["sentAt"] as? Double ?? 0
  }

  /// The watch's last ask, if no plan has gone out since: {missingPosters, current}.
  func takePlanWanted() -> [String: Any]? {
    queue.sync {
      let wanted = planWanted
      planWanted = nil
      return wanted
    }
  }

  private var planURL: URL {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("paceo-watch-plan.json")
  }

  /// What the watch is doing right now, asked directly: the logKey of the
  /// workout it's running, or "" when it's running none. nil when the
  /// watch can't be reached, so the caller knows it doesn't know.
  func askWatchState(_ completion: @escaping (String?) -> Void) {
    let s = WCSession.default
    guard WCSession.isSupported(), s.activationState == .activated, s.isReachable else { return completion(nil) }
    s.sendMessage(["state": true], replyHandler: { reply in
      completion(reply["active"] as? String ?? "")
    }, errorHandler: { _ in completion(nil) })
  }

  /// A downsized exercise photo, keyed by exercise (exerciseId ?? name).
  func sendPoster(fileUri: String, key: String) {
    // No isWatchAppInstalled check: it lags a fresh install, and a transfer
    // to a watch without the app just never lands.
    guard WCSession.default.activationState == .activated,
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
    onMirror?(true, false)
    // Ask for the current state rather than waiting for the next change.
    if let data = try? JSONSerialization.data(withJSONObject: ["hello": true]) {
      session.sendToRemoteWorkoutSession(data: data) { _, _ in }
    }
  }

  private func endMirror(ended: Bool) {
    guard mirrored != nil else { return }
    mirrored = nil
    onMirror?(false, ended)
  }
}

extension WatchLink: WCSessionDelegate {
  func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
    // A plan handed over before the link was up is still only on disk.
    if state == .activated { redeliverPlan() }
  }
  func sessionDidBecomeInactive(_ session: WCSession) {}
  /// A watch was paired, or the Paceo watch app installed: it gets the plan now.
  func sessionWatchStateDidChange(_ session: WCSession) { redeliverPlan() }
  // Switching watches: activate again for the new one.
  func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }

  func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
    receiveFinished(userInfo)
  }

  func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
    if let p = context["permissions"] as? [String: Any] { onPermissions?(p) }
  }

  /// The watch asking for the plan, with the `sentAt` of the one it holds:
  /// answered from disk at once (this can be a background launch with no
  /// JS yet). If it already holds this phone's last plan it's told so in a
  /// few bytes; otherwise it gets the plan in the reply, or, when the plan
  /// is too big for a reply (they cap near 64 KB), as a queued transfer
  /// that can't be refused for its size. Either way JS is told, and sends
  /// a fresh one if the week has changed.
  func session(
    _ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void
  ) {
    // A finished workout sent live (the watch does this whenever the phone
    // is in reach): into the inbox now, even from a background launch with
    // no JS, and say so, so the watch can show "On your iPhone".
    if message["finished"] != nil {
      receiveFinished(message)
      return replyHandler(["received": true])
    }
    guard message["needPlan"] != nil else { return replyHandler([:]) }
    var current = false
    if let data = try? Data(contentsOf: planURL) {
      let ours = planSentAt(data)
      if let have = message["have"] as? Double, ours > 0, have >= ours {
        current = true
        replyHandler(["current": true])
      } else if data.count <= 60_000 {
        replyHandler(["plan": data])
      } else {
        session.transferUserInfo(["plan": data])
        replyHandler(["planComing": true])
      }
    } else {
      replyHandler([:])
    }
    let missing = message["missingPosters"] as? [String] ?? []
    queue.sync { planWanted = ["missingPosters": missing, "current": current] }
    onPlanWanted?(missing, current)
  }
}

extension WatchLink: HKWorkoutSessionDelegate {
  func workoutSession(
    _ s: HKWorkoutSession, didChangeTo to: HKWorkoutSessionState, from: HKWorkoutSessionState, date: Date
  ) {
    // The watch ended (or stopped, on its way to ending) the workout: it's
    // over there, not just out of reach.
    if to == .ended || to == .stopped { endMirror(ended: true) }
  }

  func workoutSession(_ s: HKWorkoutSession, didFailWithError error: Error) {}

  func workoutSession(_ s: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?) {
    endMirror(ended: false)
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
