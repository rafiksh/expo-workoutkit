package expo.modules.workoutkit

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import androidx.core.content.ContextCompat
import java.util.UUID

// Bluetooth Heart Rate Measurement (0x2A37), the packet every strap sends
// about once a second. Byte 0 flags: bit 0 = uint16 value (else uint8),
// bit 1 = skin contact, bit 2 = contact is reported. Mirrors
// ios/HeartRateMeasurement.swift.
object HeartRateMeasurement {
  /** Beats per minute, or null for a short packet, a strap off skin, or a value no heart makes. */
  fun bpm(bytes: ByteArray): Int? {
    if (bytes.isEmpty()) return null
    val flags = bytes[0].toInt() and 0xFF
    val wide = flags and 0x01 != 0
    val contactReported = flags and 0x04 != 0
    val contact = flags and 0x02 != 0
    if (contactReported && !contact) return null
    val value = if (wide) {
      if (bytes.size < 3) return null
      (bytes[1].toInt() and 0xFF) or ((bytes[2].toInt() and 0xFF) shl 8)
    } else {
      if (bytes.size < 2) return null
      bytes[1].toInt() and 0xFF
    }
    return if (value in 25..250) value else null
  }
}

// A Bluetooth heart-rate strap (Heart Rate Service 0x180D), the twin of
// ios/HeartRateMonitor.swift: paired once, connected only while something
// holds it (a recording run, warm-up, or the pairing screen). The stack
// owns the radio; autoConnect means a strap out of range or asleep is
// picked up when it wakes, with no scanning. Health Connect has no live
// heart-rate stream, so on Android a strap is the only live source.
//
// Everything is handed to the main looper, like RunRecorder.
@SuppressLint("MissingPermission")
object HeartRateMonitor {
  private val SERVICE: UUID = UUID.fromString("0000180d-0000-1000-8000-00805f9b34fb")
  private val MEASUREMENT: UUID = UUID.fromString("00002a37-0000-1000-8000-00805f9b34fb")
  private val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
  private const val PREFS = "expo-workoutkit.heartRateMonitor"
  private const val SCAN_FOR_MS = 20_000L

  var onMonitors: ((List<Map<String, Any?>>) -> Unit)? = null
  var onState: ((Map<String, Any?>) -> Unit)? = null
  var onReading: ((Int) -> Unit)? = null

  private var context: Context? = null
  private val main = Handler(Looper.getMainLooper())
  private var gatt: BluetoothGatt? = null
  private val found = LinkedHashMap<String, String>()
  private var scanning = false
  private val holders = HashSet<String>()
  private var connection = "disconnected"
  private var latestBpm: Int? = null
  private var latestAtMs: Long? = null
  private val stopScanLater = Runnable { stopScan() }

  fun attach(context: Context) {
    if (this.context == null) this.context = context.applicationContext
  }

  private val adapter: BluetoothAdapter?
    get() = (context?.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

  val supported: Boolean
    get() = context?.packageManager?.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE) == true

  /** The runtime permissions scanning and connecting need on this version. */
  val permissions: Array<String>
    get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
    } else {
      arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
    }

  fun granted(): Boolean {
    val ctx = context ?: return false
    return permissions.all { ContextCompat.checkSelfPermission(ctx, it) == PackageManager.PERMISSION_GRANTED }
  }

  private fun canConnect(): Boolean {
    val ctx = context ?: return false
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
    return ContextCompat.checkSelfPermission(ctx, Manifest.permission.BLUETOOTH_CONNECT) ==
      PackageManager.PERMISSION_GRANTED
  }

  private val prefs get() = context?.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

  val saved: Map<String, Any?>?
    get() {
      val id = prefs?.getString("id", null) ?: return null
      return mapOf("id" to id, "name" to (prefs?.getString("name", "") ?: ""))
    }

  private val savedId: String? get() = prefs?.getString("id", null)

  // MARK: - Pairing

  fun scan() {
    if (!supported || !granted()) return emitState()
    val scanner = adapter?.takeIf { it.isEnabled }?.bluetoothLeScanner ?: return emitState()
    found.clear()
    gatt?.device?.let { found[it.address] = deviceName(it) }
    main.removeCallbacks(stopScanLater)
    main.postDelayed(stopScanLater, SCAN_FOR_MS)
    if (!scanning) {
      val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE)).build()
      val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
      runCatching { scanner.startScan(listOf(filter), settings, scanCallback) }
        .onSuccess { scanning = true }
    }
    emitMonitors()
    hold("screen")
    emitState()
  }

  fun stopScan() {
    main.removeCallbacks(stopScanLater)
    if (!scanning) return
    scanning = false
    runCatching { adapter?.bluetoothLeScanner?.stopScan(scanCallback) }
    emitState()
  }

  fun pair(id: String): Boolean {
    val name = found[id] ?: return false
    if (gatt?.device?.address != id) closeGatt()
    prefs?.edit()?.putString("id", id)?.putString("name", name)?.apply()
    latestBpm = null
    latestAtMs = null
    stopScan()
    hold("screen")
    return true
  }

  fun forget() {
    closeGatt()
    prefs?.edit()?.clear()?.apply()
    emitState()
  }

  // MARK: - Connection

  fun hold(who: String) {
    if (!supported || savedId == null) return
    holders.add(who)
    connect()
  }

  fun release(who: String) {
    holders.remove(who)
    if (holders.isNotEmpty()) return
    closeGatt()
    emitState()
  }

  fun fresh(maxAgeMs: Long): Int? {
    val at = latestAtMs ?: return null
    return if (System.currentTimeMillis() - at <= maxAgeMs) latestBpm else null
  }

  // MARK: - Internals

  private fun connect() {
    val ctx = context ?: return
    val id = savedId ?: return
    if (holders.isEmpty() || !canConnect()) return emitState()
    if (gatt?.device?.address == id) return
    val device = runCatching { adapter?.getRemoteDevice(id) }.getOrNull() ?: return emitState()
    connection = "connecting"
    gatt = device.connectGatt(ctx, true, gattCallback, BluetoothDevice.TRANSPORT_LE)
    emitState()
  }

  private fun closeGatt() {
    runCatching { gatt?.disconnect() }
    runCatching { gatt?.close() }
    gatt = null
    connection = "disconnected"
    latestBpm = null
    latestAtMs = null
  }

  private fun deviceName(device: BluetoothDevice): String =
    if (canConnect()) runCatching { device.name }.getOrNull() ?: "" else ""

  private val scanCallback = object : ScanCallback() {
    override fun onScanResult(callbackType: Int, result: ScanResult) {
      val device = result.device
      val name = result.scanRecord?.deviceName ?: deviceName(device)
      main.post {
        if (found.containsKey(device.address)) return@post
        found[device.address] = name
        emitMonitors()
      }
    }

    override fun onScanFailed(errorCode: Int) {
      main.post {
        scanning = false
        emitState()
      }
    }
  }

  private val gattCallback = object : BluetoothGattCallback() {
    override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
      main.post {
        if (g != gatt) return@post
        if (newState == BluetoothProfile.STATE_CONNECTED) {
          connection = "connected"
          g.discoverServices()
        } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
          // autoConnect keeps trying on its own while the gatt stays open.
          connection = if (holders.isEmpty()) "disconnected" else "connecting"
          latestBpm = null
          latestAtMs = null
        }
        emitState()
      }
    }

    @Suppress("DEPRECATION")
    override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
      main.post {
        if (g != gatt) return@post
        val c = g.getService(SERVICE)?.getCharacteristic(MEASUREMENT) ?: return@post
        g.setCharacteristicNotification(c, true)
        val d = c.getDescriptor(CCCD) ?: return@post
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
          g.writeDescriptor(d, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
        } else {
          d.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
          g.writeDescriptor(d)
        }
      }
    }

    // Android 13+.
    override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray) {
      reading(g, c, value)
    }

    // Android 12 and below.
    @Deprecated("Deprecated in Java")
    @Suppress("DEPRECATION")
    override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
      reading(g, c, c.value ?: return)
    }
  }

  private fun reading(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray) {
    if (c.uuid != MEASUREMENT) return
    val bpm = HeartRateMeasurement.bpm(value.copyOf()) ?: return
    main.post {
      if (g != gatt) return@post
      val first = latestBpm == null
      latestBpm = bpm
      latestAtMs = System.currentTimeMillis()
      onReading?.invoke(bpm)
      if (holders.contains("screen") || first) emitState()
    }
  }

  private fun emitMonitors() {
    onMonitors?.invoke(found.map { (id, name) -> mapOf("id" to id, "name" to name) })
  }

  private fun bluetoothState(): String {
    if (!supported) return "unsupported"
    if (!granted()) return "unauthorized"
    val a = adapter ?: return "unsupported"
    return if (a.isEnabled) "on" else "off"
  }

  private fun emitState() {
    val out = HashMap<String, Any?>()
    out["bluetooth"] = bluetoothState()
    out["connection"] = connection
    out["scanning"] = scanning
    fresh(5_000)?.let { out["bpm"] = it }
    onState?.invoke(out)
  }
}
