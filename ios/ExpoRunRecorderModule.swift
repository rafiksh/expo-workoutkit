import ExpoModulesCore

// JS surface for RunRecorder + RunMapView. Kept separate from
// ExpoWorkoutkitModule because a module definition holds one native view.
public class ExpoRunRecorderModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ExpoRunRecorder")

    Events("onRunUpdate", "onRunState")

    OnCreate {
      RunRecorder.shared.onUpdate = { [weak self] metrics in
        self?.sendEvent("onRunUpdate", metrics)
      }
      RunRecorder.shared.onState = { [weak self] state in
        self?.sendEvent("onRunState", ["state": state])
      }
    }

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

    AsyncFunction("requestHealthWritePermission") { (promise: Promise) in
      RunRecorder.shared.requestHealth { promise.resolve($0) }
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
      Prop("lineColor") { (view: RunMapView, value: String?) in
        view.setLineColor(value)
      }
    }
  }
}
