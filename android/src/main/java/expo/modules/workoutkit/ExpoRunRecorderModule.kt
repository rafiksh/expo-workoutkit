package expo.modules.workoutkit

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import expo.modules.interfaces.permissions.PermissionsStatus
import expo.modules.kotlin.Promise
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.functions.Queues
import expo.modules.kotlin.modules.ModuleDefinition
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

// JS surface for RunRecorder + RunMapView, same contract as
// ios/ExpoRunRecorderModule.swift. Kept separate from ExpoWorkoutkitModule
// because a module definition holds one native view.
class ExpoRunRecorderModule : Module() {
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

  override fun definition() = ModuleDefinition {
    Name("ExpoRunRecorder")

    Events("onRunUpdate", "onRunState", "onHeartRateMonitors", "onHeartRateMonitorState")

    OnCreate {
      appContext.reactContext?.let { RunRecorder.attach(it) }
      RunRecorder.onUpdate = { metrics -> sendEvent("onRunUpdate", metrics) }
      RunRecorder.onState = { state -> sendEvent("onRunState", mapOf("state" to state)) }
      HeartRateMonitor.onMonitors = { monitors -> sendEvent("onHeartRateMonitors", mapOf("monitors" to monitors)) }
      HeartRateMonitor.onState = { state -> sendEvent("onHeartRateMonitorState", state) }
      // Prime the Health Connect grant cache so canWriteHealth answers
      // right on the first session; refreshed again after every request.
      scope.launch { runCatching { appContext.reactContext?.let { HealthStore.refreshGranted(it) } } }
    }

    OnDestroy {
      RunRecorder.onUpdate = null
      RunRecorder.onState = null
      HeartRateMonitor.onMonitors = null
      HeartRateMonitor.onState = null
      scope.cancel()
    }

    AsyncFunction("getLocationPermission") { promise: Promise ->
      promise.resolve(locationStatus())
    }

    AsyncFunction("requestLocationPermission") { promise: Promise ->
      if (locationStatus() == "granted") {
        promise.resolve("granted")
        return@AsyncFunction
      }
      val manager = appContext.permissions
      if (manager == null) {
        promise.resolve("denied")
        return@AsyncFunction
      }
      manager.askForPermissions(
        { result ->
          val fine = result[Manifest.permission.ACCESS_FINE_LOCATION]?.status
          val coarse = result[Manifest.permission.ACCESS_COARSE_LOCATION]?.status
          val granted = fine == PermissionsStatus.GRANTED || coarse == PermissionsStatus.GRANTED
          promise.resolve(if (granted) "granted" else "denied")
        },
        Manifest.permission.ACCESS_FINE_LOCATION,
        Manifest.permission.ACCESS_COARSE_LOCATION,
      )
    }

    Function("canWriteHealth") { RunRecorder.canWriteWorkouts() }

    // Health Connect can't tell a refusal from never asked (its sheet can
    // be shown again), so anything short of granted is "undetermined".
    Function("getHealthWritePermission") {
      if (RunRecorder.canWriteWorkouts()) "granted" else "undetermined"
    }

    // One Health Connect sheet: write workout + route + distance, plus the
    // import read set, like the iOS combined request.
    AsyncFunction("requestHealthWritePermission") { promise: Promise ->
      HealthPermissionFlow.request(appContext, scope) { promise.resolve(RunRecorder.canWriteWorkouts()) }
    }

    OnActivityResult { _, payload ->
      HealthPermissionFlow.onActivityResult(appContext, scope, payload.requestCode)
    }

    // Bluetooth heart-rate straps, same contract as iOS. The permission
    // sheet (Nearby devices on 12+, location before) appears on the first
    // scan, never on its own.
    Function("getHeartRateMonitor") {
      val out = HashMap<String, Any?>()
      out["supported"] = HeartRateMonitor.supported
      out["permission"] = if (HeartRateMonitor.granted()) "granted" else "undetermined"
      HeartRateMonitor.saved?.let { out["monitor"] = it }
      out
    }

    AsyncFunction("scanHeartRateMonitors") { promise: Promise ->
      if (HeartRateMonitor.granted()) {
        HeartRateMonitor.scan()
        promise.resolve(null)
        return@AsyncFunction
      }
      val manager = appContext.permissions
      if (manager == null) {
        HeartRateMonitor.scan()
        promise.resolve(null)
        return@AsyncFunction
      }
      manager.askForPermissions(
        { _ ->
          HeartRateMonitor.scan()
          promise.resolve(null)
        },
        *HeartRateMonitor.permissions,
      )
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("stopHeartRateMonitorScan") {
      HeartRateMonitor.stopScan()
      HeartRateMonitor.release("screen")
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("pairHeartRateMonitor") { id: String -> HeartRateMonitor.pair(id) }.runOnQueue(Queues.MAIN)

    AsyncFunction("forgetHeartRateMonitor") { HeartRateMonitor.forget() }.runOnQueue(Queues.MAIN)

    AsyncFunction("warmUp") { RunRecorder.warmUp() }

    AsyncFunction("coolDown") { RunRecorder.coolDown() }

    AsyncFunction("start") { activity: String, outdoor: Boolean ->
      RunRecorder.start(activity, outdoor)
    }

    AsyncFunction("pause") { RunRecorder.pause() }

    AsyncFunction("resume") { RunRecorder.resume() }

    AsyncFunction("stop") { RunRecorder.stop() }

    AsyncFunction("finish") { promise: Promise ->
      scope.launch {
        val summary = runCatching { RunRecorder.finish() }.getOrElse { RunRecorder.snapshot() }
        promise.resolve(summary)
      }
    }

    AsyncFunction("discard") { RunRecorder.discard() }

    AsyncFunction("snapshot") { RunRecorder.snapshot() }

    View(RunMapView::class) {
      Events("onFollowChange")

      Prop("live") { view: RunMapView, value: Boolean? -> view.setLive(value ?: false) }
      Prop("followUser") { view: RunMapView, value: Boolean? -> view.setFollow(value ?: true) }
      Prop("route") { view: RunMapView, value: List<String>? -> view.setRoute(value) }
      Prop("spanMeters") { view: RunMapView, value: Double? -> view.setSpanMeters(value) }
      Prop("lineColor") { view: RunMapView, value: String? -> view.setLineColor(value) }
    }
  }

  // "denied" only once the system would no longer show the sheet (the
  // athlete refused for good); "undetermined" while asking still works.
  private fun locationStatus(): String {
    val context = appContext.reactContext ?: return "undetermined"
    val granted =
      ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
    if (granted) return "granted"
    val activity: Activity = appContext.currentActivity ?: return "undetermined"
    val asked = appContext.permissions?.isPermissionPresentInManifest(Manifest.permission.ACCESS_FINE_LOCATION) == true
    val rationale = ActivityCompat.shouldShowRequestPermissionRationale(activity, Manifest.permission.ACCESS_FINE_LOCATION)
    // No rationale after a refusal means "don't ask again"; before any ask
    // the flag is also false, so remember whether we ever asked.
    return if (asked && !rationale && HealthPermissionFlow.locationAsked) "denied" else "undetermined"
  }
}
