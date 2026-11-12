package expo.modules.workoutkit

import android.net.Uri
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.WearableListenerService
import org.json.JSONObject

// What the Paceo watch sends this phone, delivered by Play services even
// when the app isn't running (the manifest filters which paths wake it):
//
//   /finished/<Uri.encode(logKey)>  DataItem  a finished workout -> the inbox file
//                                   (raw bytes, or an Asset "payload" over 90 KB)
//   /snapshot                       Message   the live session JSON while mirroring
//   /mirror                         Message   {"active": false, "ended": bool}
//   /needPlan                       Message   {"missingPosters": [...]}
//
// Everything lands in WatchLinkHub, which forwards to the live module if JS
// is running.
class WatchLinkListenerService : WearableListenerService() {
  override fun onDataChanged(events: DataEventBuffer) {
    for (event in events) {
      if (event.type != DataEvent.TYPE_CHANGED) continue
      val item = event.dataItem
      val logKey = finishedLogKey(item.uri) ?: continue
      val json = WatchLinkHub.finishedPayload(applicationContext, item) ?: continue
      WatchLinkHub.putFinished(applicationContext, logKey, json)
    }
  }

  override fun onMessageReceived(event: MessageEvent) {
    val text = event.data?.let { String(it, Charsets.UTF_8) } ?: ""
    when (event.path) {
      WatchLinkHub.PATH_SNAPSHOT -> if (text.isNotEmpty()) WatchLinkHub.receiveSnapshot(text)
      WatchLinkHub.PATH_MIRROR -> {
        val obj = runCatching { JSONObject(text) }.getOrNull() ?: JSONObject()
        // Only "stopped mirroring" is sent; a mirror starts with its first snapshot.
        if (!obj.optBoolean("active", false)) WatchLinkHub.endMirror(obj.optBoolean("ended", false))
      }
      WatchLinkHub.PATH_NEED_PLAN -> {
        val arr = runCatching { JSONObject(text).optJSONArray("missingPosters") }.getOrNull()
        val missing = mutableListOf<String>()
        if (arr != null) for (i in 0 until arr.length()) arr.optString(i)?.takeIf { it.isNotEmpty() }?.let(missing::add)
        // The /plan DataItem already holds the last plan for the watch; JS
        // (when running) sends a fresh one.
        WatchLinkHub.planWanted(missing)
      }
    }
  }

  companion object {
    /** The logKey a `/finished/<Uri.encode(logKey)>` item carries, or null for any other path. */
    internal fun finishedLogKey(uri: Uri): String? {
      val path = uri.encodedPath ?: return null
      val prefix = WatchLinkHub.PATH_FINISHED + "/"
      if (!path.startsWith(prefix) || path.length == prefix.length) return null
      return Uri.decode(path.substring(prefix.length))
    }
  }
}
