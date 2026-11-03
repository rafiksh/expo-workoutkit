import CoreBluetooth
import Foundation

// A Bluetooth heart-rate strap (standard Heart Rate Service 0x180D), paired
// once and then connected only while something needs it: a recording run,
// or the pairing screen showing the strap's live number.
//
// Battery: CoreBluetooth owns the radio; a connected strap notifies about
// once a second and nothing here polls. The central manager is created
// lazily, so an athlete who never pairs a strap never sees the Bluetooth
// permission sheet and never wakes the radio. A pending connect has no
// timeout on iOS: a strap that's off or out of range is picked up the
// moment it wakes, with no scanning.
//
// Main thread throughout (the central's queue is nil = main).
final class HeartRateMonitor: NSObject {
  static let shared = HeartRateMonitor()

  static let service = CBUUID(string: "180D")
  static let measurement = CBUUID(string: "2A37")
  private static let savedIdKey = "expo-workoutkit.heartRateMonitor.id"
  private static let savedNameKey = "expo-workoutkit.heartRateMonitor.name"
  private static let scanForS: TimeInterval = 20

  // Pairing screen: the straps found so far, and connection changes.
  var onMonitors: (([[String: Any]]) -> Void)?
  var onState: (([String: Any]) -> Void)?
  // The recorder: one reading, as it arrives.
  var onReading: ((Int) -> Void)?

  private var central: CBCentralManager?
  private var peripheral: CBPeripheral?
  private var found: [CBPeripheral] = []
  private var wantsScan = false
  private var scanTimer: Timer?
  // Who needs the strap connected ("run", "screen"); empty = disconnect.
  private var holders = Set<String>()
  private(set) var connection = "disconnected"
  private(set) var latestBpm: Int?
  private(set) var latestAt: Date?

  // The host app must declare why it uses Bluetooth, or touching
  // CoreBluetooth kills the app. Without it, straps simply don't exist.
  var supported: Bool {
    Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil
  }

  var saved: [String: Any]? {
    guard let id = UserDefaults.standard.string(forKey: Self.savedIdKey) else { return nil }
    return ["id": id, "name": UserDefaults.standard.string(forKey: Self.savedNameKey) ?? ""]
  }

  private var savedId: UUID? {
    UserDefaults.standard.string(forKey: Self.savedIdKey).flatMap(UUID.init(uuidString:))
  }

  /// "granted" | "denied" | "undetermined", without ever prompting.
  var permission: String {
    switch CBManager.authorization {
    case .allowedAlways: return "granted"
    case .denied, .restricted: return "denied"
    default: return "undetermined"
    }
  }

  // MARK: - Pairing

  func scan() {
    guard supported else { return }
    wantsScan = true
    found = peripheral.map { [$0] } ?? []
    scanTimer?.invalidate()
    scanTimer = Timer.scheduledTimer(withTimeInterval: Self.scanForS, repeats: false) { [weak self] _ in
      self?.stopScan()
    }
    ensureCentral()
    startScanIfReady()
    // The pairing screen shows the paired strap's live number while open.
    hold("screen")
    emitState()
  }

  func stopScan() {
    scanTimer?.invalidate()
    scanTimer = nil
    guard wantsScan else { return }
    wantsScan = false
    if central?.isScanning == true { central?.stopScan() }
    emitState()
  }

  /// Remembers this strap and connects to it while the screen holds it.
  func pair(_ id: String) -> Bool {
    guard let uuid = UUID(uuidString: id) else { return false }
    let match = found.first { $0.identifier == uuid }
      ?? central?.retrievePeripherals(withIdentifiers: [uuid]).first
    guard let match else { return false }
    if let current = peripheral, current.identifier != uuid { central?.cancelPeripheralConnection(current) }
    UserDefaults.standard.set(id, forKey: Self.savedIdKey)
    UserDefaults.standard.set(match.name ?? "", forKey: Self.savedNameKey)
    peripheral = nil
    latestBpm = nil
    latestAt = nil
    stopScan()
    hold("screen")
    return true
  }

  func forget() {
    if let peripheral { central?.cancelPeripheralConnection(peripheral) }
    peripheral = nil
    UserDefaults.standard.removeObject(forKey: Self.savedIdKey)
    UserDefaults.standard.removeObject(forKey: Self.savedNameKey)
    latestBpm = nil
    latestAt = nil
    connection = "disconnected"
    emitState()
  }

  // MARK: - Connection

  /// Something needs the paired strap: connect (or keep it). No-op without one.
  func hold(_ who: String) {
    guard supported, savedId != nil else { return }
    holders.insert(who)
    ensureCentral()
    connectIfReady()
  }

  func release(_ who: String) {
    holders.remove(who)
    guard holders.isEmpty else { return }
    if let peripheral { central?.cancelPeripheralConnection(peripheral) }
    peripheral = nil
    latestBpm = nil
    latestAt = nil
    connection = "disconnected"
    emitState()
  }

  /// The latest reading if it's no older than maxAgeS.
  func fresh(maxAgeS: TimeInterval) -> Int? {
    guard let bpm = latestBpm, let at = latestAt, -at.timeIntervalSinceNow <= maxAgeS else { return nil }
    return bpm
  }

  // MARK: - Internals

  private func ensureCentral() {
    guard central == nil else { return }
    central = CBCentralManager(
      delegate: self, queue: nil,
      options: [CBCentralManagerOptionShowPowerAlertKey: false])
  }

  private func startScanIfReady() {
    guard wantsScan, let central, central.state == .poweredOn, !central.isScanning else { return }
    // Straps that are already connected to this phone (another app, or
    // us) don't advertise; list them too.
    for p in central.retrieveConnectedPeripherals(withServices: [Self.service])
    where !found.contains(where: { $0.identifier == p.identifier }) {
      found.append(p)
    }
    emitMonitors()
    central.scanForPeripherals(withServices: [Self.service], options: nil)
  }

  private func connectIfReady() {
    guard !holders.isEmpty, let central, central.state == .poweredOn, let id = savedId else {
      emitState()
      return
    }
    if let peripheral, peripheral.identifier == id,
       peripheral.state == .connected || peripheral.state == .connecting {
      return
    }
    guard let target = central.retrievePeripherals(withIdentifiers: [id]).first else {
      connection = "disconnected"
      emitState()
      return
    }
    peripheral = target
    target.delegate = self
    connection = "connecting"
    central.connect(target, options: nil)
    emitState()
  }

  private func emitMonitors() {
    onMonitors?(found.map { ["id": $0.identifier.uuidString, "name": $0.name ?? ""] })
  }

  private var bluetoothState: String {
    guard let central else { return "unknown" }
    switch central.state {
    case .poweredOn: return "on"
    case .poweredOff: return "off"
    case .unauthorized: return "unauthorized"
    case .unsupported: return "unsupported"
    default: return "unknown"
    }
  }

  private func emitState() {
    var out: [String: Any] = [
      "bluetooth": bluetoothState,
      "connection": connection,
      "scanning": wantsScan,
    ]
    if let bpm = fresh(maxAgeS: 5) { out["bpm"] = bpm }
    onState?(out)
  }
}

extension HeartRateMonitor: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    if central.state == .poweredOn {
      startScanIfReady()
      connectIfReady()
    } else {
      // Bluetooth off or refused: CoreBluetooth has dropped every
      // connection; a later poweredOn reconnects whoever still holds.
      peripheral = nil
      connection = "disconnected"
      latestBpm = nil
      latestAt = nil
    }
    emitState()
  }

  func centralManager(
    _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any], rssi RSSI: NSNumber
  ) {
    guard !found.contains(where: { $0.identifier == peripheral.identifier }) else { return }
    found.append(peripheral)
    emitMonitors()
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard peripheral.identifier == self.peripheral?.identifier else { return }
    connection = "connected"
    peripheral.discoverServices([Self.service])
    emitState()
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    guard peripheral.identifier == self.peripheral?.identifier else { return }
    self.peripheral = nil
    connection = "disconnected"
    emitState()
    connectIfReady()
  }

  func centralManager(
    _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
  ) {
    guard peripheral.identifier == self.peripheral?.identifier else { return }
    self.peripheral = nil
    connection = "disconnected"
    latestBpm = nil
    latestAt = nil
    emitState()
    // Out of range mid-run: a pending connect picks it back up.
    connectIfReady()
  }
}

extension HeartRateMonitor: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    for service in peripheral.services ?? [] where service.uuid == Self.service {
      peripheral.discoverCharacteristics([Self.measurement], for: service)
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
  ) {
    for c in service.characteristics ?? [] where c.uuid == Self.measurement {
      peripheral.setNotifyValue(true, for: c)
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
  ) {
    guard characteristic.uuid == Self.measurement, let data = characteristic.value,
          let bpm = HeartRateMeasurement.bpm([UInt8](data))
    else { return }
    let first = latestBpm == nil
    latestBpm = bpm
    latestAt = Date()
    onReading?(bpm)
    // The pairing screen shows the live number; 1 Hz is the strap's own rate.
    if holders.contains("screen") || first { emitState() }
  }
}
