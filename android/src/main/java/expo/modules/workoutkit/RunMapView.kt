package expo.modules.workoutkit

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Color
import androidx.core.content.ContextCompat
import com.google.android.gms.maps.CameraUpdateFactory
import com.google.android.gms.maps.GoogleMap
import com.google.android.gms.maps.GoogleMapOptions
import com.google.android.gms.maps.MapView
import com.google.android.gms.maps.model.JointType
import com.google.android.gms.maps.model.LatLng
import com.google.android.gms.maps.model.LatLngBounds
import com.google.android.gms.maps.model.MapStyleOptions
import com.google.android.gms.maps.model.Polyline
import com.google.android.gms.maps.model.PolylineOptions
import com.google.android.gms.maps.model.RoundCap
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.viewevent.EventDispatcher
import expo.modules.kotlin.views.ExpoView

// Route map for the run player (live) and the finish/history screens
// (static), the twin of ios/RunMapView.swift on Google Maps. Live mode
// never receives coordinates from JS: it reads RunRecorder's in-memory
// track directly, and only while attached to a window. The line grows in
// frozen chunks plus one short live tail, so each new fix re-renders at
// most CHUNK points instead of the whole run.
@SuppressLint("ViewConstructor")
class RunMapView(context: Context, appContext: AppContext) : ExpoView(context, appContext) {
  private val onFollowChange by EventDispatcher<Map<String, Any>>()

  private val mapView = MapView(
    context,
    GoogleMapOptions()
      .rotateGesturesEnabled(false)
      .tiltGesturesEnabled(false)
      .compassEnabled(false)
      .mapToolbarEnabled(false)
      .zoomControlsEnabled(false),
  )
  private var map: GoogleMap? = null
  private var created = false
  private var resumed = false

  private var live = false
  private var follow = true
  private var staticRoute: List<List<LatLng>> = emptyList()
  private var lineColor: Int = Color.parseColor("#E5484D")

  // Live drawing state, per recorder segment.
  private val frozenUpTo = ArrayList<Int>()
  private val frozen = ArrayList<Polyline>()
  private val tails = ArrayList<Polyline>()
  private var observing = false
  private val appendListener: () -> Unit = { syncLive() }

  init {
    clipChildren = true
    addView(mapView, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
    mapView.onCreate(null)
    created = true
    mapView.getMapAsync { googleMap ->
      map = googleMap
      googleMap.uiSettings.apply {
        isRotateGesturesEnabled = false
        isTiltGesturesEnabled = false
        isCompassEnabled = false
        isMapToolbarEnabled = false
        isZoomControlsEnabled = false
        isMyLocationButtonEnabled = false
      }
      googleMap.isBuildingsEnabled = false
      googleMap.isIndoorEnabled = false
      googleMap.isTrafficEnabled = false
      // Muted: no points of interest or transit, the route is the subject.
      runCatching { googleMap.setMapStyle(MapStyleOptions(MUTED_STYLE)) }
      // A pan drops follow mode; JS shows a recenter control and sets
      // follow back to true when tapped.
      googleMap.setOnCameraMoveStartedListener { reason ->
        if (live && observing && reason == GoogleMap.OnCameraMoveStartedListener.REASON_GESTURE && follow) {
          follow = false
          onFollowChange(mapOf("following" to false))
        }
      }
      rebuild()
    }
  }

  override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
    super.onLayout(changed, left, top, right, bottom)
    mapView.layout(0, 0, right - left, bottom - top)
    if (changed && !live) fitStatic()
  }

  // MARK: - Props

  fun setLive(value: Boolean) {
    if (value == live) return
    live = value
    rebuild()
  }

  fun setFollow(value: Boolean) {
    follow = value
    applyTracking(animated = true)
  }

  fun setRoute(encoded: List<String>?) {
    staticRoute = (encoded ?: emptyList()).map(RunPolyline::decode).filter { it.size >= 2 }
    if (!live) rebuild()
  }

  fun setLineColor(hex: String?) {
    lineColor = hex?.let { runCatching { Color.parseColor(it) }.getOrNull() } ?: Color.parseColor("#E5484D")
    rebuild()
  }

  // MARK: - Lifecycle / visibility gating

  override fun onAttachedToWindow() {
    super.onAttachedToWindow()
    if (created && !resumed) {
      mapView.onStart()
      mapView.onResume()
      resumed = true
    }
    updateObserving()
  }

  override fun onDetachedFromWindow() {
    setObserving(false)
    if (resumed) {
      mapView.onPause()
      mapView.onStop()
      resumed = false
    }
    super.onDetachedFromWindow()
  }

  private fun updateObserving() {
    setObserving(live && isAttachedToWindow)
  }

  @SuppressLint("MissingPermission")
  private fun setObserving(on: Boolean) {
    if (on == observing) return
    observing = on
    val googleMap = map
    if (on) {
      RunRecorder.appendListeners.add(appendListener)
      if (googleMap != null && hasLocationPermission()) googleMap.isMyLocationEnabled = true
      syncLive()
      applyTracking(animated = false)
    } else {
      RunRecorder.appendListeners.remove(appendListener)
      googleMap?.let { runCatching { it.isMyLocationEnabled = false } }
    }
  }

  private fun hasLocationPermission(): Boolean =
    ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
      ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

  // MARK: - Drawing

  private fun rebuild() {
    val googleMap = map ?: return
    googleMap.clear()
    frozenUpTo.clear()
    frozen.clear()
    tails.clear()
    if (live) {
      updateObserving()
      if (observing) syncLive()
    } else {
      setObserving(false)
      staticRoute.forEach { googleMap.addPolyline(options(it)) }
      fitStatic()
    }
  }

  private fun options(points: List<LatLng>): PolylineOptions = PolylineOptions()
    .addAll(points)
    .color(lineColor)
    .width(5f * resources.displayMetrics.density)
    .startCap(RoundCap())
    .endCap(RoundCap())
    .jointType(JointType.ROUND)
    .geodesic(false)

  private fun syncLive() {
    val googleMap = map ?: return
    val segments = RunRecorder.segments
    tails.forEach { it.remove() }
    tails.clear()
    for ((i, coords) in segments.withIndex()) {
      if (i >= frozenUpTo.size) frozenUpTo.add(0)
      // Freeze full chunks; consecutive chunks share their joint point so
      // the line has no gaps.
      while (coords.size - frozenUpTo[i] > CHUNK) {
        val slice = coords.subList(frozenUpTo[i], frozenUpTo[i] + CHUNK + 1).toList()
        frozen.add(googleMap.addPolyline(options(slice)))
        frozenUpTo[i] += CHUNK
      }
      val rest = coords.subList(frozenUpTo[i], coords.size).take(CHUNK + 1)
      if (rest.size >= 2) tails.add(googleMap.addPolyline(options(rest)))
    }
    if (follow) applyTracking(animated = true)
  }

  private fun applyTracking(animated: Boolean) {
    val googleMap = map ?: return
    if (!live || !observing || !follow) return
    val last = RunRecorder.segments.lastOrNull { it.isNotEmpty() }?.lastOrNull() ?: return
    val update = CameraUpdateFactory.newLatLngZoom(last, 16f)
    if (animated) googleMap.animateCamera(update, 600, null) else googleMap.moveCamera(update)
  }

  private fun fitStatic() {
    val googleMap = map ?: return
    if (staticRoute.isEmpty() || width == 0 || height == 0) return
    val builder = LatLngBounds.Builder()
    staticRoute.forEach { seg -> seg.forEach { builder.include(it) } }
    val padding = (32 * resources.displayMetrics.density).toInt()
    runCatching {
      googleMap.moveCamera(CameraUpdateFactory.newLatLngBounds(builder.build(), width, height, padding))
    }
  }

  companion object {
    private const val CHUNK = 64
    private const val MUTED_STYLE = """
      [
        {"featureType":"poi","stylers":[{"visibility":"off"}]},
        {"featureType":"transit","stylers":[{"visibility":"off"}]},
        {"featureType":"road","elementType":"labels.icon","stylers":[{"visibility":"off"}]},
        {"featureType":"administrative","elementType":"labels","stylers":[{"visibility":"simplified"}]},
        {"elementType":"geometry","stylers":[{"saturation":-40},{"lightness":10}]}
      ]
    """
  }
}
