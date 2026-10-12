import CoreLocation
import MapKit

// Route geometry helpers. The wire format is the Google encoded polyline at
// precision 5 (~1 m), one string per segment: compact for the server and
// decodable on any platform without a library.
enum RunPolyline {
  // Douglas-Peucker in projected map points, so the tolerance is in metres.
  static func simplify(_ coords: [CLLocationCoordinate2D], toleranceM: Double) -> [CLLocationCoordinate2D] {
    guard coords.count > 2 else { return coords }
    let points = coords.map(MKMapPoint.init)
    let tolerance = toleranceM * MKMapPointsPerMeterAtLatitude(coords[0].latitude)
    var keep = [Bool](repeating: false, count: coords.count)
    keep[0] = true
    keep[coords.count - 1] = true
    var stack = [(0, coords.count - 1)]
    while let (start, end) = stack.popLast() {
      guard end > start + 1 else { continue }
      var maxDist = 0.0
      var index = start
      for i in (start + 1)..<end {
        let d = perpendicular(points[i], points[start], points[end])
        if d > maxDist { maxDist = d; index = i }
      }
      if maxDist > tolerance {
        keep[index] = true
        stack.append((start, index))
        stack.append((index, end))
      }
    }
    return coords.enumerated().filter { keep[$0.offset] }.map(\.element)
  }

  private static func perpendicular(_ p: MKMapPoint, _ a: MKMapPoint, _ b: MKMapPoint) -> Double {
    let dx = b.x - a.x, dy = b.y - a.y
    let len2 = dx * dx + dy * dy
    guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
  }

  static func encode(_ coords: [CLLocationCoordinate2D]) -> String {
    var out = ""
    var prevLat = 0, prevLng = 0
    for c in coords {
      let lat = Int((c.latitude * 1e5).rounded())
      let lng = Int((c.longitude * 1e5).rounded())
      append(lat - prevLat, to: &out)
      append(lng - prevLng, to: &out)
      prevLat = lat
      prevLng = lng
    }
    return out
  }

  private static func append(_ value: Int, to out: inout String) {
    var v = value < 0 ? ~(value << 1) : value << 1
    while v >= 0x20 {
      out.unicodeScalars.append(UnicodeScalar(UInt8((0x20 | (v & 0x1f)) + 63)))
      v >>= 5
    }
    out.unicodeScalars.append(UnicodeScalar(UInt8(v + 63)))
  }

  static func decode(_ encoded: String) -> [CLLocationCoordinate2D] {
    var coords: [CLLocationCoordinate2D] = []
    let bytes = Array(encoded.utf8)
    var index = 0, lat = 0, lng = 0
    func next() -> Int? {
      var result = 0, shift = 0
      while index < bytes.count {
        let b = Int(bytes[index]) - 63
        index += 1
        result |= (b & 0x1f) << shift
        shift += 5
        if b < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : result >> 1 }
      }
      return nil
    }
    while index < bytes.count {
      guard let dLat = next(), let dLng = next() else { break }
      lat += dLat
      lng += dLng
      coords.append(CLLocationCoordinate2D(latitude: Double(lat) / 1e5, longitude: Double(lng) / 1e5))
    }
    return coords
  }
}
