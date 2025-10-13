import ExpoModulesCore
import WorkoutKit
import HealthKit

public class ExpoWorkoutkitModule: Module {
  // Each module class must implement the definition function. The definition consists of components
  // that describes the module's functionality and behavior.
  // See https://docs.expo.dev/modules/module-api for more details about available components.
  public func definition() -> ModuleDefinition {
    // Sets the name of the module that JavaScript code will use to refer to the module. Takes a string as an argument.
    // Can be inferred from module's class name, but it's recommended to set it explicitly for clarity.
    // The module will be accessible from `requireNativeModule('ExpoWorkoutkit')` in JavaScript.
    Name("ExpoWorkoutkit")


    // Enables the module to be used as a native view. Definition components that are accepted as part of the
    // view definition: Prop, Events.
    View(ExpoWorkoutkitView.self) {
      Prop("workoutData") { (view: ExpoWorkoutkitView, data: [String: Any]?) in
        if #available(iOS 17.0, *) {
          if let data = data {
            let workoutPlan = createWorkoutPlan(from: data)
            view.setWorkoutPlan(workoutPlan)
          } else {
            view.setWorkoutPlan(nil)
          }
        }
        // For iOS < 17.0, the view will show the fallback message
      }
      
      Events("onButtonPress")
    }
  }
}

// Create WorkoutPlan directly from JavaScript data
@available(iOS 17.0, *)
private func createWorkoutPlan(from data: [String: Any]) -> WorkoutPlan {
  let type = data["type"] as? String ?? "goal"
  
  switch type {
  case "goal":
    return createSingleGoalWorkout(from: data["workout"] as? [String: Any])
  case "pacer":
    return createPacerWorkout(from: data["workout"] as? [String: Any])
  case "custom":
    return createCustomWorkout(from: data["workout"] as? [String: Any])
  default:
    return createSingleGoalWorkout(from: data["workout"] as? [String: Any])
  }
}

private func parseActivity(from string: String?) -> HKWorkoutActivityType {
  switch string {
  case "running": return .running
  case "cycling": return .cycling
  case "swimming": return .swimming
  case "walking": return .walking
  default: return .running
  }
}

private func parseLocation(from string: String?) -> HKWorkoutSessionLocationType {
  switch string {
  case "indoor": return .indoor
  case "outdoor": return .outdoor
  default: return .outdoor
  }
}

@available(iOS 17.0, *)
private func createSingleGoalWorkout(from data: [String: Any]?) -> WorkoutPlan {
  guard let data = data else {
    let basicWorkout = SingleGoalWorkout(activity: .running, location: .outdoor, goal: .time(20, UnitDuration.minutes))
    return WorkoutPlan(.goal(basicWorkout))
  }
  
  let activity = parseActivity(from: data["activity"] as? String)
  let location = parseLocation(from: data["location"] as? String)
  let goal = createWorkoutGoal(from: data["goal"] as? [String: Any] ?? [:])
  
  let basicWorkout = SingleGoalWorkout(activity: activity, location: location, goal: goal)
  return WorkoutPlan(.goal(basicWorkout))
}

@available(iOS 17.0, *)
private func createPacerWorkout(from data: [String: Any]?) -> WorkoutPlan {
  guard let data = data else {
    let distance = Measurement(value: 5, unit: UnitLength.miles)
    let time = Measurement(value: 30, unit: UnitDuration.minutes)
    let pacerWorkout = PacerWorkout(activity: .running, location: .outdoor, distance: distance, time: time)
    return WorkoutPlan(.pacer(pacerWorkout))
  }
  
  let activity = parseActivity(from: data["activity"] as? String)
  let location = parseLocation(from: data["location"] as? String)
  let distance = createDistance(from: data["distance"] as? [String: Any] ?? [:])
  let time = createTime(from: data["time"] as? [String: Any] ?? [:])
  
  let pacerWorkout = PacerWorkout(activity: activity, location: location, distance: distance, time: time)
  return WorkoutPlan(.pacer(pacerWorkout))
}

@available(iOS 17.0, *)
private func createCustomWorkout(from data: [String: Any]?) -> WorkoutPlan {
  guard let data = data else {
    let customWorkout = CustomWorkout(activity: .running, location: .outdoor, displayName: "Default Workout")
    return WorkoutPlan(.custom(customWorkout))
  }
  
  let activity = parseActivity(from: data["activity"] as? String)
  let location = parseLocation(from: data["location"] as? String)
  let displayName = data["displayName"] as? String
  let warmup = createWorkoutStep(from: data["warmup"] as? [String: Any])
  let cooldown = createWorkoutStep(from: data["cooldown"] as? [String: Any])
  let blocks = createBlocks(from: data["blocks"] as? [[String: Any]])
  
  let customWorkout = CustomWorkout(
    activity: activity,
    location: location,
    displayName: displayName,
    warmup: warmup,
    blocks: blocks,
    cooldown: cooldown
  )
  return WorkoutPlan(.custom(customWorkout))
}

@available(iOS 17.0, *)
private func createWorkoutGoal(from data: [String: Any]) -> WorkoutGoal {
  let type = data["type"] as? String ?? "time"
  let value = data["value"] as? Double ?? 20.0
  let unit = data["unit"] as? String ?? "minutes"
  
  switch type {
  case "time":
    let timeUnit: UnitDuration = unit == "hours" ? UnitDuration.hours : UnitDuration.minutes
    return .time(value, timeUnit)
  case "distance":
    let distanceUnit: UnitLength = unit == "miles" ? UnitLength.miles : UnitLength.kilometers
    return .distance(value, distanceUnit)
  default:
    return .time(20, UnitDuration.minutes)
  }
}

@available(iOS 17.0, *)
private func createDistance(from data: [String: Any]) -> Measurement<UnitLength> {
  let value = data["value"] as? Double ?? 5.0
  let unit = data["unit"] as? String ?? "miles"
  let distanceUnit: UnitLength = unit == "miles" ? UnitLength.miles : UnitLength.kilometers
  return Measurement(value: value, unit: distanceUnit)
}

@available(iOS 17.0, *)
private func createTime(from data: [String: Any]) -> Measurement<UnitDuration> {
  let value = data["value"] as? Double ?? 30.0
  let unit = data["unit"] as? String ?? "minutes"
  let timeUnit: UnitDuration = unit == "hours" ? UnitDuration.hours : UnitDuration.minutes
  return Measurement(value: value, unit: timeUnit)
}

@available(iOS 17.0, *)
private func createWorkoutStep(from data: [String: Any]?) -> WorkoutStep? {
  guard let data = data, let goalData = data["goal"] as? [String: Any] else { return nil }
  let goal = createWorkoutGoal(from: goalData)
  return WorkoutStep(goal: goal)
}

@available(iOS 17.0, *)
private func createBlocks(from data: [[String: Any]]?) -> [IntervalBlock] {
  guard let data = data else { return [] }
  return data.map { blockData in
    let steps = (blockData["steps"] as? [[String: Any]])?.compactMap { createIntervalStep(from: $0) } ?? []
    return IntervalBlock(steps: steps, iterations: blockData["iterations"] as? Int ?? 1)
  }
}

@available(iOS 17.0, *)
private func createIntervalStep(from data: [String: Any]) -> IntervalStep? {
  guard let stepData = data["step"] as? [String: Any],
        let goalData = stepData["goal"] as? [String: Any] else { return nil }
  
  let purpose: IntervalStep.Purpose = data["purpose"] as? String == "recovery" ? .recovery : .work
  let goal = createWorkoutGoal(from: goalData)
  let workoutStep = WorkoutStep(goal: goal)
  return IntervalStep(purpose, step: workoutStep)
}