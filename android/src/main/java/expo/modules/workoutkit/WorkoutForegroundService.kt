package expo.modules.workoutkit

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

// The one ongoing notification a workout owns, and the foreground service
// behind it. Two jobs, one service, so the athlete never sees two
// notifications: it keeps the process (and so the JS timers and cues) alive
// with the screen off, and it hosts the location type the GPS recorder
// needs. The Android twin of the iOS Live Activity + background modes.
//
// Content is pushed from JS (ExpoWorkoutNotificationModule) and mirrors the
// Live Activity's: current step, its countdown, the target or set, what's
// next, and Back / Pause-Resume / Next actions that round-trip to JS as
// events (the JS engine is alive, that's the point of the service).
class WorkoutForegroundService : Service() {
  override fun onBind(intent: Intent?): IBinder? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    when (intent?.action) {
      ACTION_BACK, ACTION_NEXT, ACTION_PAUSE, ACTION_RESUME -> {
        onAction?.invoke(intent.action!!.removePrefix(ACTION_PREFIX).lowercase())
        return START_NOT_STICKY
      }
      ACTION_STOP -> {
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        running = false
        return START_NOT_STICKY
      }
    }
    val types = foregroundTypes(this, needsLocation)
    val notification = build(this, content)
    try {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        startForeground(NOTIFICATION_ID, notification, types)
      } else {
        startForeground(NOTIFICATION_ID, notification)
      }
      running = true
    } catch (e: Exception) {
      // A type we may not use (permission revoked mid-run): fall back to a
      // plain ongoing notification so the athlete still sees the workout.
      notificationManager(this).notify(NOTIFICATION_ID, notification)
      stopSelf()
    }
    return START_NOT_STICKY
  }

  override fun onDestroy() {
    running = false
    super.onDestroy()
  }

  companion object {
    private const val CHANNEL_ID = "workout"
    private const val NOTIFICATION_ID = 7211
    private const val ACTION_PREFIX = "expo.modules.workoutkit.action."
    const val ACTION_BACK = ACTION_PREFIX + "BACK"
    const val ACTION_NEXT = ACTION_PREFIX + "NEXT"
    const val ACTION_PAUSE = ACTION_PREFIX + "PAUSE"
    const val ACTION_RESUME = ACTION_PREFIX + "RESUME"
    const val ACTION_STOP = ACTION_PREFIX + "STOP"

    /** "back" | "next" | "pause" | "resume", set by the notification module. */
    var onAction: ((String) -> Unit)? = null

    // What the notification currently shows. Kept here (not in the
    // service instance) so a restart re-renders the same thing.
    @Volatile private var content: NotificationContent = NotificationContent()
    @Volatile private var running = false
    @Volatile private var notificationActive = false
    @Volatile private var recorderActive = false
    @Volatile private var needsLocation = false

    fun start(context: Context, next: NotificationContent) {
      content = next
      notificationActive = true
      ensure(context)
    }

    fun update(context: Context, next: NotificationContent) {
      content = next
      if (!notificationActive) return
      if (running) notificationManager(context).notify(NOTIFICATION_ID, build(context, content)) else ensure(context)
    }

    fun end(context: Context) {
      notificationActive = false
      settle(context)
    }

    fun setRecorderActive(context: Context, needsLocation: Boolean, active: Boolean = true) {
      recorderActive = active
      this.needsLocation = active && needsLocation
      if (active) ensure(context) else settle(context)
    }

    private fun ensure(context: Context) {
      val intent = Intent(context, WorkoutForegroundService::class.java)
      try {
        ContextCompat.startForegroundService(context, intent)
      } catch (e: Exception) {
        // Background start restrictions: show the notification without the
        // service rather than nothing.
        notificationManager(context).notify(NOTIFICATION_ID, build(context, content))
      }
    }

    private fun settle(context: Context) {
      if (notificationActive || recorderActive) {
        // Still needed by the other owner; re-render without the location
        // type when the recorder let go.
        if (running) ensure(context)
        return
      }
      val intent = Intent(context, WorkoutForegroundService::class.java).setAction(ACTION_STOP)
      try {
        context.startService(intent)
      } catch (e: Exception) {
        // Service already gone.
      }
      notificationManager(context).cancel(NOTIFICATION_ID)
    }

    private fun notificationManager(context: Context) =
      context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    // Android 14 insists on a type the app is allowed to use right now:
    // "location" needs the location permission, "health" one of the
    // fitness permissions (we ask for ACTIVITY_RECOGNITION). Neither
    // granted: no type, and on 14+ the service can't start; the caller
    // then shows a plain notification.
    private fun foregroundTypes(context: Context, wantsLocation: Boolean): Int {
      if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return 0
      var types = 0
      val hasLocation =
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
          ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
      if (wantsLocation && hasLocation) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
        val hasActivity =
          ContextCompat.checkSelfPermission(context, Manifest.permission.ACTIVITY_RECOGNITION) == PackageManager.PERMISSION_GRANTED
        if (hasActivity) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_HEALTH
      }
      return types
    }

    private fun ensureChannel(context: Context) {
      if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
      val manager = notificationManager(context)
      if (manager.getNotificationChannel(CHANNEL_ID) != null) return
      val channel = NotificationChannel(CHANNEL_ID, "Workout in progress", NotificationManager.IMPORTANCE_LOW).apply {
        description = "The live workout: current step, timer, and controls."
        setShowBadge(false)
        enableVibration(false)
        setSound(null, null)
      }
      manager.createNotificationChannel(channel)
    }

    private fun smallIcon(context: Context): Int {
      // expo-notifications' plugin ships a monochrome notification_icon;
      // fall back to the launcher icon (tinted grey by the system).
      val id = context.resources.getIdentifier("notification_icon", "drawable", context.packageName)
      return if (id != 0) id else context.applicationInfo.icon
    }

    private fun action(context: Context, action: String, label: String): NotificationCompat.Action {
      val intent = Intent(context, WorkoutForegroundService::class.java).setAction(action)
      val flags = PendingIntent.FLAG_UPDATE_CURRENT or
        (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
      val pending = PendingIntent.getService(context, action.hashCode(), intent, flags)
      return NotificationCompat.Action.Builder(0, label, pending).build()
    }

    private fun build(context: Context, c: NotificationContent): Notification {
      ensureChannel(context)
      val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
      val tapFlags = PendingIntent.FLAG_UPDATE_CURRENT or
        (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
      val tap = launch?.let { PendingIntent.getActivity(context, 0, it, tapFlags) }

      val line = listOfNotNull(c.stepName.ifBlank { null }, c.setText ?: c.targetText).joinToString(" · ")
      val position = if (c.stepCount > 0) "${c.stepIndex + 1}/${c.stepCount}" else null
      val sub = listOfNotNull(position, c.nextLabel?.let { "Next: $it" }).joinToString(" · ")

      val builder = NotificationCompat.Builder(context, CHANNEL_ID)
        .setSmallIcon(smallIcon(context))
        .setContentTitle(c.workoutName.ifBlank { "Workout" })
        .setContentText(line.ifBlank { if (c.isPaused) "Paused" else "In progress" })
        .setSubText(sub.ifBlank { null })
        .setOngoing(true)
        .setOnlyAlertOnce(true)
        .setSilent(true)
        .setCategory(NotificationCompat.CATEGORY_WORKOUT)
        .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
        .setPriority(NotificationCompat.PRIORITY_LOW)
        .setShowWhen(false)
      c.purposeColorHex?.let { hex -> runCatching { Color.parseColor(hex) }.getOrNull()?.let { builder.setColor(it) } }
      tap?.let { builder.setContentIntent(it) }

      // The clock: a native countdown for timed steps, a count-up for open
      // ones, frozen text while paused (both dates are null then).
      when {
        c.isPaused -> builder.setContentText(
          listOfNotNull("Paused", line.ifBlank { null }, c.remainingS?.let { formatClock(it) }).joinToString(" · "),
        )
        c.stepEndDateMs != null -> builder.setUsesChronometer(true).setChronometerCountDown(true).setWhen(c.stepEndDateMs).setShowWhen(true)
        c.stepStartDateMs != null -> builder.setUsesChronometer(true).setWhen(c.stepStartDateMs).setShowWhen(true)
      }
      if (c.stepCount > 0) builder.setProgress(c.stepCount, (c.stepIndex + 1).coerceIn(0, c.stepCount), false)

      builder.addAction(action(context, ACTION_BACK, "Back"))
      builder.addAction(
        if (c.isPaused) action(context, ACTION_RESUME, "Resume") else action(context, ACTION_PAUSE, "Pause"),
      )
      builder.addAction(action(context, ACTION_NEXT, "Next"))
      return builder.build()
    }

    private fun formatClock(seconds: Long): String {
      val s = seconds.coerceAtLeast(0)
      val h = s / 3600
      val m = (s % 3600) / 60
      val sec = s % 60
      return if (h > 0) String.format("%d:%02d:%02d", h, m, sec) else String.format("%d:%02d", m, sec)
    }
  }
}

/** What the notification renders; the Live Activity content, flattened. */
data class NotificationContent(
  val workoutName: String = "",
  val stepName: String = "",
  val purposeColorHex: String? = null,
  val stepIndex: Int = 0,
  val stepCount: Int = 0,
  val remainingS: Long? = null,
  val stepEndDateMs: Long? = null,
  val stepStartDateMs: Long? = null,
  val isPaused: Boolean = false,
  val targetText: String? = null,
  val setText: String? = null,
  val nextLabel: String? = null,
) {
  companion object {
    fun from(workoutName: String, map: Map<String, Any?>): NotificationContent = NotificationContent(
      workoutName = workoutName,
      stepName = map["stepName"] as? String ?: "",
      purposeColorHex = map["purposeColorHex"] as? String,
      stepIndex = (map["stepIndex"] as? Number)?.toInt() ?: 0,
      stepCount = (map["stepCount"] as? Number)?.toInt() ?: 0,
      remainingS = (map["remainingS"] as? Number)?.toLong(),
      stepEndDateMs = (map["stepEndDateMs"] as? Number)?.toLong(),
      stepStartDateMs = (map["stepStartDateMs"] as? Number)?.toLong(),
      isPaused = map["isPaused"] as? Boolean ?: false,
      targetText = map["targetText"] as? String,
      setText = map["setText"] as? String,
      nextLabel = map["nextLabel"] as? String,
    )
  }
}
