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
    guard live, observing else { return }
    map.setUserTrackingMode(follow ? .follow : .none, animated: true)
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

  // A pan drops follow mode; JS shows a recenter control and sets follow
  // back to true when tapped.
  func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
    guard live, observing else { return }
    let following = mode != .none
    if following != follow {
      follow = following
      onFollowChange(["following": following])
    }
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
