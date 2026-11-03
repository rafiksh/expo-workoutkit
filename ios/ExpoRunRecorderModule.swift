import ExpoModulesCore

// JS surface for RunRecorder + RunMapView. Kept separate from
// ExpoWorkoutkitModule because a module definition holds one native view.
public class ExpoRunRecorderModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ExpoRunRecorder")

    Events("onRunUpdate", "onRunState", "onHeartRateMonitors", "onHeartRateMonitorState")

    OnCreate {
      RunRecorder.shared.onUpdate = { [weak self] metrics in
        self?.sendEvent("onRunUpdate", metrics)
      }
      RunRecorder.shared.onState = { [weak self] state in
        self?.sendEvent("onRunState", ["state": state])
      }
      HeartRateMonitor.shared.onMonitors = { [weak self] monitors in
        self?.sendEvent("onHeartRateMonitors", ["monitors": monitors])
      }
      HeartRateMonitor.shared.onState = { [weak self] state in
        self?.sendEvent("onHeartRateMonitorState", state)
      }
    }

    // Bluetooth heart-rate straps. Never prompts on its own: the
    // permission sheet appears on the first scan.
    Function("getHeartRateMonitor") { () -> [String: Any] in
      let monitor = HeartRateMonitor.shared
      var out: [String: Any] = ["supported": monitor.supported, "permission": monitor.permission]
      if let saved = monitor.saved { out["monitor"] = saved }
      return out
    }

    AsyncFunction("scanHeartRateMonitors") {
      HeartRateMonitor.shared.scan()
    }.runOnQueue(.main)

    // The pairing screen closed: stop scanning and let the strap go unless
    // a run is using it.
    AsyncFunction("stopHeartRateMonitorScan") {
      HeartRateMonitor.shared.stopScan()
      HeartRateMonitor.shared.release("screen")
    }.runOnQueue(.main)

    AsyncFunction("pairHeartRateMonitor") { (id: String) -> Bool in
      HeartRateMonitor.shared.pair(id)
    }.runOnQueue(.main)

    AsyncFunction("forgetHeartRateMonitor") {
      HeartRateMonitor.shared.forget()
    }.runOnQueue(.main)

    // Async on main: the first touch creates the CLLocationManager, and its
    // delegate callbacks arrive on the thread that created it.
    AsyncFunction("getLocationPermission") { () -> String in
      RunRecorder.shared.locationStatus
    }.runOnQueue(.main)

    AsyncFunction("requestLocationPermission") { (promise: Promise) in
      RunRecorder.shared.requestLocation { promise.resolve($0) }
    }.runOnQueue(.main)

    Function("canWriteHealth") { () -> Bool in
      RunRecorder.shared.canWriteWorkouts
    }

    Function("getHealthWritePermission") { () -> String in
      RunRecorder.shared.healthWriteStatus
    }

    AsyncFunction("requestHealthWritePermission") { (promise: Promise) in
      RunRecorder.shared.requestHealth { promise.resolve($0) }
    }.runOnQueue(.main)

    AsyncFunction("warmUp") {
      RunRecorder.shared.warmUp()
    }.runOnQueue(.main)

    AsyncFunction("coolDown") {
      RunRecorder.shared.coolDown()
    }.runOnQueue(.main)

    AsyncFunction("start") { (activity: String, outdoor: Bool) in
      RunRecorder.shared.start(activity: activity, outdoor: outdoor)
    }.runOnQueue(.main)

    AsyncFunction("pause") {
      RunRecorder.shared.pause()
    }.runOnQueue(.main)

    AsyncFunction("resume") {
      RunRecorder.shared.resume()
    }.runOnQueue(.main)

    AsyncFunction("stop") {
      RunRecorder.shared.stop()
    }.runOnQueue(.main)

    AsyncFunction("finish") { (promise: Promise) in
      RunRecorder.shared.finish { promise.resolve($0) }
    }.runOnQueue(.main)

    AsyncFunction("discard") {
      RunRecorder.shared.discard()
    }.runOnQueue(.main)

    AsyncFunction("snapshot") { () -> [String: Any] in
      RunRecorder.shared.snapshot()
    }.runOnQueue(.main)

    View(RunMapView.self) {
      Events("onFollowChange")

      Prop("live") { (view: RunMapView, value: Bool?) in
        view.setLive(value ?? false)
      }
      Prop("followUser") { (view: RunMapView, value: Bool?) in
        view.setFollow(value ?? true)
      }
      Prop("route") { (view: RunMapView, value: [String]?) in
        view.setRoute(value)
      }
      Prop("spanMeters") { (view: RunMapView, value: Double?) in
        view.setSpanMeters(value)
      }
      Prop("lineColor") { (view: RunMapView, value: String?) in
        view.setLineColor(value)
      }
    }
  }
}
