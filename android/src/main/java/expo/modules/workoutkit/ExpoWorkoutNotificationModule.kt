package expo.modules.workoutkit

import android.Manifest
import android.os.Build
import expo.modules.interfaces.permissions.Permissions
import expo.modules.kotlin.Promise
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

// JS surface for the ongoing workout notification (the Android twin of the
// app's Live Activity controller). Content follows the Live Activity's
// WorkoutActivityContent shape; see WorkoutForegroundService for what is
// rendered. Actions tapped on the notification arrive as onWorkoutAction.
class ExpoWorkoutNotificationModule : Module() {
  private var workoutName = ""

  override fun definition() = ModuleDefinition {
    Name("ExpoWorkoutNotification")

    Events("onWorkoutAction")

    OnCreate {
      WorkoutForegroundService.onAction = { type -> sendEvent("onWorkoutAction", mapOf("type" to type)) }
    }

    OnDestroy {
      WorkoutForegroundService.onAction = null
    }

    Function("isSupported") { Build.VERSION.SDK_INT >= Build.VERSION_CODES.O }

    // Android 14 only lets a "health" foreground service run for an app
    // holding a fitness permission. Asked right before a session, like the
    // location sheet; a refusal just means the timers may stall in a
    // pocket. Granted outright below Android 10, where it doesn't exist.
    AsyncFunction("requestActivityRecognitionPermission") { promise: Promise ->
      if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
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
          val status = result[Manifest.permission.ACTIVITY_RECOGNITION]?.status
          promise.resolve(if (status == expo.modules.interfaces.permissions.PermissionsStatus.GRANTED) "granted" else "denied")
        },
        Manifest.permission.ACTIVITY_RECOGNITION,
      )
    }

    AsyncFunction("startWorkoutActivity") { input: Map<String, Any?> ->
      appContext.reactContext?.let { context ->
        workoutName = input["workoutName"] as? String ?: ""
        @Suppress("UNCHECKED_CAST")
        val content = input["content"] as? Map<String, Any?> ?: emptyMap()
        WorkoutForegroundService.start(context, NotificationContent.from(workoutName, content))
      }
      Unit
    }

    AsyncFunction("updateWorkoutActivity") { content: Map<String, Any?> ->
      appContext.reactContext?.let { context ->
        WorkoutForegroundService.update(context, NotificationContent.from(workoutName, content))
      }
      Unit
    }

    AsyncFunction("endWorkoutActivity") {
      appContext.reactContext?.let { context -> WorkoutForegroundService.end(context) }
      Unit
    }
  }
}
