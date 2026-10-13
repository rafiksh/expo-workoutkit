package expo.modules.workoutkit

import android.app.Activity
import android.os.Bundle
import android.widget.ScrollView
import android.widget.TextView

// Health Connect opens this when the athlete taps "why does this app want
// my data" on its permission screen. Plain text, system dialog theme, no
// dependency on the app's UI stack (it can be launched while the app is
// not running).
class HealthRationaleActivity : Activity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    val appName = applicationInfo.loadLabel(packageManager).toString()
    val padding = (24 * resources.displayMetrics.density).toInt()
    val text = TextView(this).apply {
      setPadding(padding, padding, padding, padding)
      textSize = 15f
      text =
        "$appName reads your workouts, heart rate, sleep, and body metrics from Health Connect " +
          "to fill in your training timeline and readiness, and writes the runs, walks, and rides " +
          "you record in $appName with their route and distance.\n\n" +
          "Nothing is read or written beyond that, and you can change this at any time in Health Connect."
    }
    setContentView(ScrollView(this).apply { addView(text) })
  }
}
