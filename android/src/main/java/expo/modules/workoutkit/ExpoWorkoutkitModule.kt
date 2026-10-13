package expo.modules.workoutkit

import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.SleepSessionRecord
import expo.modules.kotlin.Promise
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import java.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

// The Android half of ExpoWorkoutkitModule.swift. WorkoutKit (the Apple
// Watch export) has no Android twin, so only the Health import side exists
// here, on Health Connect, with the same JS contract: an opaque anchor in,
// samples out, new anchor back.
class ExpoWorkoutkitModule : Module() {
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

  override fun definition() = ModuleDefinition {
    Name("ExpoWorkoutkit")

    OnDestroy { scope.cancel() }

    Function("isHealthDataAvailable") {
      appContext.reactContext?.let { HealthStore.available(it) } ?: false
    }

    // Presents the Health Connect permission screen for every type the
    // module reads and writes (one sheet, like the iOS combined request).
    AsyncFunction("requestHealthAuthorization") { promise: Promise ->
      HealthPermissionFlow.request(appContext, scope) {
        promise.resolve(HealthStore.granted.containsAll(HealthImport.readPermissions))
      }
    }

    OnActivityResult { _, payload ->
      HealthPermissionFlow.onActivityResult(appContext, scope, payload.requestCode)
    }

    // Health Connect's own settings (per-app permissions). The Android twin
    // of deep-linking x-apple-health://; false when nothing can open it.
    Function("openHealthSettings") {
      val activity = appContext.currentActivity ?: return@Function false
      val intent = android.content.Intent(androidx.health.connect.client.HealthConnectClient.ACTION_HEALTH_CONNECT_SETTINGS)
      runCatching { activity.startActivity(intent) }.isSuccess
    }

    AsyncFunction("queryWorkouts") { anchor: String?, limit: Int, promise: Promise ->
      val context = appContext.reactContext
      if (context == null || !HealthStore.available(context)) {
        promise.resolve(mapOf("anchor" to anchor, "samples" to emptyList<Any>()))
        return@AsyncFunction
      }
      scope.launch {
        try {
          val page = HealthImport.page(context, ExerciseSessionRecord::class, anchor, limit)
          val samples = page.records.filterIsInstance<ExerciseSessionRecord>().map { HealthImport.serializeWorkout(context, it) }
          promise.resolve(mapOf("anchor" to page.anchor, "samples" to samples))
        } catch (e: Exception) {
          promise.reject("ERR_HEALTH_QUERY", e.message, e)
        }
      }
    }

    AsyncFunction("listWorkouts") { beforeISO: String?, limit: Int, promise: Promise ->
      val context = appContext.reactContext
      if (context == null || !HealthStore.available(context)) {
        promise.resolve(emptyList<Any>())
        return@AsyncFunction
      }
      scope.launch {
        try {
          val before = beforeISO?.let { runCatching { Instant.parse(it) }.getOrNull() }
          val workouts = HealthImport.listWorkouts(context, before, limit)
          promise.resolve(workouts.map { HealthImport.serializeWorkout(context, it) })
        } catch (e: Exception) {
          promise.reject("ERR_HEALTH_QUERY", e.message, e)
        }
      }
    }

    AsyncFunction("queryQuantitySamples") { metric: String, anchor: String?, limit: Int, promise: Promise ->
      val context = appContext.reactContext
      val type = HealthImport.quantityType(metric)
      if (context == null || type == null || !HealthStore.available(context)) {
        promise.resolve(mapOf("anchor" to anchor, "samples" to emptyList<Any>()))
        return@AsyncFunction
      }
      scope.launch {
        try {
          val page = HealthImport.page(context, type, anchor, limit)
          val samples = page.records.mapNotNull { HealthImport.serializeQuantity(metric, it) }
          promise.resolve(mapOf("anchor" to page.anchor, "samples" to samples))
        } catch (e: Exception) {
          promise.reject("ERR_HEALTH_QUERY", e.message, e)
        }
      }
    }

    AsyncFunction("querySleepSamples") { anchor: String?, limit: Int, promise: Promise ->
      val context = appContext.reactContext
      if (context == null || !HealthStore.available(context)) {
        promise.resolve(mapOf("anchor" to anchor, "samples" to emptyList<Any>()))
        return@AsyncFunction
      }
      scope.launch {
        try {
          val page = HealthImport.page(context, SleepSessionRecord::class, anchor, limit)
          val samples = page.records.filterIsInstance<SleepSessionRecord>().flatMap { HealthImport.serializeSleep(it) }
          promise.resolve(mapOf("anchor" to page.anchor, "samples" to samples))
        } catch (e: Exception) {
          promise.reject("ERR_HEALTH_QUERY", e.message, e)
        }
      }
    }

    // Apple-only in practice; see ExpoWorkoutkitView.
    View(ExpoWorkoutkitView::class) {}
  }
}
