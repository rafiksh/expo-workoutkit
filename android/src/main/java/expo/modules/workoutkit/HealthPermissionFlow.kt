package expo.modules.workoutkit

import androidx.health.connect.client.PermissionController
import expo.modules.kotlin.AppContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

// Health Connect's permission screen is an Activity result, not a callback:
// build its intent from the SDK's contract, start it from the current
// Activity, and read the grants back when the module's OnActivityResult
// fires. Both modules (import read, recorder write) share one request so
// the athlete sees one sheet, like iOS.
object HealthPermissionFlow {
  private const val REQUEST_CODE = 0x4843 // "HC"
  private val waiters = ArrayList<() -> Unit>()
  @Volatile var locationAsked = false

  val allPermissions: Set<String> get() = HealthImport.readPermissions + HealthStore.writePermissions

  fun request(appContext: AppContext, scope: CoroutineScope, done: () -> Unit) {
    val context = appContext.reactContext
    val activity = appContext.currentActivity
    if (context == null || activity == null || !HealthStore.available(context)) {
      done()
      return
    }
    scope.launch {
      runCatching { HealthStore.refreshGranted(context) }
      if (HealthStore.granted.containsAll(allPermissions)) {
        done()
        return@launch
      }
      waiters.add(done)
      if (waiters.size > 1) return@launch
      try {
        val intent = PermissionController.createRequestPermissionResultContract().createIntent(context, allPermissions)
        activity.startActivityForResult(intent, REQUEST_CODE)
      } catch (e: Exception) {
        finish(context, scope)
      }
    }
  }

  fun onActivityResult(appContext: AppContext, scope: CoroutineScope, requestCode: Int) {
    if (requestCode != REQUEST_CODE) return
    val context = appContext.reactContext ?: return
    finish(context, scope)
  }

  private fun finish(context: android.content.Context, scope: CoroutineScope) {
    scope.launch {
      runCatching { HealthStore.refreshGranted(context) }
      val pending = waiters.toList()
      waiters.clear()
      pending.forEach { it() }
    }
  }
}
