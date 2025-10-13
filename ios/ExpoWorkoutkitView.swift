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
  let label: String
  
  init(workoutPlan: WorkoutPlan, label: String, onButtonPress: @escaping () -> Void) {
    self.workoutPlan = workoutPlan
    self.label = label
    self.onButtonPress = onButtonPress
  }
  
  
  var body: some View {
    Button(label) {
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
  private var label: String = "Start Workout"

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    clipsToBounds = true
    setupView()
  }
  
  private func setupView() {
    if #available(iOS 17.0, *) {
      // Create the SwiftUI view with WorkoutKit support
      let plan = (workoutPlan as? WorkoutPlan) ?? createDefaultWorkoutPlan()
      let swiftUIView = WorkoutButtonView(workoutPlan: plan, label: label) {
        self.onButtonPress(["message": "Workout preview triggered!"])
      }
      
      // Host it in a UIHostingController
      hostingController = UIHostingController(rootView: AnyView(swiftUIView))
    } else {
      // Fallback for older iOS versions
      let fallbackView = FallbackButtonView(onButtonPress: {
        self.onButtonPress(["message": "WorkoutKit requires iOS 17.0+"])
      }, label: label)
      
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
  
  func setLabel(_ text: String) {
    self.label = text
    // Recreate the view with new label
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
  let label: String
  
  init(onButtonPress: @escaping () -> Void, label: String) {
    self.onButtonPress = onButtonPress
    self.label = label
  }
  
  var body: some View {
    Button(label) {
      onButtonPress()
    }
    .buttonStyle(.borderedProminent)
  }
}
