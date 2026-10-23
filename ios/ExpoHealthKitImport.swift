import ExpoModulesCore
import HealthKit

// HealthKit *read* side of the module: authorization plus anchored queries
// the app uses to incrementally import completed workouts and wellness
// samples. Anchors are HKQueryAnchor blobs round-tripped to JS as base64 so
// each sync only sees samples added since the previous one.
enum HealthImport {
  static let store = HKHealthStore()

  static let readTypes: Set<HKObjectType> = {
    var types: Set<HKObjectType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
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

  // Recent-first page of workouts for browse/pick UIs (anchored queries
  // can't sort). `before` (ISO date) pages older results.
  static func listWorkouts(
    before: Date?,
    limit: Int,
    completion: @escaping (Result<[HKWorkout], Error>) -> Void
  ) {
    let predicate = before.map {
      HKQuery.predicateForSamples(withStart: nil, end: $0, options: .strictStartDate)
    }
    let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
    let query = HKSampleQuery(
      sampleType: HKObjectType.workoutType(),
      predicate: predicate,
      limit: limit,
      sortDescriptors: [sort]
    ) { _, samples, error in
      if let error {
        completion(.failure(error))
        return
      }
      completion(.success(samples?.compactMap { $0 as? HKWorkout } ?? []))
    }
    store.execute(query)
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

  // One workout by its uuid, for the per-workout reads below.
  static func workout(uuid: String, completion: @escaping (HKWorkout?) -> Void) {
    guard let id = UUID(uuidString: uuid) else {
      completion(nil)
      return
    }
    let query = HKSampleQuery(
      sampleType: HKObjectType.workoutType(),
      predicate: HKQuery.predicateForObject(with: id),
      limit: 1,
      sortDescriptors: nil
    ) { _, samples, _ in
      completion(samples?.first as? HKWorkout)
    }
    store.execute(query)
  }

  // The GPS trace a workout was recorded with, as the app that recorded it
  // (Nike Run Club, Strava, the Watch) wrote it to Health: every fix with
  // seconds since the workout started, position, altitude and horizontal
  // accuracy. Routes live beside the workout as their own series objects;
  // a workout may carry several (rare) and they are read in order. Empty
  // when there is none (indoor, or the recorder kept the route to itself).
  static func workoutRoute(
    uuid: String,
    completion: @escaping (Result<[[String: Any]], Error>) -> Void
  ) {
    workout(uuid: uuid) { workout in
      guard let workout else {
        completion(.success([]))
        return
      }
      let routeQuery = HKSampleQuery(
        sampleType: HKSeriesType.workoutRoute(),
        predicate: HKQuery.predicateForObjects(from: workout),
        limit: HKObjectQueryNoLimit,
        sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
      ) { _, samples, error in
        if let error {
          completion(.failure(error))
          return
        }
        let routes = samples?.compactMap { $0 as? HKWorkoutRoute } ?? []
        guard !routes.isEmpty else {
          completion(.success([]))
          return
        }
        var points: [[String: Any]] = []
        var remaining = routes.count
        let start = workout.startDate
        for route in routes {
          let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
            if let error {
              completion(.failure(error))
              return
            }
            for loc in locations ?? [] {
              var point: [String: Any] = [
                "t": loc.timestamp.timeIntervalSince(start),
                "lat": loc.coordinate.latitude,
                "lng": loc.coordinate.longitude,
                "acc": loc.horizontalAccuracy,
              ]
              if loc.verticalAccuracy >= 0 { point["alt"] = loc.altitude }
              points.append(point)
            }
            if done {
              remaining -= 1
              if remaining == 0 {
                completion(.success(points.sorted { ($0["t"] as? Double ?? 0) < ($1["t"] as? Double ?? 0) }))
              }
            }
          }
          store.execute(query)
        }
      }
      store.execute(routeQuery)
    }
  }

  // Heart rate through the workout: every sample in its window, seconds
  // since the start and beats per minute, oldest first.
  static func workoutHeartRate(
    uuid: String,
    completion: @escaping (Result<[[String: Any]], Error>) -> Void
  ) {
    workout(uuid: uuid) { workout in
      guard let workout, let type = HKObjectType.quantityType(forIdentifier: .heartRate) else {
        completion(.success([]))
        return
      }
      let bpm = HKUnit.count().unitDivided(by: .minute())
      let query = HKSampleQuery(
        sampleType: type,
        predicate: HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: []),
        limit: HKObjectQueryNoLimit,
        sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
      ) { _, samples, error in
        if let error {
          completion(.failure(error))
          return
        }
        let points = (samples?.compactMap { $0 as? HKQuantitySample } ?? []).map { sample -> [String: Any] in
          [
            "t": sample.startDate.timeIntervalSince(workout.startDate),
            "bpm": sample.quantity.doubleValue(for: bpm),
          ]
        }
        completion(.success(points))
      }
      store.execute(query)
    }
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
