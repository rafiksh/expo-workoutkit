import ExpoModulesCore
import WorkoutKit
import HealthKit
import SwiftUI

extension Color {
  init?(hex: String) {
    let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var int: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&int)
    let a, r, g, b: UInt64
    switch hex.count {
    case 3: // RGB (12-bit)
      (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
    case 6: // RGB (24-bit)
      (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
    case 8: // ARGB (32-bit)
      (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
    default:
      return nil
    }
    
    self.init(
      .sRGB,
      red: Double(r) / 255,
      green: Double(g) / 255,
      blue:  Double(b) / 255,
      opacity: Double(a) / 255
    )
  }
}

public class ExpoWorkoutkitModule: Module {
  // Each module class must implement the definition function. The definition consists of components
  // that describes the module's functionality and behavior.
  // See https://docs.expo.dev/modules/module-api for more details about available components.
  public func definition() -> ModuleDefinition {
    // Sets the name of the module that JavaScript code will use to refer to the module. Takes a string as an argument.
    // Can be inferred from module's class name, but it's recommended to set it explicitly for clarity.
    // The module will be accessible from `requireNativeModule('ExpoWorkoutkit')` in JavaScript.
    Name("ExpoWorkoutkit")

    // MARK: - HealthKit import (read side, see ExpoHealthKitImport.swift)

    // Lets JS tell a binary whose Health queries take a date window from an
    // older one, where passing the extra arguments would throw.
    Constant("healthRangeQueries") { true }

    Function("isHealthDataAvailable") { () -> Bool in
      return HKHealthStore.isHealthDataAvailable()
    }

    AsyncFunction("requestHealthAuthorization") { (promise: Promise) in
      guard HKHealthStore.isHealthDataAvailable() else {
        promise.resolve(false)
        return
      }
      HealthImport.store.requestAuthorization(toShare: nil, read: HealthImport.readTypes) { granted, error in
        if let error {
          promise.reject("ERR_HEALTH_AUTH", error.localizedDescription)
        } else {
          promise.resolve(granted)
        }
      }
    }

    AsyncFunction("queryWorkouts") { (anchor: String?, limit: Int, fromISO: String?, toISO: String?, promise: Promise) in
      HealthImport.anchoredQuery(
        type: HKObjectType.workoutType(),
        anchor: HealthImport.decodeAnchor(anchor),
        limit: limit,
        from: HealthImport.date(fromISO),
        to: HealthImport.date(toISO)
      ) { result in
        switch result {
        case .failure(let error):
          promise.reject("ERR_HEALTH_QUERY", error.localizedDescription)
        case .success(let payload):
          let workouts = payload.samples
            .compactMap { $0 as? HKWorkout }
            .map(HealthImport.serializeWorkout)
          promise.resolve([
            "anchor": HealthImport.encodeAnchor(payload.newAnchor) as Any,
            "samples": workouts,
          ])
        }
      }
    }

    AsyncFunction("listWorkouts") { (beforeISO: String?, limit: Int, promise: Promise) in
      let before = beforeISO.flatMap { HealthImport.iso.date(from: $0) }
      HealthImport.listWorkouts(before: before, limit: limit) { result in
        switch result {
        case .failure(let error):
          promise.reject("ERR_HEALTH_QUERY", error.localizedDescription)
        case .success(let workouts):
          promise.resolve(workouts.map(HealthImport.serializeWorkout))
        }
      }
    }

    AsyncFunction("queryWorkoutRoute") { (uuid: String, _ allowConsent: Bool?, promise: Promise) in
      HealthImport.workoutRoute(uuid: uuid) { result in
        switch result {
        case .failure(let error): promise.reject("ERR_HEALTH_QUERY", error.localizedDescription)
        case .success(let points): promise.resolve(points)
        }
      }
    }

    AsyncFunction("queryWorkoutHeartRate") { (uuid: String, promise: Promise) in
      HealthImport.workoutHeartRate(uuid: uuid) { result in
        switch result {
        case .failure(let error): promise.reject("ERR_HEALTH_QUERY", error.localizedDescription)
        case .success(let points): promise.resolve(points)
        }
      }
    }

    AsyncFunction("queryWorkoutEvents") { (uuid: String, promise: Promise) in
      HealthImport.workoutEvents(uuid: uuid) { events in
        promise.resolve(events)
      }
    }

    AsyncFunction("queryQuantitySamples") { (metric: String, anchor: String?, limit: Int, fromISO: String?, toISO: String?, promise: Promise) in
      guard let (type, unit) = HealthImport.quantityType(for: metric) else {
        promise.reject("ERR_HEALTH_TYPE", "Unknown metric type: \(metric)")
        return
      }
      HealthImport.anchoredQuery(
        type: type,
        anchor: HealthImport.decodeAnchor(anchor),
        limit: limit,
        from: HealthImport.date(fromISO),
        to: HealthImport.date(toISO)
      ) { result in
        switch result {
        case .failure(let error):
          promise.reject("ERR_HEALTH_QUERY", error.localizedDescription)
        case .success(let payload):
          let samples = payload.samples
            .compactMap { $0 as? HKQuantitySample }
            .map { HealthImport.serializeQuantitySample($0, unit: unit) }
          promise.resolve([
            "anchor": HealthImport.encodeAnchor(payload.newAnchor) as Any,
            "samples": samples,
          ])
        }
      }
    }

    AsyncFunction("querySleepSamples") { (anchor: String?, limit: Int, fromISO: String?, toISO: String?, promise: Promise) in
      guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
        promise.reject("ERR_HEALTH_TYPE", "Sleep analysis type unavailable")
        return
      }
      HealthImport.anchoredQuery(
        type: sleepType,
        anchor: HealthImport.decodeAnchor(anchor),
        limit: limit,
        from: HealthImport.date(fromISO),
        to: HealthImport.date(toISO)
      ) { result in
        switch result {
        case .failure(let error):
          promise.reject("ERR_HEALTH_QUERY", error.localizedDescription)
        case .success(let payload):
          let samples = payload.samples
            .compactMap { $0 as? HKCategorySample }
            .map(HealthImport.serializeSleepSample)
          promise.resolve([
            "anchor": HealthImport.encodeAnchor(payload.newAnchor) as Any,
            "samples": samples,
          ])
        }
      }
    }


    // Enables the module to be used as a native view. Definition components that are accepted as part of the
    // view definition: Prop, Events.
    View(ExpoWorkoutkitView.self) {
      Prop("workoutPlan") { (view: ExpoWorkoutkitView, data: [String: Any]?) in
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
      
      Prop("label") { (view: ExpoWorkoutkitView, label: String?) in
        if let label = label {
          view.setLabel(label)
        }
      }
      
      Prop("buttonColor") { (view: ExpoWorkoutkitView, color: String?) in
        if let colorString = color {
          let color = Color(hex: colorString) ?? .blue
          view.setButtonColor(color)
        }
      }
      
      Prop("textColor") { (view: ExpoWorkoutkitView, color: String?) in
        if let colorString = color {
          let color = Color(hex: colorString) ?? .white
          view.setTextColor(color)
        }
      }
      
      Prop("cornerRadius") { (view: ExpoWorkoutkitView, radius: Double?) in
        if let radius = radius {
          view.setCornerRadius(CGFloat(radius))
        }
      }
      
      Prop("fontSize") { (view: ExpoWorkoutkitView, size: Double?) in
        if let size = size {
          view.setFontSize(CGFloat(size))
        }
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
  let warmup = createWorkoutStep(from: data["warmup"] as? [String: Any], activity: activity, location: location)
  let cooldown = createWorkoutStep(from: data["cooldown"] as? [String: Any], activity: activity, location: location)
  let blocks = createBlocks(from: data["blocks"] as? [[String: Any]], activity: activity, location: location)
  
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

// Unit strings mirror the WorkoutGoal/PacerWorkout unions in
// src/ExpoWorkoutkit.types.ts; every unit the types allow must be mapped
// here, otherwise the value silently lands in the fallback unit.
private func parseDurationUnit(_ unit: String?) -> UnitDuration {
  switch unit {
  case "seconds": return .seconds
  case "hours": return .hours
  default: return .minutes
  }
}

private func parseLengthUnit(_ unit: String?) -> UnitLength {
  switch unit {
  case "meters": return .meters
  case "yards": return .yards
  case "feet": return .feet
  case "miles": return .miles
  default: return .kilometers
  }
}

private func parseEnergyUnit(_ unit: String?) -> UnitEnergy {
  switch unit {
  case "calories": return .calories
  case "joules": return .joules
  case "kilojoules": return .kilojoules
  default: return .kilocalories
  }
}

@available(iOS 17.0, *)
private func createWorkoutGoal(from data: [String: Any]) -> WorkoutGoal {
  guard let type = data["type"] as? String, type != "open",
        let value = data["value"] as? Double else {
    return .open
  }
  let unit = data["unit"] as? String

  switch type {
  case "time":
    return .time(value, parseDurationUnit(unit))
  case "distance":
    return .distance(value, parseLengthUnit(unit))
  case "energy":
    return .energy(value, parseEnergyUnit(unit))
  default:
    return .open
  }
}

@available(iOS 17.0, *)
private func createDistance(from data: [String: Any]) -> Measurement<UnitLength> {
  let value = data["value"] as? Double ?? 5.0
  return Measurement(value: value, unit: parseLengthUnit(data["unit"] as? String))
}

@available(iOS 17.0, *)
private func createTime(from data: [String: Any]) -> Measurement<UnitDuration> {
  let value = data["value"] as? Double ?? 30.0
  return Measurement(value: value, unit: parseDurationUnit(data["unit"] as? String))
}

@available(iOS 17.0, *)
private func createWorkoutStep(
  from data: [String: Any]?,
  activity: HKWorkoutActivityType,
  location: HKWorkoutSessionLocationType
) -> WorkoutStep? {
  guard let data = data, let goalData = data["goal"] as? [String: Any] else { return nil }
  return buildStep(goalData: goalData, alertData: data["alert"] as? [String: Any], activity: activity, location: location)
}

@available(iOS 17.0, *)
private func buildStep(
  goalData: [String: Any],
  alertData: [String: Any]?,
  activity: HKWorkoutActivityType,
  location: HKWorkoutSessionLocationType
) -> WorkoutStep {
  let goal = createWorkoutGoal(from: goalData)
  guard let alertData, let alert = createWorkoutAlert(from: alertData) else {
    return WorkoutStep(goal: goal)
  }
  // An alert the activity can't carry (power on an outdoor walk, say) would
  // make the whole plan invalid; the step goes without it instead.
  guard CustomWorkout.supportsAlert(alert, activity: activity, location: location) else {
    return WorkoutStep(goal: goal)
  }
  return WorkoutStep(goal: goal, alert: alert)
}

// Shapes mirror the WorkoutAlert union in src/ExpoWorkoutkit.types.ts.
// Ranges need both bounds; a single bound becomes a threshold where
// WorkoutKit has one (speed, power, cadence). Heart rate has no threshold
// alert, so an open end is closed at a physiological bound.
@available(iOS 17.0, *)
private func createWorkoutAlert(from data: [String: Any]) -> (any WorkoutAlert)? {
  let min = data["min"] as? Double
  let max = data["max"] as? Double
  let metric: WorkoutAlertMetric = data["metric"] as? String == "average" ? .average : .current

  switch data["type"] as? String {
  case "heartRateZone":
    guard let zone = data["zone"] as? Int, (1...5).contains(zone) else { return nil }
    return HeartRateZoneAlert(zone: zone)
  case "heartRate":
    guard min != nil || max != nil else { return nil }
    let lo = min ?? 40, hi = max ?? 220
    guard lo <= hi else { return nil }
    return HeartRateRangeAlert.heartRate(lo...hi)
  case "speed":
    let unit = parseSpeedUnit(data["unit"] as? String)
    if let lo = min, let hi = max {
      guard lo <= hi else { return nil }
      return SpeedRangeAlert.speed(lo...hi, unit: unit, metric: metric)
    }
    guard let value = min ?? max else { return nil }
    return SpeedThresholdAlert.speed(value, unit: unit, metric: metric)
  case "powerZone":
    guard let zone = data["zone"] as? Int, zone >= 1 else { return nil }
    return PowerZoneAlert(zone: zone)
  case "power":
    if let lo = min, let hi = max {
      guard lo <= hi else { return nil }
      return PowerRangeAlert.power(lo...hi, unit: .watts)
    }
    guard let value = min ?? max else { return nil }
    return PowerThresholdAlert.power(value, unit: .watts)
  case "cadence":
    if let lo = min, let hi = max {
      guard lo <= hi else { return nil }
      return CadenceRangeAlert.cadence(lo...hi)
    }
    guard let value = min ?? max else { return nil }
    return CadenceThresholdAlert.cadence(value)
  default:
    return nil
  }
}

private func parseSpeedUnit(_ unit: String?) -> UnitSpeed {
  switch unit {
  case "kilometersPerHour": return .kilometersPerHour
  case "milesPerHour": return .milesPerHour
  default: return .metersPerSecond
  }
}

@available(iOS 17.0, *)
private func createBlocks(
  from data: [[String: Any]]?,
  activity: HKWorkoutActivityType,
  location: HKWorkoutSessionLocationType
) -> [IntervalBlock] {
  guard let data = data else { return [] }
  return data.map { blockData in
    let steps = (blockData["steps"] as? [[String: Any]])?.compactMap {
      createIntervalStep(from: $0, activity: activity, location: location)
    } ?? []
    return IntervalBlock(steps: steps, iterations: blockData["iterations"] as? Int ?? 1)
  }
}

@available(iOS 17.0, *)
private func createIntervalStep(
  from data: [String: Any],
  activity: HKWorkoutActivityType,
  location: HKWorkoutSessionLocationType
) -> IntervalStep? {
  guard let stepData = data["step"] as? [String: Any],
        let goalData = stepData["goal"] as? [String: Any] else { return nil }

  let purpose: IntervalStep.Purpose = data["purpose"] as? String == "recovery" ? .recovery : .work
  let step = buildStep(
    goalData: goalData,
    alertData: stepData["alert"] as? [String: Any],
    activity: activity,
    location: location
  )
  return IntervalStep(purpose, step: step)
}
