package expo.modules.workoutkit

import android.content.Context
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.views.ExpoView

// WorkoutKit's preview button is an Apple-only concept (it hands a plan to
// Apple Watch). The view exists on Android only so a bundle that renders
// PreviewWorkoutButton by mistake gets an empty box, never a crash.
class ExpoWorkoutkitView(context: Context, appContext: AppContext) : ExpoView(context, appContext)
