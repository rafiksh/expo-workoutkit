package expo.modules.workoutkit

import com.google.android.gms.maps.model.LatLng
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.roundToLong

// Route geometry helpers, the twin of ios/RunPolyline.swift. The wire format
// is the Google encoded polyline at precision 5 (~1 m), one string per
// segment: compact for the server and decodable on any platform.
object RunPolyline {
  // Douglas-Peucker in an equirectangular projection around the first point,
  // so the tolerance is in metres (good to well under 1% at route scale).
  fun simplify(coords: List<LatLng>, toleranceM: Double): List<LatLng> {
    if (coords.size <= 2) return coords
    val lat0 = Math.toRadians(coords[0].latitude)
    val kx = 111_320.0 * cos(lat0)
    val ky = 110_574.0
    val xs = DoubleArray(coords.size) { coords[it].longitude * kx }
    val ys = DoubleArray(coords.size) { coords[it].latitude * ky }
    val keep = BooleanArray(coords.size)
    keep[0] = true
    keep[coords.size - 1] = true
    val stack = ArrayDeque<Pair<Int, Int>>()
    stack.addLast(0 to coords.size - 1)
    while (stack.isNotEmpty()) {
      val (start, end) = stack.removeLast()
      if (end <= start + 1) continue
      var maxDist = 0.0
      var index = start
      for (i in start + 1 until end) {
        val d = perpendicular(xs[i], ys[i], xs[start], ys[start], xs[end], ys[end])
        if (d > maxDist) {
          maxDist = d
          index = i
        }
      }
      if (maxDist > toleranceM) {
        keep[index] = true
        stack.addLast(start to index)
        stack.addLast(index to end)
      }
    }
    return coords.filterIndexed { i, _ -> keep[i] }
  }

  private fun perpendicular(px: Double, py: Double, ax: Double, ay: Double, bx: Double, by: Double): Double {
    val dx = bx - ax
    val dy = by - ay
    val len2 = dx * dx + dy * dy
    if (len2 == 0.0) return hypot(px - ax, py - ay)
    val t = (((px - ax) * dx + (py - ay) * dy) / len2).coerceIn(0.0, 1.0)
    return hypot(px - (ax + t * dx), py - (ay + t * dy))
  }

  fun encode(coords: List<LatLng>): String {
    val out = StringBuilder()
    var prevLat = 0L
    var prevLng = 0L
    for (c in coords) {
      val lat = (c.latitude * 1e5).roundToLong()
      val lng = (c.longitude * 1e5).roundToLong()
      append(lat - prevLat, out)
      append(lng - prevLng, out)
      prevLat = lat
      prevLng = lng
    }
    return out.toString()
  }

  private fun append(value: Long, out: StringBuilder) {
    var v = if (value < 0) (value shl 1).inv() else value shl 1
    while (v >= 0x20) {
      out.append(((0x20L or (v and 0x1f)) + 63).toInt().toChar())
      v = v shr 5
    }
    out.append((v + 63).toInt().toChar())
  }

  fun decode(encoded: String): List<LatLng> {
    val coords = ArrayList<LatLng>()
    var index = 0
    var lat = 0L
    var lng = 0L
    fun next(): Long? {
      var result = 0L
      var shift = 0
      while (index < encoded.length) {
        val b = encoded[index].code.toLong() - 63
        index += 1
        result = result or ((b and 0x1f) shl shift)
        shift += 5
        if (b < 0x20) return if ((result and 1L) != 0L) (result shr 1).inv() else result shr 1
      }
      return null
    }
    while (index < encoded.length) {
      val dLat = next() ?: break
      val dLng = next() ?: break
      lat += dLat
      lng += dLng
      coords.add(LatLng(lat / 1e5, lng / 1e5))
    }
    return coords
  }

  @Suppress("unused")
  private fun unused() = abs(0)
}
