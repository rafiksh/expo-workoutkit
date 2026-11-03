// Run: swiftc ios/HeartRateMeasurement.swift test/heart-rate/main.swift -o /tmp/hrm && /tmp/hrm
import Foundation
// (kept outside ios/ so the podspec's source glob never picks up this main)
var failures = 0
func check(_ name: String, _ got: Int?, _ want: Int?) {
  if got != want { failures += 1; print("FAIL \(name): got \(String(describing: got)) want \(String(describing: want))") }
}

check("uint8", HeartRateMeasurement.bpm([0x00, 72]), 72)
check("uint16 little endian", HeartRateMeasurement.bpm([0x01, 0x8C, 0x00]), 140)
check("uint16 high byte", HeartRateMeasurement.bpm([0x01, 0xC8, 0x00, 0x00]), 200)
check("contact reported and on skin", HeartRateMeasurement.bpm([0x06, 150]), 150)
check("contact reported, off skin", HeartRateMeasurement.bpm([0x04, 0]), nil)
check("contact bit without support flag is ignored", HeartRateMeasurement.bpm([0x02, 90]), 90)
check("rr intervals after the value", HeartRateMeasurement.bpm([0x10, 64, 0x00, 0x04]), 64)
check("energy + rr, uint16", HeartRateMeasurement.bpm([0x19, 0x9B, 0x00, 0x10, 0x00, 0x00, 0x04]), 155)
check("empty", HeartRateMeasurement.bpm([]), nil)
check("uint8 missing value", HeartRateMeasurement.bpm([0x00]), nil)
check("uint16 missing high byte", HeartRateMeasurement.bpm([0x01, 0x50]), nil)
check("zero", HeartRateMeasurement.bpm([0x00, 0]), nil)
check("implausible", HeartRateMeasurement.bpm([0x01, 0xFF, 0x01]), nil)

if failures == 0 { print("ok: HeartRateMeasurement") } else { print("\(failures) failed"); exit(1) }
