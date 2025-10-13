import ExpoModulesCore
import SwiftUI
import WorkoutKit
import HealthKit

// SwiftUI view that uses .workoutPreview
@available(iOS 17.0, *)
struct WorkoutButtonView: View {
  @State private var showWorkoutPreview = false
  let onButtonPress: () -> Void
  let workoutPlan: WorkoutPlan
  
  init(workoutPlan: WorkoutPlan, onButtonPress: @escaping () -> Void) {
    self.workoutPlan = workoutPlan
    self.onButtonPress = onButtonPress
  }
  
  
  var body: some View {
    Button("Show Workout Preview") {
      showWorkoutPreview.toggle()
      onButtonPress()
    }
    .workoutPreview(workoutPlan, isPresented: $showWorkoutPreview)
    .buttonStyle(.borderedProminent)
  }
}

// This view will be used as a native component. Make sure to inherit from `ExpoView`
// to apply the proper styling (e.g. border radius and shadows).
class ExpoWorkoutkitView: ExpoView {
  let onButtonPress = EventDispatcher()
  private var hostingController: UIHostingController<AnyView>?
  
  private var workoutPlan: Any?

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    clipsToBounds = true
    setupView()
  }
  
  private func setupView() {
    if #available(iOS 17.0, *) {
      // Create the SwiftUI view with WorkoutKit support
      let plan = (workoutPlan as? WorkoutPlan) ?? createDefaultWorkoutPlan()
      let swiftUIView = WorkoutButtonView(workoutPlan: plan) {
        self.onButtonPress(["message": "Workout preview triggered!"])
      }
      
      // Host it in a UIHostingController
      hostingController = UIHostingController(rootView: AnyView(swiftUIView))
    } else {
      // Fallback for older iOS versions
      let fallbackView = FallbackButtonView {
        self.onButtonPress(["message": "WorkoutKit requires iOS 17.0+"])
      }
      
      hostingController = UIHostingController(rootView: AnyView(fallbackView))
    }
    
    hostingController?.view.backgroundColor = UIColor.clear
    
    if let hostingController = hostingController {
      addSubview(hostingController.view)
    }
  }
  
  @available(iOS 17.0, *)
  func setWorkoutPlan(_ plan: WorkoutPlan?) {
    self.workoutPlan = plan
    // Recreate the view with new data
    hostingController?.view.removeFromSuperview()
    setupView()
  }
  
  @available(iOS 17.0, *)
  private func createDefaultWorkoutPlan() -> WorkoutPlan {
    let basicWorkout = SingleGoalWorkout(
      activity: .running,
      location: .outdoor,
      goal: .time(20, UnitDuration.minutes)
    )
    return WorkoutPlan(.goal(basicWorkout))
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    hostingController?.view.frame = bounds
  }
}

// Fallback view for older iOS versions
struct FallbackButtonView: View {
  let onButtonPress: () -> Void
  
  var body: some View {
    Button("WorkoutKit requires iOS 17.0+") {
      onButtonPress()
    }
    .buttonStyle(.borderedProminent)
  }
}
