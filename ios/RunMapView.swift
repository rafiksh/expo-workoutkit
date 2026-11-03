import ExpoModulesCore
import MapKit

// Route map for the run player (live) and the finish/history screens
// (static). Live mode never receives coordinates from JS: it reads
// RunRecorder's in-memory track directly, and only while it is on screen
// with the app active. Pocket time costs nothing; the line catches up in one
// sync when the screen comes back.
//
// The line grows in frozen chunks plus one short live tail, so each new fix
// re-renders at most CHUNK points instead of the whole run.
final class RunMapView: ExpoView, MKMapViewDelegate {
  private static let chunk = 64

  private let map = MKMapView()
  let onFollowChange = EventDispatcher()

  private var live = false
  private var follow = true
  private var staticRoute: [[CLLocationCoordinate2D]] = []
  private var lineColor: UIColor = .systemRed
  // Live only: metres across the map's narrow side while following, so the
  // runner sees their street, not the city. Applied when following starts
  // (or comes back from a pan) and on the first fix if none was known yet.
  //
  // Following is ours, not MKUserTrackingMode: engaging .follow re-zooms to
  // MapKit's own default (about 1.3 km across) whatever region was set, so
  // the camera is zoomed once here and then only re-centred on each fix,
  // which keeps the span and any pinch the runner made.
  private var spanMeters: Double = 400
  private var zoomPending = true

  // Live drawing state, per recorder segment.
  private var frozenUpTo: [Int] = []
  private var tails: [MKPolyline] = []
  private var observing = false

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    clipsToBounds = true
    let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
    config.pointOfInterestFilter = .excludingAll
    config.showsTraffic = false
    map.preferredConfiguration = config
    map.isPitchEnabled = false
    map.isRotateEnabled = false
    map.showsCompass = false
    map.delegate = self
    addSubview(map)

    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(appActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    center.addObserver(self, selector: #selector(appInactive), name: UIApplication.willResignActiveNotification, object: nil)
  }

  deinit { NotificationCenter.default.removeObserver(self) }

  override func layoutSubviews() {
    super.layoutSubviews()
    map.frame = bounds
    // A region set while the map had no size reads back as the whole world;
    // the zoom waits for a real frame.
    if zoomPending { applyTracking() }
  }

  // MARK: - Props

  func setLive(_ value: Bool) {
    guard value != live else { return }
    live = value
    rebuild()
  }

  func setFollow(_ value: Bool) {
    follow = value
    applyTracking()
  }

  func setRoute(_ encoded: [String]?) {
    staticRoute = (encoded ?? []).map(RunPolyline.decode).filter { $0.count >= 2 }
    if !live { rebuild() }
  }

  func setSpanMeters(_ value: Double?) {
    let next = max(100, min(value ?? 400, 20_000))
    guard next != spanMeters else { return }
    spanMeters = next
    zoomPending = true
    applyTracking()
  }

  func setLineColor(_ hex: String?) {
    lineColor = hex.flatMap(UIColor.init(hex:)) ?? .systemRed
    rebuild()
  }

  // MARK: - Visibility gating

  override func didMoveToWindow() {
    super.didMoveToWindow()
    updateObserving()
  }

  @objc private func appActive() { updateObserving() }
  @objc private func appInactive() { setObserving(false) }

  private func updateObserving() {
    setObserving(live && window != nil && UIApplication.shared.applicationState == .active)
  }

  private func setObserving(_ on: Bool) {
    guard on != observing else { return }
    observing = on
    map.showsUserLocation = on
    if on {
      NotificationCenter.default.addObserver(
        self, selector: #selector(recorderAppended),
        name: RunRecorder.didAppendNotification, object: nil)
      syncLive()
      applyTracking()
    } else {
      NotificationCenter.default.removeObserver(self, name: RunRecorder.didAppendNotification, object: nil)
    }
  }

  @objc private func recorderAppended() { syncLive() }

  // MARK: - Drawing

  private func rebuild() {
    map.removeOverlays(map.overlays)
    frozenUpTo = []
    tails = []
    if live {
      updateObserving()
      if observing { syncLive() }
    } else {
      setObserving(false)
      staticRoute.forEach { map.addOverlay(MKPolyline(coordinates: $0, count: $0.count)) }
      fitStatic()
    }
  }

  private func syncLive() {
    let segments = RunRecorder.shared.segments
    map.removeOverlays(tails)
    tails = []
    for (i, coords) in segments.enumerated() {
      if i >= frozenUpTo.count { frozenUpTo.append(0) }
      // Freeze full chunks; consecutive chunks share their joint point so
      // the line has no gaps.
      while coords.count - frozenUpTo[i] > Self.chunk {
        let slice = Array(coords[frozenUpTo[i]...(frozenUpTo[i] + Self.chunk)])
        map.addOverlay(MKPolyline(coordinates: slice, count: slice.count))
        frozenUpTo[i] += Self.chunk
      }
      let rest = Array(coords[frozenUpTo[i]...].prefix(Self.chunk + 1))
      if rest.count >= 2 {
        let tail = MKPolyline(coordinates: rest, count: rest.count)
        tails.append(tail)
        map.addOverlay(tail)
      }
    }
  }

  private func applyTracking() {
    guard live, observing, follow else { return }
    zoomPending = true
    if let here = runnerCoordinate() { zoom(to: here) }
  }

  // Newest recorded fix, else the map's own blue dot; nil before any fix.
  private func runnerCoordinate() -> CLLocationCoordinate2D? {
    if let last = RunRecorder.shared.segments.last(where: { !$0.isEmpty })?.last { return last }
    if let loc = map.userLocation.location { return loc.coordinate }
    return nil
  }

  private func zoom(to center: CLLocationCoordinate2D) {
    if map.frame.isEmpty { map.frame = bounds }
    guard !map.frame.isEmpty else { return }
    zoomPending = false
    let region = MKCoordinateRegion(center: center, latitudinalMeters: spanMeters, longitudinalMeters: spanMeters)
    map.setRegion(map.regionThatFits(region), animated: false)
  }

  // The first fix after following starts zooms in (MapKit's default camera
  // is a whole country); every later one only re-centres.
  func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
    guard live, observing, follow, let loc = userLocation.location else { return }
    if zoomPending {
      zoom(to: loc.coordinate)
    } else {
      map.setCenter(loc.coordinate, animated: true)
    }
  }

  private func fitStatic() {
    guard let first = staticRoute.first, !first.isEmpty else { return }
    var rect = MKMapRect.null
    for coords in staticRoute {
      rect = rect.union(MKPolyline(coordinates: coords, count: coords.count).boundingMapRect)
    }
    map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 32, left: 32, bottom: 32, right: 32), animated: false)
  }

  // MARK: - MKMapViewDelegate

  func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
    let renderer = MKPolylineRenderer(overlay: overlay)
    renderer.strokeColor = lineColor
    renderer.lineWidth = 5
    renderer.lineCap = .round
    renderer.lineJoin = .round
    return renderer
  }

  // A pan drops follow; JS shows a recenter control and sets follow back
  // to true when tapped. Only a finger moves the camera off the runner:
  // a camera change while one of the map's gestures is live is a pan. A
  // pinch keeps following (the centre stays on the runner).
  func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
    guard live, observing, follow, userPanning() else { return }
    follow = false
    onFollowChange(["following": false])
  }

  private func userPanning() -> Bool {
    var views: [UIView] = [map]
    while let view = views.popLast() {
      for g in view.gestureRecognizers ?? [] where g is UIPanGestureRecognizer {
        if g.state == .began || g.state == .changed { return true }
      }
      views.append(contentsOf: view.subviews)
    }
    return false
  }
}

private extension UIColor {
  convenience init?(hex: String) {
    var s = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
    guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
    self.init(
      red: CGFloat((v >> 16) & 0xff) / 255,
      green: CGFloat((v >> 8) & 0xff) / 255,
      blue: CGFloat(v & 0xff) / 255,
      alpha: 1)
  }
}
