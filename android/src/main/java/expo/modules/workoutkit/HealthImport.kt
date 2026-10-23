package expo.modules.workoutkit

import android.content.Context
import androidx.health.connect.client.changes.DeletionChange
import androidx.health.connect.client.changes.UpsertionChange
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.ActiveCaloriesBurnedRecord
import androidx.health.connect.client.records.DistanceRecord
import androidx.health.connect.client.records.ElevationGainedRecord
import androidx.health.connect.client.records.ExerciseRouteResult
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.HeartRateVariabilityRmssdRecord
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.RestingHeartRateRecord
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.Vo2MaxRecord
import androidx.health.connect.client.records.WeightRecord
import androidx.health.connect.client.request.AggregateRequest
import androidx.health.connect.client.request.ChangesTokenRequest
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import java.time.Instant
import java.time.format.DateTimeFormatter
import kotlin.reflect.KClass

// Health Connect *read* side, the twin of ios/ExpoHealthKitImport.swift.
// HealthKit's anchored queries become a two-stage cursor here: a first pass
// pages through history with readRecords ("p:<pageToken>"), then hands
// out a changes token ("c:<token>") that only ever yields what was added
// or deleted since. JS never sees the difference: an opaque anchor in,
// samples out, new anchor back.
object HealthImport {
  private val iso: DateTimeFormatter = DateTimeFormatter.ISO_INSTANT

  val readPermissions: Set<String> = setOf(
    HealthPermission.getReadPermission(ExerciseSessionRecord::class),
    // Routes come back inside ExerciseSessionRecord with this grant; the
    // SDK has no constant for it in every release, so the literal.
    "android.permission.health.READ_EXERCISE_ROUTES",
    HealthPermission.getReadPermission(HeartRateRecord::class),
    HealthPermission.getReadPermission(HeartRateVariabilityRmssdRecord::class),
    HealthPermission.getReadPermission(RestingHeartRateRecord::class),
    HealthPermission.getReadPermission(WeightRecord::class),
    HealthPermission.getReadPermission(Vo2MaxRecord::class),
    HealthPermission.getReadPermission(ActiveCaloriesBurnedRecord::class),
    HealthPermission.getReadPermission(DistanceRecord::class),
    HealthPermission.getReadPermission(SleepSessionRecord::class),
    HealthPermission.getReadPermission(ElevationGainedRecord::class),
  )

  fun quantityType(metric: String): KClass<out Record>? = when (metric) {
    "hrv" -> HeartRateVariabilityRmssdRecord::class
    "resting_hr" -> RestingHeartRateRecord::class
    "weight" -> WeightRecord::class
    "vo2max" -> Vo2MaxRecord::class
    else -> null
  }

  data class Page(val records: List<Record>, val anchor: String?)

  /**
   * One page of the cursor for `type`. The time filter for the initial
   * pass is since the epoch (HealthKit's "no predicate"); the changes pass
   * carries its own window. A changes token Health Connect no longer honours
   * (30 days idle) restarts from the beginning, as HealthKit's would.
   */
  suspend fun <T : Record> page(context: Context, type: KClass<T>, anchor: String?, limit: Int): Page {
    val client = HealthStore.client(context)
    if (anchor == null || anchor.startsWith("p:")) {
      val token = anchor?.removePrefix("p:")?.ifEmpty { null }
      val response = client.readRecords(
        ReadRecordsRequest(
          recordType = type,
          timeRangeFilter = TimeRangeFilter.after(Instant.EPOCH),
          pageSize = limit.coerceIn(1, 5000),
          pageToken = token,
        ),
      )
      val next = response.pageToken
      return if (next != null) {
        Page(response.records, "p:$next")
      } else {
        Page(response.records, "c:" + client.getChangesToken(ChangesTokenRequest(setOf(type))))
      }
    }
    val token = anchor.removePrefix("c:")
    val changes = client.getChanges(token)
    if (changes.changesTokenExpired) return page(context, type, null, limit)
    val records = changes.changes.mapNotNull { change ->
      when (change) {
        is UpsertionChange -> change.record.takeIf { type.isInstance(it) }
        is DeletionChange -> null
        else -> null
      }
    }
    return Page(records, "c:" + changes.nextChangesToken)
  }

  /** Recent-first page for browse UIs; `before` pages older results. */
  suspend fun listWorkouts(context: Context, before: Instant?, limit: Int): List<ExerciseSessionRecord> {
    val client = HealthStore.client(context)
    val filter = if (before != null) TimeRangeFilter.before(before) else TimeRangeFilter.after(Instant.EPOCH)
    val response = client.readRecords(
      ReadRecordsRequest(
        recordType = ExerciseSessionRecord::class,
        timeRangeFilter = filter,
        ascendingOrder = false,
        pageSize = limit.coerceIn(1, 5000),
      ),
    )
    return response.records
  }

  // MARK: - Serialization (canonical units, HK raw activity ids)

  suspend fun serializeWorkout(context: Context, w: ExerciseSessionRecord): Map<String, Any?> {
    val out = HashMap<String, Any?>()
    out["uuid"] = w.metadata.id
    out["activityTypeRaw"] = hkActivityRaw(w.exerciseType)
    out["startDate"] = iso.format(w.startTime)
    out["endDate"] = iso.format(w.endTime)
    out["durationS"] = (w.endTime.epochSecond - w.startTime.epochSecond).toInt()
    out["sourceName"] = w.metadata.dataOrigin.packageName
    out["sourceBundleId"] = w.metadata.dataOrigin.packageName
    w.title?.let { out["title"] = it }

    // Totals live in separate records; HealthKit folds them into the
    // workout. One aggregate over the session window does the same.
    runCatching {
      val client = HealthStore.client(context)
      val result = client.aggregate(
        AggregateRequest(
          metrics = setOf(
            DistanceRecord.DISTANCE_TOTAL,
            ActiveCaloriesBurnedRecord.ACTIVE_CALORIES_TOTAL,
            HeartRateRecord.BPM_AVG,
            HeartRateRecord.BPM_MAX,
            ElevationGainedRecord.ELEVATION_GAINED_TOTAL,
          ),
          timeRangeFilter = TimeRangeFilter.between(w.startTime, w.endTime),
          dataOriginFilter = setOf(w.metadata.dataOrigin),
        ),
      )
      result[DistanceRecord.DISTANCE_TOTAL]?.let { out["distanceM"] = it.inMeters }
      result[ActiveCaloriesBurnedRecord.ACTIVE_CALORIES_TOTAL]?.let { out["calories"] = it.inKilocalories }
      result[HeartRateRecord.BPM_AVG]?.let { out["avgHr"] = it.toDouble() }
      result[HeartRateRecord.BPM_MAX]?.let { out["maxHr"] = it.toDouble() }
      result[ElevationGainedRecord.ELEVATION_GAINED_TOTAL]?.let { out["elevationGainM"] = it.inMeters }
    }
    return out
  }

  // The GPS route one session was recorded with, as the recording app wrote
  // it: seconds since the session started, position, altitude, accuracy.
  // Health Connect hands the route back inside the session once the route
  // grant is held; a session whose route needs per-session consent, or has
  // none, reads as empty (the iOS twin returns [] for the same cases).
  suspend fun workoutRoute(context: Context, id: String): List<Map<String, Any?>> {
    val client = HealthStore.client(context)
    val session = client.readRecord(ExerciseSessionRecord::class, id).record
    val result = session.exerciseRouteResult as? ExerciseRouteResult.Data ?: return emptyList()
    val start = session.startTime.toEpochMilli()
    return result.exerciseRoute.route.sortedBy { it.time }.map { loc ->
      val out = HashMap<String, Any?>()
      out["t"] = (loc.time.toEpochMilli() - start) / 1000.0
      out["lat"] = loc.latitude
      out["lng"] = loc.longitude
      out["acc"] = loc.horizontalAccuracy?.inMeters ?: -1.0
      loc.altitude?.let { out["alt"] = it.inMeters }
      out
    }
  }

  /** Heart rate through one session: seconds since its start and beats per minute, oldest first. */
  suspend fun workoutHeartRate(context: Context, id: String): List<Map<String, Any?>> {
    val client = HealthStore.client(context)
    val session = client.readRecord(ExerciseSessionRecord::class, id).record
    val start = session.startTime.toEpochMilli()
    val out = ArrayList<Map<String, Any?>>()
    var token: String? = null
    do {
      val page = client.readRecords(
        ReadRecordsRequest(
          recordType = HeartRateRecord::class,
          timeRangeFilter = TimeRangeFilter.between(session.startTime, session.endTime),
          pageSize = 1000,
          pageToken = token,
        ),
      )
      for (record in page.records) {
        for (sample in record.samples) {
          out.add(mapOf("t" to (sample.time.toEpochMilli() - start) / 1000.0, "bpm" to sample.beatsPerMinute.toDouble()))
        }
      }
      token = page.pageToken
    } while (token != null)
    out.sortBy { it["t"] as Double }
    return out
  }

  fun serializeQuantity(metric: String, r: Record): Map<String, Any?>? {
    val (value, at) = when (r) {
      is HeartRateVariabilityRmssdRecord -> r.heartRateVariabilityMillis to r.time
      is RestingHeartRateRecord -> r.beatsPerMinute.toDouble() to r.time
      is WeightRecord -> r.weight.inKilograms to r.time
      is Vo2MaxRecord -> r.vo2MillilitersPerMinuteKilogram to r.time
      else -> return null
    }
    return mapOf(
      "uuid" to r.metadata.id,
      "value" to value,
      "measuredAt" to iso.format(at),
      "sourceName" to r.metadata.dataOrigin.packageName,
    )
  }

  // One sample per stage, in HKCategoryValueSleepAnalysis terms (0 inBed,
  // 1 asleepUnspecified, 2 awake, 3 core, 4 deep, 5 REM); a session without
  // stages is one "asleep" span.
  fun serializeSleep(r: SleepSessionRecord): List<Map<String, Any?>> {
    val source = r.metadata.dataOrigin.packageName
    if (r.stages.isEmpty()) {
      return listOf(
        mapOf(
          "uuid" to r.metadata.id,
          "value" to 1,
          "startDate" to iso.format(r.startTime),
          "endDate" to iso.format(r.endTime),
          "sourceName" to source,
        ),
      )
    }
    return r.stages.mapIndexed { i, stage ->
      val value = when (stage.stage) {
        SleepSessionRecord.STAGE_TYPE_AWAKE, SleepSessionRecord.STAGE_TYPE_AWAKE_IN_BED -> 2
        SleepSessionRecord.STAGE_TYPE_OUT_OF_BED -> 0
        SleepSessionRecord.STAGE_TYPE_LIGHT -> 3
        SleepSessionRecord.STAGE_TYPE_DEEP -> 4
        SleepSessionRecord.STAGE_TYPE_REM -> 5
        else -> 1
      }
      mapOf(
        "uuid" to "${r.metadata.id}:$i",
        "value" to value,
        "startDate" to iso.format(stage.startTime),
        "endDate" to iso.format(stage.endTime),
        "sourceName" to source,
      )
    }
  }

  // Health Connect exercise type -> HKWorkoutActivityType raw value, so the
  // JS sport mapping written for HealthKit works unchanged. 3000 = other.
  private fun hkActivityRaw(type: Int): Int = when (type) {
    ExerciseSessionRecord.EXERCISE_TYPE_RUNNING, ExerciseSessionRecord.EXERCISE_TYPE_RUNNING_TREADMILL -> 37
    ExerciseSessionRecord.EXERCISE_TYPE_WALKING -> 52
    ExerciseSessionRecord.EXERCISE_TYPE_HIKING -> 24
    ExerciseSessionRecord.EXERCISE_TYPE_BIKING, ExerciseSessionRecord.EXERCISE_TYPE_BIKING_STATIONARY -> 13
    ExerciseSessionRecord.EXERCISE_TYPE_SWIMMING_POOL, ExerciseSessionRecord.EXERCISE_TYPE_SWIMMING_OPEN_WATER -> 46
    ExerciseSessionRecord.EXERCISE_TYPE_STRENGTH_TRAINING, ExerciseSessionRecord.EXERCISE_TYPE_WEIGHTLIFTING -> 50
    ExerciseSessionRecord.EXERCISE_TYPE_CALISTHENICS, ExerciseSessionRecord.EXERCISE_TYPE_BOOT_CAMP -> 20
    ExerciseSessionRecord.EXERCISE_TYPE_HIGH_INTENSITY_INTERVAL_TRAINING -> 63
    ExerciseSessionRecord.EXERCISE_TYPE_YOGA -> 57
    ExerciseSessionRecord.EXERCISE_TYPE_PILATES -> 66
    ExerciseSessionRecord.EXERCISE_TYPE_STRETCHING -> 62
    ExerciseSessionRecord.EXERCISE_TYPE_ROWING, ExerciseSessionRecord.EXERCISE_TYPE_ROWING_MACHINE -> 35
    ExerciseSessionRecord.EXERCISE_TYPE_ELLIPTICAL -> 16
    ExerciseSessionRecord.EXERCISE_TYPE_STAIR_CLIMBING, ExerciseSessionRecord.EXERCISE_TYPE_STAIR_CLIMBING_MACHINE -> 44
    ExerciseSessionRecord.EXERCISE_TYPE_SOCCER -> 41
    ExerciseSessionRecord.EXERCISE_TYPE_BASKETBALL -> 6
    ExerciseSessionRecord.EXERCISE_TYPE_TENNIS -> 48
    ExerciseSessionRecord.EXERCISE_TYPE_TABLE_TENNIS -> 47
    ExerciseSessionRecord.EXERCISE_TYPE_BADMINTON -> 4
    ExerciseSessionRecord.EXERCISE_TYPE_SQUASH -> 43
    ExerciseSessionRecord.EXERCISE_TYPE_RACQUETBALL -> 34
    ExerciseSessionRecord.EXERCISE_TYPE_VOLLEYBALL -> 51
    ExerciseSessionRecord.EXERCISE_TYPE_BASEBALL -> 5
    ExerciseSessionRecord.EXERCISE_TYPE_SOFTBALL -> 42
    ExerciseSessionRecord.EXERCISE_TYPE_CRICKET -> 10
    ExerciseSessionRecord.EXERCISE_TYPE_RUGBY -> 36
    ExerciseSessionRecord.EXERCISE_TYPE_FOOTBALL_AMERICAN -> 1
    ExerciseSessionRecord.EXERCISE_TYPE_FOOTBALL_AUSTRALIAN -> 3
    ExerciseSessionRecord.EXERCISE_TYPE_ICE_HOCKEY, ExerciseSessionRecord.EXERCISE_TYPE_ROLLER_HOCKEY -> 25
    ExerciseSessionRecord.EXERCISE_TYPE_BOXING -> 8
    ExerciseSessionRecord.EXERCISE_TYPE_MARTIAL_ARTS -> 28
    ExerciseSessionRecord.EXERCISE_TYPE_GYMNASTICS -> 22
    ExerciseSessionRecord.EXERCISE_TYPE_DANCING -> 14
    ExerciseSessionRecord.EXERCISE_TYPE_GOLF -> 21
    ExerciseSessionRecord.EXERCISE_TYPE_ROCK_CLIMBING -> 9
    ExerciseSessionRecord.EXERCISE_TYPE_SKIING -> 61
    ExerciseSessionRecord.EXERCISE_TYPE_SNOWBOARDING -> 67
    ExerciseSessionRecord.EXERCISE_TYPE_SKATING, ExerciseSessionRecord.EXERCISE_TYPE_ICE_SKATING -> 39
    ExerciseSessionRecord.EXERCISE_TYPE_SURFING -> 45
    ExerciseSessionRecord.EXERCISE_TYPE_PADDLING -> 31
    ExerciseSessionRecord.EXERCISE_TYPE_SAILING -> 38
    ExerciseSessionRecord.EXERCISE_TYPE_WATER_POLO -> 54
    ExerciseSessionRecord.EXERCISE_TYPE_HANDBALL -> 23
    ExerciseSessionRecord.EXERCISE_TYPE_FENCING -> 18
    ExerciseSessionRecord.EXERCISE_TYPE_FRISBEE_DISC -> 75
    ExerciseSessionRecord.EXERCISE_TYPE_EXERCISE_CLASS -> 73
    ExerciseSessionRecord.EXERCISE_TYPE_WHEELCHAIR -> 70
    ExerciseSessionRecord.EXERCISE_TYPE_SCUBA_DIVING -> 84
    ExerciseSessionRecord.EXERCISE_TYPE_SNOWSHOEING -> 40
    ExerciseSessionRecord.EXERCISE_TYPE_GUIDED_BREATHING -> 29
    else -> 3000
  }
}
