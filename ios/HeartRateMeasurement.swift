import Foundation

// Bluetooth Heart Rate Measurement (characteristic 0x2A37), the packet every
// chest strap and arm band sends about once a second:
//   byte 0      flags: bit 0 = value is uint16 (else uint8),
//               bit 1 = skin contact detected, bit 2 = contact is reported
//   byte 1(..2) beats per minute, little endian
//   then optional energy expended and RR intervals, which we don't read.
// Pure Foundation so test/heart-rate/main.swift can compile it alone.
enum HeartRateMeasurement {
  /// Beats per minute, or nil for a short packet, a strap reporting it isn't
  /// on skin (they send 0 or garbage then), or a value no human heart makes.
  static func bpm(_ bytes: [UInt8]) -> Int? {
    guard let flags = bytes.first else { return nil }
    let wide = flags & 0x01 != 0
    let contactReported = flags & 0x04 != 0
    let contact = flags & 0x02 != 0
    if contactReported && !contact { return nil }
    let value: Int
    if wide {
      guard bytes.count >= 3 else { return nil }
      value = Int(bytes[1]) | (Int(bytes[2]) << 8)
    } else {
      guard bytes.count >= 2 else { return nil }
      value = Int(bytes[1])
    }
    guard value >= 25, value <= 250 else { return nil }
    return value
  }
}
