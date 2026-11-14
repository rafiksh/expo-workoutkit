package expo.modules.workoutkit

import android.content.Context
import android.util.AtomicFile
import com.google.android.gms.tasks.Tasks
import com.google.android.gms.wearable.DataItem
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.Wearable
import org.json.JSONObject
import java.io.File
import java.util.concurrent.TimeUnit

// The phone's half of the Paceo Wear OS link (monorepo docs/plans/wear-os.md,
// "W2 wire protocol"): state shared by the listener service, which the Data
// Layer wakes even with no JS running, and the live ExpoWatchLink module.
//
// The finished-workout inbox lives on disk until JS saves and acks each one,
// the same as WatchLink.swift on iOS. Snapshot/mirror state is in memory: a
// cold start asks the watch again with /hello.
internal object WatchLinkHub {
  const val WATCH_CAPABILITY = "paceo_watch_app"

  const val PATH_PLAN = "/plan"
  const val PATH_FINISHED = "/finished"
  const val PATH_ACK = "/ack"
  const val PATH_SNAPSHOT = "/snapshot"
  const val PATH_MIRROR = "/mirror"
  const val PATH_COMMAND = "/command"
  const val PATH_HELLO = "/hello"
  const val PATH_NEED_PLAN = "/needPlan"
  const val PATH_START = "/start"
  const val PATH_PERMISSIONS = "/permissions"
  const val PATH_STATE = "/state"

  private const val INBOX_FILE = "paceo-watch-inbox.json"

  /** What the live module forwards to JS. Null when no module (no JS) is running. */
  interface Listener {
    fun onSnapshot(json: String)
    fun onMirror(active: Boolean, ended: Boolean)
    fun onFinished()
    fun onPlanWanted(missingPosters: List<String>, current: Boolean)
  }

  @Volatile var listener: Listener? = null

  /** The watch's latest session JSON while mirroring. */
  @Volatile var lastSnapshot: String? = null
    private set

  /** A watch-owned workout is mirrored to this phone right now. */
  @Volatile var mirroring = false
    private set

  private val lock = Any()

  // MARK: mirroring

  fun receiveSnapshot(json: String) {
    val started: Boolean
    synchronized(lock) {
      lastSnapshot = json
      started = !mirroring
      mirroring = true
    }
    // Snapshot stored first, so a JS listener reacting to the mirror event
    // can already read it with getMirroredSnapshot.
    if (started) listener?.onMirror(true, false)
    listener?.onSnapshot(json)
  }

  /**
   * `ended`: the watch ended the workout itself; false when the link dropped
   * and the workout carries on there.
   */
  fun endMirror(ended: Boolean) {
    synchronized(lock) {
      if (!mirroring) return
      mirroring = false
      lastSnapshot = null
    }
    listener?.onMirror(false, ended)
  }

  /**
   * The watch asked for the plan, with the `sentAt` of the one it holds
   * (absent from older watch apps). `current`: that is this phone's last
   * plan, so only a week that changed since needs sending. The ask is kept
   * until a plan answers it: the watch can ask with no JS running, and JS
   * takes it once it is.
   */
  fun planWanted(context: Context, missingPosters: List<String>, have: Double?) {
    val ours = prefs(context).getLong(PLAN_SENT_AT, 0L)
    val current = have != null && ours > 0 && have >= ours
    synchronized(lock) { wanted = missingPosters to current }
    listener?.onPlanWanted(missingPosters, current)
  }

  /** The watch's last ask if no plan has gone out since; taking it clears it. */
  fun takePlanWanted(): Pair<List<String>, Boolean>? = synchronized(lock) { wanted.also { wanted = null } }

  /** A plan went out: remember when it was built, and the ask (if any) is answered. */
  fun planSent(context: Context, json: String) {
    val sentAt = runCatching { JSONObject(json).optDouble("sentAt", 0.0).toLong() }.getOrDefault(0L)
    prefs(context).edit().putLong(PLAN_SENT_AT, sentAt).apply()
    synchronized(lock) { wanted = null }
  }

  private var wanted: Pair<List<String>, Boolean>? = null
  private const val PLAN_SENT_AT = "planSentAt"
  private fun prefs(context: Context) = context.getSharedPreferences("paceo-watch-link", Context.MODE_PRIVATE)

  // MARK: finished inbox

  private fun inboxFile(context: Context) = AtomicFile(File(context.filesDir, INBOX_FILE))

  private fun readInbox(context: Context): MutableMap<String, String> {
    val out = mutableMapOf<String, String>()
    try {
      val text = String(inboxFile(context).readFully(), Charsets.UTF_8)
      val obj = JSONObject(text)
      for (key in obj.keys()) out[key] = obj.optString(key)
    } catch (_: Exception) {
      // Missing or unreadable: an empty inbox.
    }
    return out
  }

  private fun writeInbox(context: Context, inbox: Map<String, String>) {
    val file = inboxFile(context)
    val stream = file.startWrite()
    try {
      stream.write(JSONObject(inbox).toString().toByteArray(Charsets.UTF_8))
      file.finishWrite(stream)
    } catch (e: Exception) {
      file.failWrite(stream)
    }
  }

  /**
   * A /finished item's JSON. Small ones carry it as the item's raw bytes;
   * one over the Data Layer's 100 KB item cap (a long ride's track) comes as
   * an Asset named "payload" in a DataMap. Blocking: call off the main thread.
   */
  fun finishedPayload(context: Context, item: DataItem): String? {
    if (item.assets.containsKey("payload")) {
      // A DataMap: its raw bytes aren't the JSON. Unreadable now: null, and
      // the item stays on the watch for the next try.
      return runCatching {
        val asset = DataMapItem.fromDataItem(item).dataMap.getAsset("payload")!!
        val fd = Tasks.await(Wearable.getDataClient(context).getFdForAsset(asset), 30, TimeUnit.SECONDS)
        fd.inputStream.use { String(it.readBytes(), Charsets.UTF_8) }
      }.getOrNull()
    }
    return item.data?.let { String(it, Charsets.UTF_8) }
  }

  /** Stores a finished workout. Returns true when it was new (not already waiting). */
  fun putFinished(context: Context, logKey: String, json: String, notify: Boolean = true): Boolean {
    val isNew: Boolean
    synchronized(lock) {
      val inbox = readInbox(context)
      isNew = inbox[logKey] != json
      if (isNew) {
        inbox[logKey] = json
        writeInbox(context, inbox)
      }
    }
    if (isNew && notify) listener?.onFinished()
    return isNew
  }

  /** Finished workouts waiting to be saved: [{logKey, json}]. */
  fun pendingFinished(context: Context): List<Map<String, String>> =
    synchronized(lock) { readInbox(context).map { mapOf("logKey" to it.key, "json" to it.value) } }

  fun removeFinished(context: Context, logKey: String) {
    synchronized(lock) {
      val inbox = readInbox(context)
      if (inbox.remove(logKey) != null) writeInbox(context, inbox)
    }
  }
}
