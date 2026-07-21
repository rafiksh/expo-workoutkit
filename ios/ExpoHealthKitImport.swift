import ExpoModulesCore
import HealthKit

// HealthKit *read* side of the module: authorization plus anchored queries
// the app uses to incrementally import completed workouts and wellness
// samples. Anchors are HKQueryAnchor blobs round-tripped to JS as base64 so
// each sync only sees samples added since the previous one.
enum HealthImport {
  static let store = HKHealthStore()

  static let readTypes: Set<HKObjectType> = {
    var types: Set<HKObjectType> = [HKObjectType.workoutType()]
    let quantities: [HKQuantityTypeIdentifier] = [
      .heartRate,
      .heartRateVariabilitySDNN,
      .restingHeartRate,
      .bodyMass,
      .vo2Max,
      .activeEnergyBurned,
      .distanceWalkingRunning,
      .distanceCycling,
      .distanceSwimming,
    ]
    for id in quantities {
      if let type = HKObjectType.quantityType(forIdentifier: id) { types.insert(type) }
    }
    if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
    return types
  }()

  static let iso = ISO8601DateFormatter()

  static func encodeAnchor(_ anchor: HKQueryAnchor?) -> String? {
    guard let anchor,
          let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    else { return nil }
    return data.base64EncodedString()
  }

  static func decodeAnchor(_ base64: String?) -> HKQueryAnchor? {
    guard let base64, let data = Data(base64Encoded: base64) else { return nil }
    return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
  }

  // Paceo metric id -> (HealthKit type, canonical unit the value is returned
  // in). The ids intentionally match the server's HEALTH_METRIC_TYPES so the
  // JS layer can pass them straight through.
  static func quantityType(for metric: String) -> (HKQuantityType, HKUnit)? {
    let bpm = HKUnit.count().unitDivided(by: .minute())
    let mlPerKgMin = HKUnit.literUnit(with: .milli)
      .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
    switch metric {
    case "hrv":
      guard let type = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else { return nil }
      return (type, HKUnit.secondUnit(with: .milli))
    case "resting_hr":
      guard let type = HKObjectType.quantityType(forIdentifier: .restingHeartRate) else { return nil }
      return (type, bpm)
    case "weight":
      guard let type = HKObjectType.quantityType(forIdentifier: .bodyMass) else { return nil }
      return (type, HKUnit.gramUnit(with: .kilo))
    case "vo2max":
      guard let type = HKObjectType.quantityType(forIdentifier: .vo2Max) else { return nil }
      return (type, mlPerKgMin)
    default:
      return nil
    }
  }

  static func anchoredQuery(
    type: HKSampleType,
    anchor: HKQueryAnchor?,
    limit: Int,
    completion: @escaping (Result<(samples: [HKSample], newAnchor: HKQueryAnchor?), Error>) -> Void
  ) {
    let query = HKAnchoredObjectQuery(
      type: type,
      predicate: nil,
      anchor: anchor,
      limit: limit
    ) { _, samples, _, newAnchor, error in
      if let error {
        completion(.failure(error))
        return
      }
      completion(.success((samples ?? [], newAnchor)))
    }
    store.execute(query)
  }

  static func serializeWorkout(_ workout: HKWorkout) -> [String: Any] {
    var dict: [String: Any] = [
      "uuid": workout.uuid.uuidString,
      "activityTypeRaw": Int(workout.workoutActivityType.rawValue),
      "startDate": iso.string(from: workout.startDate),
      "endDate": iso.string(from: workout.endDate),
      "durationS": Int(workout.duration.rounded()),
      "sourceName": workout.sourceRevision.source.name,
      "sourceBundleId": workout.sourceRevision.source.bundleIdentifier,
    ]

    var distanceM: Double?
    var calories: Double?

    if #available(iOS 16.0, *) {
      let distanceIds: [HKQuantityTypeIdentifier] = [
        .distanceWalkingRunning, .distanceCycling, .distanceSwimming,
      ]
      for id in distanceIds {
        if let type = HKObjectType.quantityType(forIdentifier: id),
           let sum = workout.statistics(for: type)?.sumQuantity() {
          distanceM = sum.doubleValue(for: .meter())
          break
        }
      }
      if let type = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned),
         let sum = workout.statistics(for: type)?.sumQuantity() {
        calories = sum.doubleValue(for: .kilocalorie())
      }
      if let type = HKObjectType.quantityType(forIdentifier: .heartRate),
         let stats = workout.statistics(for: type) {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        if let avg = stats.averageQuantity()?.doubleValue(for: bpm) { dict["avgHr"] = avg }
        if let max = stats.maximumQuantity()?.doubleValue(for: bpm) { dict["maxHr"] = max }
      }
    }
    if distanceM == nil { distanceM = workout.totalDistance?.doubleValue(for: .meter()) }
    if calories == nil { calories = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()) }

    if let distanceM { dict["distanceM"] = distanceM }
    if let calories { dict["calories"] = calories }
    if let ascended = workout.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity {
      dict["elevationGainM"] = ascended.doubleValue(for: .meter())
    }
    return dict
  }

  static func serializeQuantitySample(_ sample: HKQuantitySample, unit: HKUnit) -> [String: Any] {
    return [
      "uuid": sample.uuid.uuidString,
      "value": sample.quantity.doubleValue(for: unit),
      "measuredAt": iso.string(from: sample.endDate),
      "sourceName": sample.sourceRevision.source.name,
    ]
  }

  static func serializeSleepSample(_ sample: HKCategorySample) -> [String: Any] {
    return [
      "uuid": sample.uuid.uuidString,
      "value": sample.value,
      "startDate": iso.string(from: sample.startDate),
      "endDate": iso.string(from: sample.endDate),
      "sourceName": sample.sourceRevision.source.name,
    ]
  }
}
