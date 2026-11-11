import ExpoModulesCore

// JS surface for WatchLink. Payloads are JSON strings: the app owns their
// shape (the strength session and its commands), this module only carries them.
public class ExpoWatchLinkModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ExpoWatchLink")

    Events("onWatchSnapshot", "onWatchMirror", "onWatchFinished", "onWatchPermissions", "onWatchPlanWanted")

    OnCreate {
      let link = WatchLink.shared
      link.onSnapshot = { [weak self] json in self?.sendEvent("onWatchSnapshot", ["json": json]) }
      link.onMirror = { [weak self] active, ended in
        self?.sendEvent("onWatchMirror", ["active": active, "ended": ended])
      }
      link.onFinished = { [weak self] in self?.sendEvent("onWatchFinished", [:]) }
      link.onPermissions = { [weak self] p in self?.sendEvent("onWatchPermissions", p) }
      link.onPlanWanted = { [weak self] in self?.sendEvent("onWatchPlanWanted", [:]) }
    }

    OnDestroy {
      WatchLink.shared.onSnapshot = nil
      WatchLink.shared.onMirror = nil
      WatchLink.shared.onFinished = nil
      WatchLink.shared.onPermissions = nil
      WatchLink.shared.onPlanWanted = nil
    }

    Function("getStatus") { () -> [String: Any] in
      WatchLink.shared.status
    }

    /// The watch's latest session JSON if a mirrored session is live.
    Function("getMirroredSnapshot") { () -> String? in
      WatchLink.shared.mirrored != nil ? WatchLink.shared.lastSnapshot : nil
    }

    AsyncFunction("sendPlan") { (json: String) in
      try WatchLink.shared.sendPlan(json)
    }

    Function("sendPoster") { (fileUri: String, key: String) in
      WatchLink.shared.sendPoster(fileUri: fileUri, key: key)
    }

    Function("sendCommand") { (json: String) -> Bool in
      WatchLink.shared.sendCommand(json)
    }

    AsyncFunction("startOnWatch") { (json: String, promise: Promise) in
      WatchLink.shared.startOnWatch(json) { promise.resolve($0) }
    }

    Function("getPendingFinished") { () -> [[String: String]] in
      WatchLink.shared.pendingFinished()
    }

    Function("ackFinished") { (logKey: String) in
      WatchLink.shared.ack(logKey)
    }

    /// What the watch may do: asked afresh in reach, else its last report; null before any.
    AsyncFunction("checkPermissions") { (promise: Promise) in
      WatchLink.shared.checkPermissions { promise.resolve($0) }
    }

    /// The logKey of the workout the watch is running, "" for none, null when out of reach.
    AsyncFunction("getWatchState") { (promise: Promise) in
      WatchLink.shared.askWatchState { promise.resolve($0) }
    }
  }
}
