package expo.modules.workoutkit

import android.app.Activity
import android.content.Intent
import androidx.health.connect.client.contracts.ExerciseRouteRequestContract
import java.time.Instant

// Health Connect lets an app read another app's exercise route only with
// the athlete's consent for that one session: a system sheet, launched as
// an Activity result, that hands the route back (or nothing). One request
// at a time; the queue drains as sheets close. Only a read the athlete
// asked for (importing a workout by hand) opens the sheet; the background
// sync never does, so a run of imports can't turn into a run of prompts.
object RouteConsentFlow {
  private const val REQUEST_CODE = 0x4852 // "HR"
  private data class Pending(val sessionId: String, val start: Instant, val done: (List<Map<String, Any?>>) -> Unit)
  private val queue = ArrayDeque<Pending>()
  private var active: Pending? = null
  private val contract = ExerciseRouteRequestContract()

  fun request(activity: Activity, sessionId: String, start: Instant, done: (List<Map<String, Any?>>) -> Unit) {
    queue.addLast(Pending(sessionId, start, done))
    if (active == null) next(activity)
  }

  private fun next(activity: Activity) {
    val pending = queue.removeFirstOrNull() ?: run {
      active = null
      return
    }
    active = pending
    try {
      activity.startActivityForResult(contract.createIntent(activity, pending.sessionId), REQUEST_CODE)
    } catch (e: Exception) {
      pending.done(emptyList())
      next(activity)
    }
  }

  fun onActivityResult(activity: Activity?, requestCode: Int, resultCode: Int, data: Intent?) {
    if (requestCode != REQUEST_CODE) return
    val pending = active ?: return
    val route = runCatching { contract.parseResult(resultCode, data) }.getOrNull()
    pending.done(route?.let { HealthImport.serializeRoute(it, pending.start) } ?: emptyList())
    if (activity != null) next(activity) else {
      active = null
      queue.clear()
    }
  }
}
