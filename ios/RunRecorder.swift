import CoreLocation
import HealthKit

// Records one outdoor/indoor cardio session on the iPhone: an
// HKWorkoutBuilder (so the run lands in Apple Health as a real workout with
// its route), fed by our own GPS stream for distance, pace and the route.
//
// Not HKWorkoutSession: a standalone iPhone session + HKLiveWorkoutBuilder is
// iOS 26+ (on 17-25 the phone can only mirror a Watch session). The plain
// builder works on every version we ship; we add the distance samples and
// pause/resume events ourselves. Backgrounding is kept alive by the location
// background mode (outdoor) and the cue audio loop (indoor).
//
// Battery is the design constraint. Swift owns every coordinate: distance,
// route builder, the live map line and the simplified polyline all read the
// in-memory track here. JS only ever receives a small metrics dictionary,
// throttled to 1 Hz. GPS uses the fitness activity type at Best accuracy
// (never BestForNavigation, which adds compass/motion fusion) and stops the
// instant the run ends. Indoor runs never start it.
//
// Everything runs on the main thread: CLLocationManager delegates arrive
// there, and HealthKit callbacks hop back to it, so no locks are needed.
final class RunRecorder: NSObject {
  static let shared = RunRecorder()
  static let didAppendNotification = Notification.Name("RunRecorderDidAppend")

  enum State: String { case idle, running, paused, ended }

  // Set by the module; called on main, at most once per second.
  var onUpdate: (([String: Any]) -> Void)?
  var onState: ((String) -> Void)?

  private(set) var state: State = .idle
  // Accepted fixes split into segments: a pause ends a segment so the map
  // and the simplified route never draw a straight line across a gap.
  private(set) var segments: [[CLLocationCoordinate2D]] = []

  private let store = HealthImport.store
  private var builder: HKWorkoutBuilder?
  private var routeBuilder: HKWorkoutRouteBuilder?
  private var healthEnabled = false
  private var activity: HKWorkoutActivityType = .running
  private var outdoor = true

  private lazy var location: CLLocationManager = {
    let manager = CLLocationManager()
    manager.delegate = self
    manager.activityType = .fitness
    manager.desiredAccuracy = kCLLocationAccuracyBest
    // The GPS chip runs either way; the filter only spares callbacks while
    // standing at a light.
    manager.distanceFilter = 2
    manager.pausesLocationUpdatesAutomatically = false
    return manager
  }()
  private var permissionWaiters: [(CLAuthorizationStatus) -> Void] = []

  private var distanceM: Double = 0
  private var lastAccepted: CLLocation?
  private var lastFixAt: Date?
  private var lastAccuracyM: Double?
  // Recent accepted fixes for current pace, trimmed to the pace window.
  private var paceWindow: [CLLocation] = []
  // Pending writes, flushed in batches so HealthKit sees a few calls a
  // minute instead of one per fix.
  private var pendingRoute: [CLLocation] = []
  private var pendingDistanceM: Double = 0
  private var pendingDistanceStart: Date?
  private var lastFlushAt = Date.distantPast
  private var lastEmitAt = Date.distantPast
  private var stoppedAt: Date?
  // Kept past finish() (which drops the builder) so totals stay readable.
  private var finalElapsedS: Double?

  private static let paceWindowS: TimeInterval = 20
  private static let flushEveryS: TimeInterval = 15
  private static let maxAccuracyM: Double = 25
  private static let maxStaleS: TimeInterval = 10

  // MARK: - Permissions

  var locationStatus: String {
    switch location.authorizationStatus {
    case .authorizedAlways, .authorizedWhenInUse: return "granted"
    case .denied, .restricted: return "denied"
    default: return "undetermined"
    }
  }

  // When In Use is enough: a session started in the foreground with the
  // location background mode keeps updating while locked (blue pill).
  func requestLocation(_ done: @escaping (String) -> Void) {
    guard location.authorizationStatus == .notDetermined else {
      done(locationStatus)
      return
    }
    permissionWaiters.append { [weak self] _ in done(self?.locationStatus ?? "denied") }
    location.requestWhenInUseAuthorization()
  }

  static let shareTypes: Set<HKSampleType> = {
    var types: Set<HKSampleType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
    for id in [HKQuantityTypeIdentifier.distanceWalkingRunning, .distanceCycling, .activeEnergyBurned] {
      if let type = HKObjectType.quantityType(forIdentifier: id) { types.insert(type) }
    }
    return types
  }()

  // One combined sheet: write the workout + route, read what import needs.
  func requestHealth(_ done: @escaping (Bool) -> Void) {
    guard HKHealthStore.isHealthDataAvailable() else { return done(false) }
    store.requestAuthorization(toShare: Self.shareTypes, read: HealthImport.readTypes) { _, _ in
      DispatchQueue.main.async { done(self.canWriteWorkouts) }
    }
  }

  // Unlike read access, iOS does report write access, so a refusal can be
  // told apart from never asked and the app can point at the Health app.
  var healthWriteStatus: String {
    guard HKHealthStore.isHealthDataAvailable() else { return "denied" }
    switch store.authorizationStatus(for: HKObjectType.workoutType()) {
    case .sharingAuthorized: return "granted"
    case .sharingDenied: return "denied"
    default: return "undetermined"
    }
  }

  var canWriteWorkouts: Bool {
    HKHealthStore.isHealthDataAvailable()
      && store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
  }

  // MARK: - Lifecycle

  func start(activity: String, outdoor: Bool) {
    guard state == .idle || state == .ended else { return }
    reset()
    self.activity = Self.activityType(activity)
    self.outdoor = outdoor

    // Health is optional: without write access we still record GPS and
    // the run saves to Paceo, it just doesn't land in Apple Health.
    healthEnabled = canWriteWorkouts
    if healthEnabled {
      let config = HKWorkoutConfiguration()
      config.activityType = self.activity
      config.locationType = outdoor ? .outdoor : .indoor
      let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
      self.builder = builder
      if outdoor { routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: .local()) }
      builder.beginCollection(withStart: Date()) { _, _ in }
    }

    if outdoor && locationStatus == "granted" {
      location.allowsBackgroundLocationUpdates = true
      location.showsBackgroundLocationIndicator = true
      location.startUpdatingLocation()
    }
    setState(.running)
  }

  func pause() {
    guard state == .running else { return }
    flush(force: true)
    addEvent(.pause)
    lastAccepted = nil
    paceWindow.removeAll()
    setState(.paused)
  }

  func resume() {
    guard state == .paused else { return }
    addEvent(.resume)
    segments.append([])
    setState(.running)
  }

  // Stops recording (GPS off, clock frozen) without saving anything: the
  // athlete is on the finish screen choosing Save or Discard, and GPS has
  // no business running while they decide.
  func stop() {
    guard state == .running || state == .paused else { return }
    stopLocation()
    flush(force: true)
    stoppedAt = Date()
    setState(.ended)
  }

  // Saves to Health when allowed (stopping first if still recording).
  // Resolves with the totals plus the simplified, encoded polyline for the
  // server. A second call resolves the totals without saving twice.
  func finish(_ done: @escaping ([String: Any]) -> Void) {
    stop()
    guard let builder, let end = stoppedAt else { return done(summary(workoutId: nil)) }
    self.builder = nil
    builder.endCollection(withEnd: end) { _, _ in
      builder.finishWorkout { workout, _ in
        guard let workout else {
          DispatchQueue.main.async { done(self.summary(workoutId: nil)) }
          return
        }
        let resolve = { DispatchQueue.main.async { done(self.summary(workoutId: workout.uuid.uuidString)) } }
        if let route = self.routeBuilder, !self.segments.joined().isEmpty {
          route.finishRoute(with: workout, metadata: nil) { _, _ in resolve() }
        } else {
          resolve()
        }
      }
    }
  }

  func discard() {
    stopLocation()
    builder?.discardWorkout()
    routeBuilder?.discard()
    reset()
    setState(.idle)
  }

  // MARK: - Internals

  private var distanceType: HKQuantityType? {
    HKObjectType.quantityType(
      forIdentifier: activity == .cycling ? .distanceCycling : .distanceWalkingRunning)
  }

  private static func activityType(_ name: String) -> HKWorkoutActivityType {
    switch name {
    case "walking": return .walking
    case "cycling": return .cycling
    case "hiking": return .hiking
    default: return .running
    }
  }

  // Any plausible human speed for the sport; anything faster is a GPS jump.
  private var maxSpeedMS: Double { activity == .cycling ? 30 : 12 }

  private func addEvent(_ type: HKWorkoutEventType) {
    let event = HKWorkoutEvent(type: type, dateInterval: DateInterval(start: Date(), duration: 0), metadata: nil)
    builder?.addWorkoutEvents([event]) { _, _ in }
  }

  private func reset() {
    builder = nil
    routeBuilder = nil
    segments = [[]]
    distanceM = 0
    lastAccepted = nil
    lastFixAt = nil
    lastAccuracyM = nil
    paceWindow.removeAll()
    pendingRoute.removeAll()
    pendingDistanceM = 0
    pendingDistanceStart = nil
    lastEmitAt = .distantPast
    stoppedAt = nil
    finalElapsedS = nil
  }

  private func stopLocation() {
    location.stopUpdatingLocation()
    location.allowsBackgroundLocationUpdates = false
  }

  private func setState(_ next: State) {
    state = next
    onState?(next.rawValue)
    emit(force: true)
  }

  private func accept(_ fix: CLLocation) {
    lastFixAt = fix.timestamp
    lastAccuracyM = fix.horizontalAccuracy
    guard state == .running,
          fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= Self.maxAccuracyM,
          -fix.timestamp.timeIntervalSinceNow <= Self.maxStaleS
    else { return }

    if let last = lastAccepted {
      let dt = fix.timestamp.timeIntervalSince(last.timestamp)
      guard dt > 0 else { return }
      let d = fix.distance(from: last)
      if d / dt > maxSpeedMS { return }
      distanceM += d
      pendingDistanceM += d
      if pendingDistanceStart == nil { pendingDistanceStart = last.timestamp }
    }
    lastAccepted = fix
    segments[segments.count - 1].append(fix.coordinate)
    pendingRoute.append(fix)
    paceWindow.append(fix)
    while let first = paceWindow.first,
          fix.timestamp.timeIntervalSince(first.timestamp) > Self.paceWindowS {
      paceWindow.removeFirst()
    }
    NotificationCenter.default.post(name: Self.didAppendNotification, object: nil)
    flush(force: false)
    emit(force: false)
  }

  private func flush(force: Bool) {
    guard force || Date().timeIntervalSince(lastFlushAt) >= Self.flushEveryS else { return }
    lastFlushAt = Date()
    if let routeBuilder, !pendingRoute.isEmpty {
      routeBuilder.insertRouteData(pendingRoute) { _, _ in }
    }
    pendingRoute.removeAll()
    if let builder, let type = distanceType, pendingDistanceM > 0,
       let start = pendingDistanceStart, let end = lastAccepted?.timestamp, end > start {
      let sample = HKQuantitySample(
        type: type,
        quantity: HKQuantity(unit: .meter(), doubleValue: pendingDistanceM),
        start: start,
        end: end)
      builder.add([sample]) { _, _ in }
    }
    pendingDistanceM = 0
    pendingDistanceStart = nil
  }

  private var currentPaceSecPerKm: Double? {
    guard let first = paceWindow.first, let last = paceWindow.last, first !== last else { return nil }
    var d = 0.0
    for i in 1..<paceWindow.count { d += paceWindow[i].distance(from: paceWindow[i - 1]) }
    let dt = last.timestamp.timeIntervalSince(first.timestamp)
    // Under ~1 km/h is standing, not a pace worth showing.
    guard d > 5, dt > 0, d / dt > 0.3 else { return nil }
    return dt / (d / 1000)
  }

  private var gpsSignal: String {
    guard outdoor else { return "off" }
    guard let at = lastFixAt, -at.timeIntervalSinceNow <= Self.maxStaleS,
          let accuracy = lastAccuracyM, accuracy >= 0 else { return "none" }
    if accuracy <= 10 { return "good" }
    if accuracy <= Self.maxAccuracyM { return "fair" }
    return "weak"
  }

  private func metrics() -> [String: Any] {
    var out: [String: Any] = [
      "state": state.rawValue,
      "distanceM": distanceM,
      "gps": gpsSignal,
      "health": healthEnabled,
    ]
    if let builder { finalElapsedS = builder.elapsedTime(at: stoppedAt ?? Date()) }
    if let elapsed = finalElapsedS { out["elapsedS"] = elapsed }
    if let pace = currentPaceSecPerKm { out["paceSecPerKm"] = pace }
    return out
  }

  private func emit(force: Bool) {
    guard force || Date().timeIntervalSince(lastEmitAt) >= 1 else { return }
    lastEmitAt = Date()
    onUpdate?(metrics())
  }

  func snapshot() -> [String: Any] { metrics() }

  private func summary(workoutId: String?) -> [String: Any] {
    let simplified = segments
      .filter { $0.count >= 2 }
      .map { RunPolyline.encode(RunPolyline.simplify($0, toleranceM: 3)) }
    var out = metrics()
    out["healthWorkoutId"] = workoutId as Any
    out["route"] = simplified
    return out
  }
}

extension RunRecorder: CLLocationManagerDelegate {
  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    locations.forEach(accept)
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    guard manager.authorizationStatus != .notDetermined else { return }
    let waiters = permissionWaiters
    permissionWaiters.removeAll()
    waiters.forEach { $0(manager.authorizationStatus) }
  }
}
