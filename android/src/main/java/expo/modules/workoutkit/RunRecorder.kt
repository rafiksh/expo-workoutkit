package expo.modules.workoutkit

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.os.Looper
import androidx.core.content.ContextCompat
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.records.DistanceRecord
import androidx.health.connect.client.records.ExerciseRoute
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.metadata.Device
import androidx.health.connect.client.records.metadata.Metadata
import androidx.health.connect.client.units.Length
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.maps.model.LatLng
import java.time.Instant
import java.time.ZoneId
import kotlin.math.roundToLong

// Records one outdoor/indoor cardio session on the phone, the twin of
// ios/RunRecorder.swift: fused GPS for distance, pace and the route, and a
// Health Connect exercise session (with its route) written once at finish.
//
// Battery is the design constraint, same as iOS. Kotlin owns every
// coordinate: distance, the live map line and the simplified polyline all
// read the in-memory track here. JS only ever receives a small metrics map,
// throttled to 1 Hz. GPS runs at high accuracy with a 2 m distance filter
// and stops the instant the run ends; indoor runs never start it.
//
// Backgrounding: the workout foreground service (type location) keeps the
// process and these updates alive with the screen off. Everything runs on
// the main looper, so no locks are needed.
object RunRecorder {
  enum class State(val wire: String) { IDLE("idle"), RUNNING("running"), PAUSED("paused"), ENDED("ended") }

  // Set by the module; called on main, at most once per second.
  var onUpdate: ((Map<String, Any?>) -> Unit)? = null
  var onState: ((String) -> Unit)? = null
  // The live map subscribes here; fired after every accepted fix.
  val appendListeners = LinkedHashSet<() -> Unit>()

  var state: State = State.IDLE
    private set
  // Accepted fixes split into segments: a pause ends a segment so the map
  // and the simplified route never draw a straight line across a gap.
  val segments = ArrayList<ArrayList<LatLng>>()

  private var context: Context? = null
  private var fused: FusedLocationProviderClient? = null
  private var activity = "running"
  private var outdoor = true
  private var healthEnabled = false
  private var locationRunning = false

  private var distanceM = 0.0
  private var lastAccepted: Location? = null
  private var lastFixAtMs: Long? = null
  private var lastAccuracyM: Float? = null
  private val paceWindow = ArrayList<Location>()
  // Every accepted fix, for the Health Connect route written at finish.
  private val track = ArrayList<Location>()
  private var startedAtMs = 0L
  private var stoppedAtMs: Long? = null
  private var lastEmitAtMs = 0L
  // Moving time: what's banked from earlier running stretches, plus the
  // current one since runningSince. Pauses never count.
  private var movingBankS = 0.0
  private var runningSinceMs: Long? = null
  // The light time series behind the charts and splits: one sample every
  // SAMPLE_EVERY_S of moving time, plus one at each pause and at the end.
  private val sampleT = ArrayList<Double>()
  private val sampleD = ArrayList<Double>()
  private val sampleAlt = ArrayList<Double?>()
  private var lastAltitude: Double? = null

  private const val PACE_WINDOW_MS = 20_000L
  private const val MAX_ACCURACY_M = 25f
  private const val MAX_STALE_MS = 10_000L
  private const val SAMPLE_EVERY_S = 5.0
  // Phone altitude is GPS-only guesswork past this; better blank than a hill.
  private const val MAX_VERTICAL_ACCURACY_M = 20f

  fun attach(context: Context) {
    if (this.context == null) {
      this.context = context.applicationContext
      fused = LocationServices.getFusedLocationProviderClient(context.applicationContext)
    }
  }

  // MARK: - Permissions

  fun locationStatus(): String {
    val ctx = context ?: return "undetermined"
    val fine = ContextCompat.checkSelfPermission(ctx, Manifest.permission.ACCESS_FINE_LOCATION)
    val coarse = ContextCompat.checkSelfPermission(ctx, Manifest.permission.ACCESS_COARSE_LOCATION)
    if (fine == PackageManager.PERMISSION_GRANTED || coarse == PackageManager.PERMISSION_GRANTED) return "granted"
    // Android can't tell "never asked" from "refused" without an Activity;
    // the module layers that on top with shouldShowRequestPermissionRationale.
    return "undetermined"
  }

  private fun hasLocation(): Boolean = locationStatus() == "granted"

  fun canWriteWorkouts(): Boolean {
    val ctx = context ?: return false
    return HealthStore.hasWritePermissions(ctx)
  }

  // MARK: - Lifecycle

  fun start(activity: String, outdoor: Boolean) {
    if (state != State.IDLE && state != State.ENDED) return
    reset()
    this.activity = activity
    this.outdoor = outdoor
    // Health is optional: without write access we still record GPS and
    // the run saves to the app, it just doesn't land in Health Connect.
    healthEnabled = canWriteWorkouts()
    startedAtMs = System.currentTimeMillis()
    context?.let { WorkoutForegroundService.setRecorderActive(it, needsLocation = outdoor && hasLocation()) }
    if (outdoor && hasLocation()) startLocation()
    runningSinceMs = startedAtMs
    // The series starts at zero so the first split has its true start.
    sample(force = true)
    setState(State.RUNNING)
  }

  fun pause() {
    if (state != State.RUNNING) return
    bankMoving()
    sample(force = true)
    lastAccepted = null
    paceWindow.clear()
    setState(State.PAUSED)
  }

  fun resume() {
    if (state != State.PAUSED) return
    segments.add(ArrayList())
    runningSinceMs = System.currentTimeMillis()
    setState(State.RUNNING)
  }

  // Stops recording (GPS off, clock frozen) without saving anything: the
  // athlete is on the finish screen choosing Save or Discard.
  fun stop() {
    if (state != State.RUNNING && state != State.PAUSED) return
    stopLocation()
    bankMoving()
    sample(force = true)
    stoppedAtMs = System.currentTimeMillis()
    context?.let { WorkoutForegroundService.setRecorderActive(it, needsLocation = false, active = false) }
    setState(State.ENDED)
  }

  // Saves to Health Connect when allowed (stopping first if still
  // recording). Resolves with the totals plus the simplified, encoded
  // polyline for the server. A second call resolves the totals without
  // saving twice.
  suspend fun finish(): Map<String, Any?> {
    stop()
    if (!healthEnabled) return summary(null)
    healthEnabled = false
    val ctx = context ?: return summary(null)
    val end = stoppedAtMs ?: System.currentTimeMillis()
    val id = try {
      HealthStore.writeSession(
        ctx,
        activity = activity,
        startMs = startedAtMs,
        endMs = end,
        distanceM = distanceM,
        route = if (outdoor) track.toList() else emptyList(),
      )
    } catch (e: Exception) {
      null
    }
    return summary(id)
  }

  fun discard() {
    stopLocation()
    context?.let { WorkoutForegroundService.setRecorderActive(it, needsLocation = false, active = false) }
    reset()
    setState(State.IDLE)
  }

  // MARK: - Internals

  // Any plausible human speed for the sport; anything faster is a GPS jump.
  private val maxSpeedMS: Double get() = if (activity == "cycling") 30.0 else 12.0

  private val movingS: Double
    get() = movingBankS + (runningSinceMs?.let { (System.currentTimeMillis() - it) / 1000.0 } ?: 0.0)

  private fun bankMoving() {
    movingBankS = movingS
    runningSinceMs = null
  }

  private fun sample(force: Boolean) {
    val t = movingS
    val last = sampleT.lastOrNull()
    if (!force && last != null && t - last < SAMPLE_EVERY_S) return
    // Never two samples at one instant (a pause right after a sample).
    if (last != null && t - last < 0.5) return
    sampleT.add((t * 10).roundToLong() / 10.0)
    sampleD.add((distanceM * 10).roundToLong() / 10.0)
    sampleAlt.add(lastAltitude?.let { (it * 10).roundToLong() / 10.0 })
  }

  private fun reset() {
    segments.clear()
    segments.add(ArrayList())
    distanceM = 0.0
    lastAccepted = null
    lastFixAtMs = null
    lastAccuracyM = null
    paceWindow.clear()
    track.clear()
    lastEmitAtMs = 0L
    stoppedAtMs = null
    movingBankS = 0.0
    runningSinceMs = null
    sampleT.clear()
    sampleD.clear()
    sampleAlt.clear()
    lastAltitude = null
  }

  private val callback = object : LocationCallback() {
    override fun onLocationResult(result: LocationResult) {
      result.locations.forEach { accept(it) }
    }
  }

  @SuppressLint("MissingPermission")
  private fun startLocation() {
    val client = fused ?: return
    if (locationRunning) return
    val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 1000L)
      .setMinUpdateDistanceMeters(2f)
      .setWaitForAccurateLocation(false)
      .build()
    client.requestLocationUpdates(request, callback, Looper.getMainLooper())
    locationRunning = true
  }

  private fun stopLocation() {
    if (!locationRunning) return
    fused?.removeLocationUpdates(callback)
    locationRunning = false
  }

  private fun setState(next: State) {
    state = next
    onState?.invoke(next.wire)
    emit(force = true)
  }

  private fun accept(fix: Location) {
    lastFixAtMs = fix.time
    lastAccuracyM = if (fix.hasAccuracy()) fix.accuracy else null
    if (state != State.RUNNING) return
    if (!fix.hasAccuracy() || fix.accuracy > MAX_ACCURACY_M) return
    if (System.currentTimeMillis() - fix.time > MAX_STALE_MS) return

    val last = lastAccepted
    if (last != null) {
      val dt = (fix.time - last.time) / 1000.0
      if (dt <= 0) return
      val d = fix.distanceTo(last).toDouble()
      if (d / dt > maxSpeedMS) return
      distanceM += d
    }
    lastAccepted = fix
    if (fix.hasAltitude() && fix.hasVerticalAccuracy() && fix.verticalAccuracyMeters <= MAX_VERTICAL_ACCURACY_M) {
      lastAltitude = fix.altitude
    }
    sample(force = false)
    segments.last().add(LatLng(fix.latitude, fix.longitude))
    track.add(fix)
    paceWindow.add(fix)
    while (paceWindow.isNotEmpty() && fix.time - paceWindow.first().time > PACE_WINDOW_MS) {
      paceWindow.removeAt(0)
    }
    appendListeners.toList().forEach { it() }
    emit(force = false)
  }

  private fun currentPaceSecPerKm(): Double? {
    if (paceWindow.size < 2) return null
    var d = 0.0
    for (i in 1 until paceWindow.size) d += paceWindow[i].distanceTo(paceWindow[i - 1])
    val dt = (paceWindow.last().time - paceWindow.first().time) / 1000.0
    // Under ~1 km/h is standing, not a pace worth showing.
    if (d <= 5 || dt <= 0 || d / dt <= 0.3) return null
    return dt / (d / 1000.0)
  }

  private fun gpsSignal(): String {
    if (!outdoor) return "off"
    val at = lastFixAtMs ?: return "none"
    val accuracy = lastAccuracyM ?: return "none"
    if (System.currentTimeMillis() - at > MAX_STALE_MS) return "none"
    if (accuracy <= 10f) return "good"
    if (accuracy <= MAX_ACCURACY_M) return "fair"
    return "weak"
  }

  private fun metrics(): Map<String, Any?> {
    val out = HashMap<String, Any?>()
    out["state"] = state.wire
    out["distanceM"] = distanceM
    out["gps"] = gpsSignal()
    out["health"] = healthEnabled
    // iOS reads this off the Health builder; here moving time is the same
    // number (pauses excluded), so it is always present.
    out["elapsedS"] = movingS
    currentPaceSecPerKm()?.let { out["paceSecPerKm"] = it }
    return out
  }

  private fun emit(force: Boolean) {
    val now = System.currentTimeMillis()
    if (!force && now - lastEmitAtMs < 1000) return
    lastEmitAtMs = now
    onUpdate?.invoke(metrics())
  }

  fun snapshot(): Map<String, Any?> = metrics()

  private fun summary(workoutId: String?): Map<String, Any?> {
    val simplified = segments
      .filter { it.size >= 2 }
      .map { RunPolyline.encode(RunPolyline.simplify(it, toleranceM = 3.0)) }
    val out = HashMap(metrics())
    out["healthWorkoutId"] = workoutId
    out["route"] = simplified
    out["movingS"] = movingS
    out["samples"] = mapOf(
      "t" to sampleT.toList(),
      "d" to sampleD.toList(),
      "alt" to sampleAlt.toList(),
    )
    return out
  }
}

// Health Connect access shared by the recorder (write) and the import (read).
object HealthStore {
  fun available(context: Context): Boolean =
    HealthConnectClient.getSdkStatus(context) == HealthConnectClient.SDK_AVAILABLE

  fun client(context: Context): HealthConnectClient = HealthConnectClient.getOrCreate(context)

  // Mirrors ios RunRecorder.shareTypes: the workout, its route, distance.
  val writePermissions: Set<String> = setOf(
    androidx.health.connect.client.permission.HealthPermission.getWritePermission(ExerciseSessionRecord::class),
    androidx.health.connect.client.permission.HealthPermission.PERMISSION_WRITE_EXERCISE_ROUTE,
    androidx.health.connect.client.permission.HealthPermission.getWritePermission(DistanceRecord::class),
  )

  // Granted permissions are cached by the last permission query so the
  // synchronous JS getters (canWriteHealth) have something to answer with.
  @Volatile var granted: Set<String> = emptySet()

  fun hasWritePermissions(context: Context): Boolean =
    available(context) && granted.containsAll(writePermissions)

  suspend fun refreshGranted(context: Context): Set<String> {
    if (!available(context)) return emptySet()
    granted = client(context).permissionController.getGrantedPermissions()
    return granted
  }

  private fun exerciseType(activity: String): Int = when (activity) {
    "walking" -> ExerciseSessionRecord.EXERCISE_TYPE_WALKING
    "cycling" -> ExerciseSessionRecord.EXERCISE_TYPE_BIKING
    "hiking" -> ExerciseSessionRecord.EXERCISE_TYPE_HIKING
    else -> ExerciseSessionRecord.EXERCISE_TYPE_RUNNING
  }

  private fun title(activity: String): String = when (activity) {
    "walking" -> "Walk"
    "cycling" -> "Ride"
    "hiking" -> "Hike"
    else -> "Run"
  }

  /** Inserts the session (+ route) and distance; returns the session's record id. */
  suspend fun writeSession(
    context: Context,
    activity: String,
    startMs: Long,
    endMs: Long,
    distanceM: Double,
    route: List<Location>,
  ): String? {
    val zone = ZoneId.systemDefault()
    val start = Instant.ofEpochMilli(startMs)
    val end = Instant.ofEpochMilli(endMs)
    val startOffset = zone.rules.getOffset(start)
    val endOffset = zone.rules.getOffset(end)
    val metadata = Metadata.autoRecorded(Device(type = Device.TYPE_PHONE))
    val canRoute = granted.contains(
      androidx.health.connect.client.permission.HealthPermission.PERMISSION_WRITE_EXERCISE_ROUTE,
    )
    val locations = if (canRoute) route
      .filter { it.time in startMs..endMs }
      .map { fix ->
        ExerciseRoute.Location(
          time = Instant.ofEpochMilli(fix.time),
          latitude = fix.latitude,
          longitude = fix.longitude,
          horizontalAccuracy = if (fix.hasAccuracy()) Length.meters(fix.accuracy.toDouble()) else null,
          verticalAccuracy = if (fix.hasVerticalAccuracy()) Length.meters(fix.verticalAccuracyMeters.toDouble()) else null,
          altitude = if (fix.hasAltitude()) Length.meters(fix.altitude) else null,
        )
      } else emptyList()
    val session = ExerciseSessionRecord(
      startTime = start,
      startZoneOffset = startOffset,
      endTime = end,
      endZoneOffset = endOffset,
      exerciseType = exerciseType(activity),
      title = title(activity),
      metadata = metadata,
      exerciseRoute = if (locations.size >= 2) ExerciseRoute(locations) else null,
    )
    val records = ArrayList<androidx.health.connect.client.records.Record>()
    records.add(session)
    if (distanceM > 0 && granted.contains(
        androidx.health.connect.client.permission.HealthPermission.getWritePermission(DistanceRecord::class),
      )
    ) {
      records.add(
        DistanceRecord(
          startTime = start,
          startZoneOffset = startOffset,
          endTime = end,
          endZoneOffset = endOffset,
          distance = Length.meters(distanceM),
          metadata = metadata,
        ),
      )
    }
    val response = client(context).insertRecords(records)
    return response.recordIdsList.firstOrNull()
  }
}
