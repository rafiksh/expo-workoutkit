package expo.modules.workoutkit

import android.content.Context
import android.net.Uri
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.common.api.CommonStatusCodes
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.DataClient
import com.google.android.gms.wearable.Node
import com.google.android.gms.wearable.PutDataRequest
import com.google.android.gms.wearable.Wearable
import expo.modules.kotlin.Promise
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean

// JS surface for the Wear OS link, the same API as ios/ExpoWatchLinkModule.swift
// (src/WatchLink.ts). Payloads are JSON strings whose shape the app owns; this
// module only carries them over the Wearable Data Layer, per the monorepo's
// docs/plans/wear-os.md "W2 wire protocol". Inbound traffic arrives through
// WatchLinkListenerService and WatchLinkHub.
class ExpoWatchLinkModule : Module() {
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
  private var context: Context? = null

  // Cached status, refreshed in the background (getStatus is synchronous).
  @Volatile private var supported = false
  @Volatile private var paired = false
  /** Nodes with the Paceo watch app installed (FILTER_ALL). */
  @Volatile private var installedNodes: List<Node> = emptyList()
  /** Nodes with the Paceo watch app in reach right now (FILTER_REACHABLE). */
  @Volatile private var reachableNodes: List<Node> = emptyList()
  private val refreshing = AtomicBoolean(false)

  private val capabilityListener = CapabilityClient.OnCapabilityChangedListener {
    scope.launch { refresh() }
  }

  private val hubListener = object : WatchLinkHub.Listener {
    override fun onSnapshot(json: String) = sendEvent("onWatchSnapshot", mapOf("json" to json))
    override fun onMirror(active: Boolean, ended: Boolean) =
      sendEvent("onWatchMirror", mapOf("active" to active, "ended" to ended))
    override fun onFinished() = sendEvent("onWatchFinished", emptyMap<String, Any>())
    override fun onPlanWanted(missingPosters: List<String>) =
      sendEvent("onWatchPlanWanted", mapOf("missingPosters" to missingPosters))
  }

  override fun definition() = ModuleDefinition {
    Name("ExpoWatchLink")

    Events("onWatchSnapshot", "onWatchMirror", "onWatchFinished", "onWatchPermissions", "onWatchPlanWanted")

    OnCreate {
      val ctx = appContext.reactContext?.applicationContext ?: return@OnCreate
      context = ctx
      supported = playServicesAvailable(ctx)
      WatchLinkHub.listener = hubListener
      if (!supported) return@OnCreate
      runCatching { Wearable.getCapabilityClient(ctx).addListener(capabilityListener, WatchLinkHub.WATCH_CAPABILITY) }
      scope.launch {
        refresh()
        collectMissedFinished(ctx)
        // A watch mid-workout re-sends its snapshot, so a cold-started phone
        // picks the mirror back up.
        for (node in reachableNodes) sendMessage(ctx, node.id, WatchLinkHub.PATH_HELLO, ByteArray(0))
      }
    }

    OnDestroy {
      if (WatchLinkHub.listener === hubListener) WatchLinkHub.listener = null
      context?.let { ctx ->
        runCatching { Wearable.getCapabilityClient(ctx).removeListener(capabilityListener, WatchLinkHub.WATCH_CAPABILITY) }
      }
      scope.cancel()
    }

    Function("getStatus") {
      kickRefresh()
      statusMap()
    }

    /** The watch's latest session JSON if a mirrored session is live. */
    Function("getMirroredSnapshot") {
      if (WatchLinkHub.mirroring) WatchLinkHub.lastSnapshot else null
    }

    // Replaces the watch's plan cache: one urgent DataItem, latest wins,
    // delivered when the watch connects. The Data Layer caps an item at
    // 100 KB (DataClient's MAX_DATA_ITEM_SIZE), so a bigger plan rejects.
    AsyncFunction("sendPlan") { json: String, promise: Promise ->
      val ctx = context
      if (ctx == null || !supported) {
        promise.resolve(null)
        return@AsyncFunction
      }
      val bytes = json.toByteArray(Charsets.UTF_8)
      if (bytes.size > MAX_DATA_ITEM_BYTES) {
        promise.reject("ERR_PLAN_TOO_LARGE", "Plan is ${bytes.size} bytes; a Data Layer item holds $MAX_DATA_ITEM_BYTES", null)
        return@AsyncFunction
      }
      scope.launch {
        try {
          val request = PutDataRequest.create(WatchLinkHub.PATH_PLAN).setData(bytes).setUrgent()
          Wearable.getDataClient(ctx).putDataItem(request).await()
          promise.resolve(null)
        } catch (e: ApiException) {
          // No Wear OS companion on this phone: nothing to send to, like iOS unpaired.
          if (isApiUnavailable(e)) promise.resolve(null) else promise.reject("ERR_SEND_PLAN", e.message, e)
        } catch (e: Exception) {
          promise.reject("ERR_SEND_PLAN", e.message, e)
        }
      }
    }

    // A no-op on Wear OS: the watch app downloads exercise photos by URL
    // itself (the plan carries them), so the phone never transfers files.
    // Kept so watchLink.ts runs unchanged on both platforms.
    Function("sendPoster") { _: String, _: String -> }

    // A SessionCommand to the watch that owns the session. True when a
    // watch with the Paceo app was known to be in reach (the send itself is
    // fire-and-forget, like iOS's sendToRemoteWorkoutSession).
    Function("sendCommand") { json: String ->
      val ctx = context ?: return@Function false
      val nodes = reachableNodes
      if (nodes.isEmpty()) {
        kickRefresh()
        return@Function false
      }
      val bytes = json.toByteArray(Charsets.UTF_8)
      scope.launch { for (node in nodes) sendMessage(ctx, node.id, WatchLinkHub.PATH_COMMAND, bytes) }
      true
    }

    // Starts a built session on the watch, which launches the Paceo watch
    // app. Resolves true only when the watch replies "ok"; false on "no",
    // when no watch is in reach, or after ~8 s. Retries a failed delivery
    // within that window, as the watch app may still be launching.
    AsyncFunction("startOnWatch") { json: String, promise: Promise ->
      val ctx = context
      if (ctx == null || !supported) {
        promise.resolve(false)
        return@AsyncFunction
      }
      val bytes = json.toByteArray(Charsets.UTF_8)
      scope.launch {
        val ok = withTimeoutOrNull(START_TIMEOUT_MS) {
          while (true) {
            val node = bestNode(ctx)
            if (node != null) {
              val reply = runCatching {
                Wearable.getMessageClient(ctx).sendRequest(node.id, WatchLinkHub.PATH_START, bytes).await()
              }.getOrNull()
              if (reply != null) return@withTimeoutOrNull String(reply, Charsets.UTF_8).trim() == "ok"
            }
            delay(500)
          }
          @Suppress("UNREACHABLE_CODE")
          false
        } ?: false
        promise.resolve(ok)
      }
    }

    Function("getPendingFinished") {
      val ctx = context ?: return@Function emptyList<Map<String, String>>()
      WatchLinkHub.pendingFinished(ctx)
    }

    // Saved on our server: forget it here, tell the watch to forget it, and
    // delete the /finished DataItem so it isn't delivered again.
    Function("ackFinished") { logKey: String ->
      val ctx = context ?: return@Function
      WatchLinkHub.removeFinished(ctx, logKey)
      if (!supported) return@Function
      scope.launch {
        val uri = Uri.parse("wear://*${WatchLinkHub.PATH_FINISHED}/${Uri.encode(logKey)}")
        runCatching { Wearable.getDataClient(ctx).deleteDataItems(uri).await() }
        if (installedNodes.isEmpty()) refresh()
        val bytes = logKey.toByteArray(Charsets.UTF_8)
        for (node in installedNodes) sendMessage(ctx, node.id, WatchLinkHub.PATH_ACK, bytes)
      }
    }

    // What the watch may do: asked afresh when it's in reach, else its last
    // report; null before it ever reported.
    AsyncFunction("checkPermissions") { promise: Promise ->
      val ctx = context
      if (ctx == null) {
        promise.resolve(null)
        return@AsyncFunction
      }
      scope.launch {
        val fresh = if (supported) request(ctx, WatchLinkHub.PATH_PERMISSIONS)?.let(::parsePermissions) else null
        if (fresh != null) {
          prefs(ctx).edit().putString(PREF_PERMISSIONS, JSONObject(fresh).toString()).apply()
          sendEvent("onWatchPermissions", fresh)
          promise.resolve(fresh)
        } else {
          promise.resolve(cachedPermissions(ctx))
        }
      }
    }

    // The logKey of the workout the watch is running, "" for none, null
    // when it can't be reached.
    AsyncFunction("getWatchState") { promise: Promise ->
      val ctx = context
      if (ctx == null || !supported) {
        promise.resolve(null)
        return@AsyncFunction
      }
      scope.launch { promise.resolve(request(ctx, WatchLinkHub.PATH_STATE)?.trim()) }
    }
  }

  // MARK: status

  private fun statusMap(): Map<String, Any> {
    if (!supported) return mapOf("supported" to false)
    return mapOf(
      "supported" to true,
      "paired" to paired,
      "installed" to installedNodes.isNotEmpty(),
      "reachable" to reachableNodes.isNotEmpty(),
      "mirroring" to WatchLinkHub.mirroring,
    )
  }

  private fun kickRefresh() {
    if (context == null || !supported) return
    scope.launch { refresh() }
  }

  private suspend fun refresh() {
    val ctx = context ?: return
    if (!refreshing.compareAndSet(false, true)) return
    try {
      val connected = Wearable.getNodeClient(ctx).connectedNodes.await()
      val capabilities = Wearable.getCapabilityClient(ctx)
      val all = capabilities.getCapability(WatchLinkHub.WATCH_CAPABILITY, CapabilityClient.FILTER_ALL).await().nodes
      val reachable = capabilities.getCapability(WatchLinkHub.WATCH_CAPABILITY, CapabilityClient.FILTER_REACHABLE).await().nodes
      paired = connected.isNotEmpty()
      installedNodes = all.sortedByDescending { it.isNearby }
      reachableNodes = reachable.sortedByDescending { it.isNearby }
      // The watch fell out of reach mid-workout: the workout carries on there.
      if (reachable.isEmpty()) WatchLinkHub.endMirror(ended = false)
    } catch (e: ApiException) {
      if (isApiUnavailable(e)) {
        supported = false
        paired = false
        installedNodes = emptyList()
        reachableNodes = emptyList()
      }
    } catch (_: Exception) {
      // Keep the last known status.
    } finally {
      refreshing.set(false)
    }
  }

  /** A reachable watch with the Paceo app, nearby first; asked afresh so a just-woken watch counts. */
  private suspend fun bestNode(ctx: Context): Node? {
    val fresh = runCatching {
      Wearable.getCapabilityClient(ctx)
        .getCapability(WatchLinkHub.WATCH_CAPABILITY, CapabilityClient.FILTER_REACHABLE).await().nodes
        .sortedByDescending { it.isNearby }
    }.getOrNull()
    if (fresh != null) reachableNodes = fresh
    return (fresh ?: reachableNodes).firstOrNull()
  }

  // MARK: transport

  private suspend fun sendMessage(ctx: Context, nodeId: String, path: String, data: ByteArray) {
    runCatching { Wearable.getMessageClient(ctx).sendMessage(nodeId, path, data).await() }
  }

  /** A request/reply to the watch, as text; null when unreachable, failed, or past the timeout. */
  private suspend fun request(ctx: Context, path: String): String? {
    val node = bestNode(ctx) ?: return null
    return withTimeoutOrNull(REQUEST_TIMEOUT_MS) {
      runCatching { Wearable.getMessageClient(ctx).sendRequest(node.id, path, ByteArray(0)).await() }
        .getOrNull()?.let { String(it, Charsets.UTF_8) }
    }
  }

  // Finished items that landed while the listener service couldn't run
  // (installed or updated after the watch put them): into the inbox now.
  private suspend fun collectMissedFinished(ctx: Context) {
    val uri = Uri.parse("wear://*${WatchLinkHub.PATH_FINISHED}/")
    val buffer = runCatching {
      Wearable.getDataClient(ctx).getDataItems(uri, DataClient.FILTER_PREFIX).await()
    }.getOrNull() ?: return
    var added = false
    try {
      for (item in buffer) {
        val logKey = WatchLinkListenerService.finishedLogKey(item.uri) ?: continue
        val json = withContext(Dispatchers.IO) { WatchLinkHub.finishedPayload(ctx, item) } ?: continue
        if (WatchLinkHub.putFinished(ctx, logKey, json, notify = false)) added = true
      }
    } finally {
      buffer.release()
    }
    if (added) sendEvent("onWatchFinished", emptyMap<String, Any>())
  }

  // MARK: permissions

  private fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

  private fun cachedPermissions(ctx: Context): Map<String, Any>? =
    prefs(ctx).getString(PREF_PERMISSIONS, null)?.let(::parsePermissions)

  /** The watch's `{health, location, motion, checkedAt}` reply, in the WatchPermissions shape. */
  private fun parsePermissions(text: String): Map<String, Any>? {
    val obj = runCatching { JSONObject(text) }.getOrNull() ?: return null
    fun state(key: String): String = when (obj.optString(key)) {
      "granted" -> "granted"
      "denied", "restricted" -> "denied"
      else -> "notAsked"
    }
    val checkedAt = obj.optDouble("checkedAt").takeUnless { it.isNaN() } ?: System.currentTimeMillis().toDouble()
    return mapOf(
      "health" to state("health"),
      "location" to state("location"),
      "motion" to state("motion"),
      "checkedAt" to checkedAt,
    )
  }

  companion object {
    private const val PREFS = "paceo-watch-link"
    private const val PREF_PERMISSIONS = "permissions"
    private const val START_TIMEOUT_MS = 8_000L
    private const val REQUEST_TIMEOUT_MS = 8_000L
    // DataClient caps a DataItem's payload at 100 KB.
    private const val MAX_DATA_ITEM_BYTES = 100 * 1024

    private fun playServicesAvailable(ctx: Context) =
      GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(ctx) == ConnectionResult.SUCCESS

    /** The Wearable API isn't on this phone (no Wear OS companion app). */
    private fun isApiUnavailable(e: ApiException) =
      e.statusCode == CommonStatusCodes.API_NOT_CONNECTED || e.statusCode == ConnectionResult.API_UNAVAILABLE
  }
}
