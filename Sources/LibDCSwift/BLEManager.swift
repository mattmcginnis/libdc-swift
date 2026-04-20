import Foundation
#if canImport(UIKit)
import UIKit
#endif
import CoreBluetooth
import Clibdivecomputer
import LibDCBridge
import LibDCBridge.CoreBluetoothManagerProtocol
import Combine

/// Represents a BLE serial service with its identifying information
@objc(SerialService)
class SerialService: NSObject {
    @objc let uuid: String
    @objc let vendor: String
    @objc let product: String
    
    @objc init(uuid: String, vendor: String, product: String) {
        self.uuid = uuid
        self.vendor = vendor
        self.product = product
        super.init()
    }
}

/// Extension to check if a CBUUID is a standard Bluetooth service UUID
extension CBUUID {
    var isStandardBluetooth: Bool {
        return self.data.count == 2
    }
}

/// Central manager for handling BLE communications with dive computers.
/// Manages device discovery, connection, and data transfer with BLE dive computers.
@objc(CoreBluetoothManager)
public class CoreBluetoothManager: NSObject, CoreBluetoothManagerProtocol, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    // MARK: - Singleton
    private static let sharedInstance = CoreBluetoothManager()
    
    @objc public static func shared() -> Any! {
        return sharedInstance
    }
    
    public static var sharedManager: CoreBluetoothManager {
        return sharedInstance
    }
    
    // MARK: - Published Properties
    @Published public var centralManager: CBCentralManager! // Core Bluetooth central manager instance
    @Published public var peripheral: CBPeripheral? // Currently selected peripheral device
    @Published public var discoveredPeripherals: [CBPeripheral] = [] // List of discovered BLE peripherals
    @Published public var isPeripheralReady = false // Indicates if peripheral is ready for communication
    @Published @objc dynamic public var connectedDevice: CBPeripheral? // Currently connected peripheral device
    @Published public var isScanning = false // Indicates if currently scanning for devices
    @Published public var isRetrievingLogs = false { // Indicates if currently retrieving dive logs
        didSet {
            objectWillChange.send()
        }
    }
    @Published public var currentRetrievalDevice: CBPeripheral? { // Device currently being used for log retrieval
        didSet {
            objectWillChange.send()
        }
    }
    @Published public var isDisconnecting = false // Indicates if currently disconnecting from device
    @Published public var isBluetoothReady = false // Indicates if Bluetooth is ready for use
    @Published public var isConnecting = false // Indicates if a connection attempt is in progress (prevents auto-reconnect)
    @Published private var deviceDataPtrChanged = false

    // MARK: - Private Properties
    @objc private var timeout: Int = -1 // default to no timeout
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var receivedData: Data = Data()
    private let queue = DispatchQueue(label: "com.blemanager.queue")
    private let dataAvailableSemaphore = DispatchSemaphore(value: 0) // Signals when new data arrives
    private let frameMarker: UInt8 = 0x7E
    private var _deviceDataPtr: UnsafeMutablePointer<device_data_t>?
    private var connectionCompletion: ((Bool) -> Void)?
    private var totalBytesReceived: Int = 0
    private var lastDataReceived: Date?
    private var averageTransferRate: Double = 0
    private var preferredService: CBService?
    private var pendingOperations: [() -> Void] = []
    private var advertisedServiceUUIDs: [UUID: [CBUUID]] = [:]
    private var lastAdvertisedRSSI: [UUID: Int] = [:]
    private var lastCloseTime: Date? = nil
    private let reconnectCooldown: TimeInterval = 3.0
    
    // MARK: - Public Properties
    public var openedDeviceDataPtr: UnsafeMutablePointer<device_data_t>? { // Public access to device data pointer with change notification
        get {
            _deviceDataPtr
        }
        set {
            objectWillChange.send()
            _deviceDataPtr = newValue
        }
    }
    
    /// Checks if there is a valid device data pointer
    /// - Returns: True if device data pointer exists
    public func hasValidDeviceDataPtr() -> Bool {
        return openedDeviceDataPtr != nil
    }
    
    // MARK: - Serial Services
    /// Known BLE serial services for supported dive computers
    @objc private let knownSerialServices: [SerialService] = [
        SerialService(uuid: "0000fefb-0000-1000-8000-00805f9b34fb", vendor: "Heinrichs-Weikamp", product: "Telit/Stollmann"),
        SerialService(uuid: "2456e1b9-26e2-8f83-e744-f34f01e9d701", vendor: "Heinrichs-Weikamp", product: "U-Blox"),
        SerialService(uuid: "544e326b-5b72-c6b0-1c46-41c1bc448118", vendor: "Mares", product: "BlueLink Pro"),
        SerialService(uuid: "6e400001-b5a3-f393-e0a9-e50e24dcca9e", vendor: "Nordic Semi", product: "UART"),
        SerialService(uuid: "98ae7120-e62e-11e3-badd-0002a5d5c51b", vendor: "Suunto", product: "EON Steel/Core"),
        SerialService(uuid: "cb3c4555-d670-4670-bc20-b61dbc851e9a", vendor: "Pelagic", product: "i770R/i200C"),
        SerialService(uuid: "ca7b0001-f785-4c38-b599-c7c5fbadb034", vendor: "Pelagic", product: "i330R/DSX"),
        SerialService(uuid: "fdcdeaaa-295d-470e-bf15-04217b7aa0a0", vendor: "ScubaPro", product: "G2/G3"),
        SerialService(uuid: "fe25c237-0ece-443c-b0aa-e02033e7029d", vendor: "Shearwater", product: "Perdix/Teric"),
        SerialService(uuid: "0000fcef-0000-1000-8000-00805f9b34fb", vendor: "Divesoft", product: "Freedom")
    ]
    
    /// Service UUIDs to exclude from discovery
    private let excludedServices: Set<String> = [
        "00001530-1212-efde-1523-785feabcd123", // Nordic Upgrade
        "9e5d1e47-5c13-43a0-8635-82ad38a1386f", // Broadcom Upgrade #1
        "a86abc2d-d44c-442e-99f7-80059a873e36"  // Broadcom Upgrade #2
    ]
    
    // MARK: - Initialization
    private override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    // MARK: - Service Discovery
    @objc(getPeripheralReadyState)
    public func getPeripheralReadyState() -> Bool {
        return self.isPeripheralReady
    }

    @objc(getPeripheralName)
    public func getPeripheralName() -> String? {
        return self.peripheral?.name
    }

    @objc(discoverServices)
    public func discoverServices() -> Bool {
        guard let peripheral = self.peripheral else {
            logError("No peripheral available for service discovery")
            return false
        }
        
        // Check if peripheral is actually connected
        guard peripheral.state == .connected else {
            logError("Peripheral not in connected state: \(peripheral.state.rawValue)")
            return false
        }
        
        // Use advertised service UUIDs for targeted discovery if available,
        // otherwise fall back to discovering all services.
        let targetUUIDs: [CBUUID]? = {
            let advertised = advertisedServiceUUIDs[peripheral.identifier] ?? []
            let known = advertised.filter { isKnownSerialService($0) != nil }
            return known.isEmpty ? nil : known
        }()
        logInfo("discoverServices: peripheral=\(peripheral.name ?? "?") state=\(peripheral.state.rawValue) targetUUIDs=\(targetUUIDs?.map { $0.uuidString } ?? ["nil — discovering all"])")
        peripheral.discoverServices(targetUUIDs)

        let timeout = Date(timeIntervalSinceNow: 10.0)
        var lastLog = Date()
        while writeCharacteristic == nil || notifyCharacteristic == nil {
            if Date() > timeout {
                logError("discoverServices: TIMEOUT (10s) — writeChar=\(writeCharacteristic?.uuid.uuidString ?? "nil") notifyChar=\(notifyCharacteristic?.uuid.uuidString ?? "nil")")
                return false
            }
            if Date().timeIntervalSince(lastLog) >= 1.0 {
                logInfo("discoverServices: waiting… writeChar=\(writeCharacteristic?.uuid.uuidString ?? "nil") notifyChar=\(notifyCharacteristic?.uuid.uuidString ?? "nil")")
                lastLog = Date()
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        logInfo("discoverServices: done — writeChar=\(writeCharacteristic!.uuid.uuidString) notifyChar=\(notifyCharacteristic!.uuid.uuidString)")
        return true
    }
    
    @objc(enableNotifications)
    public func enableNotifications() -> Bool {
        guard let notifyCharacteristic = self.notifyCharacteristic,
              let peripheral = self.peripheral else {
            logError("Missing characteristic or peripheral for notifications")
            return false
        }
        
        // Check if peripheral is actually connected
        guard peripheral.state == .connected else {
            logError("Peripheral not in connected state for notifications: \(peripheral.state.rawValue)")
            return false
        }
        
        logInfo("enableNotifications: calling setNotifyValue(true) on \(notifyCharacteristic.uuid.uuidString) isNotifying=\(notifyCharacteristic.isNotifying)")
        peripheral.setNotifyValue(true, for: notifyCharacteristic)

        // Wait for notifications to be enabled with timeout
        let timeout = Date(timeIntervalSinceNow: 5.0)
        var lastLog = Date()
        while !notifyCharacteristic.isNotifying {
            if Date() > timeout {
                logError("enableNotifications: TIMEOUT — isNotifying still false after 5s")
                return false
            }
            if Date().timeIntervalSince(lastLog) >= 0.5 {
                logInfo("enableNotifications: still waiting… isNotifying=\(notifyCharacteristic.isNotifying)")
                lastLog = Date()
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        logInfo("enableNotifications: confirmed isNotifying=true for \(notifyCharacteristic.uuid.uuidString)")
        return true
    }
    
    // MARK: - Data Handling
    private func findNextCompleteFrame() -> Data? {
        var frameToReturn: Data? = nil
        
        queue.sync {
            guard let startIndex = receivedData.firstIndex(of: frameMarker) else {
                return
            }
            
            let afterStart = receivedData.index(after: startIndex)
            guard afterStart < receivedData.count,
                  let endIndex = receivedData[afterStart...].firstIndex(of: frameMarker) else {
                return
            }
            
            let frameEndIndex = receivedData.index(after: endIndex)
            let frame = receivedData[startIndex..<frameEndIndex]
            
            receivedData.removeSubrange(startIndex..<frameEndIndex)
            frameToReturn = Data(frame)
        }
        
        return frameToReturn
    }
    
    @objc public func write(_ data: Data!) -> Bool {
        guard let peripheral = self.peripheral,
              let characteristic = self.writeCharacteristic else { return false }
        // Prefer .withResponse when the characteristic supports it — the device
        // application layer may only process ATT_WRITE_REQ even if it also
        // advertises .writeWithoutResponse. Only fall back to .withoutResponse
        // when .write is absent.
        let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.write)
            ? .withResponse
            : .withoutResponse
        let typeLabel = writeType == .withResponse ? "withRsp" : "noRsp"
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        // For .withoutResponse, canSendWriteWithoutResponse being false means the write will
        // sit in iOS's internal queue until peripheralIsReady(toSendWriteWithoutResponse:)
        // fires. Logging it catches silent buffer-full drops.
        let canSend = peripheral.canSendWriteWithoutResponse
        logInfo("write \(data.count)b type=\(typeLabel) char=\(characteristic.uuid.uuidString) canSendNoRsp=\(canSend) state=\(peripheral.state.rawValue): \(hex)")
        peripheral.writeValue(data, for: characteristic, type: writeType)
        return true
    }
    
    @objc public func readDataPartial(_ requested: Int32) -> Data? {
        let requestedInt = Int(requested)
        let startTime = Date()
        let timeout: TimeInterval = 10.0
        logInfo("readDataPartial: start requested=\(requestedInt) bufSize=\(receivedData.count)")

        var lastLog = Date()
        var polledReadChars = false
        while Date().timeIntervalSince(startTime) < timeout {
            var outData: Data?

            queue.sync {
                if !receivedData.isEmpty {
                    let amount = min(requestedInt, receivedData.count)
                    outData = receivedData.prefix(amount)
                    receivedData.removeSubrange(0..<amount)
                }
            }

            if let data = outData {
                let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
                logInfo("readDataPartial: got \(data.count)b: \(hex)")
                return data
            }

            let result = dataAvailableSemaphore.wait(timeout: .now() + .milliseconds(50))
            if result == .success {
                logInfo("readDataPartial: semaphore signaled — bufSize=\(receivedData.count)")
            }
            let elapsedSec = Date().timeIntervalSince(startTime)
            // Once, after 3s of silence, actively poll every [read] char in the chosen service.
            // Some BLE stacks on dive computers post response data to a read-only characteristic
            // instead of sending notifications — without this probe we'd never see it.
            // Values surface via peripheral.didUpdateValueFor, which we already log.
            if !polledReadChars && elapsedSec >= 3.0 {
                polledReadChars = true
                pollReadableCharsForDiagnostic()
            }
            if Date().timeIntervalSince(lastLog) >= 1.0 {
                let elapsed = String(format: "%.1f", elapsedSec)
                logInfo("readDataPartial: waiting… elapsed=\(elapsed)s bufSize=\(receivedData.count)")
                lastLog = Date()
            }
        }

        logError("readDataPartial: TIMEOUT after 10s — no data received")
        return nil
    }

    /// Fire off explicit reads on every [read] characteristic in the active service.
    /// Diagnostic only — output surfaces via didUpdateValueFor. Does not consume buffered data.
    private func pollReadableCharsForDiagnostic() {
        guard let peripheral = self.peripheral,
              let service = self.preferredService,
              let characteristics = service.characteristics else {
            logInfo("pollReadableChars: no peripheral/service — skipping diagnostic")
            return
        }
        let readable = characteristics.filter { $0.properties.contains(.read) }
        logInfo("pollReadableChars: DIAGNOSTIC — reading \(readable.count) [read] chars (handshake silent for 3s)")
        for char in readable {
            logInfo("pollReadableChars: issuing readValue for \(char.uuid.uuidString)")
            peripheral.readValue(for: char)
        }
    }
    
    // MARK: - Device Management
    @objc public func close(clearDevicePtr: Bool = false) {
        logInfo("close: called clearDevicePtr=\(clearDevicePtr) peripheral=\(peripheral?.name ?? "nil") state=\(peripheral?.state.rawValue ?? -1)")
        lastCloseTime = Date()
        isDisconnecting = true
        DispatchQueue.main.async {
            self.isPeripheralReady = false
            self.connectedDevice = nil
        }
        queue.sync {
            if !receivedData.isEmpty {
                receivedData.removeAll()
            }
        }

        // Drain and signal semaphore to unblock any waiting reads and clear stale signals
        while dataAvailableSemaphore.wait(timeout: .now()) == .success {
            // Drain any accumulated signals
        }
        dataAvailableSemaphore.signal() // Signal once to unblock any waiting read

        if clearDevicePtr {
            if let devicePtr = self.openedDeviceDataPtr {
                if devicePtr.pointee.device != nil {
                    dc_device_close(devicePtr.pointee.device)
                }
                devicePtr.deallocate()
                self.openedDeviceDataPtr = nil
            }
        }
        
        if let peripheral = self.peripheral {
            self.writeCharacteristic = nil
            self.notifyCharacteristic = nil
            self.peripheral = nil
            centralManager.cancelPeripheralConnection(peripheral)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.isDisconnecting = false
        }
    }
    
    public func startScanning(omitUnsupportedPeripherals: Bool = true) {
        centralManager.scanForPeripherals(
            withServices: omitUnsupportedPeripherals ? knownSerialServices.map { CBUUID(string: $0.uuid) } : nil,
            options: nil)
        isScanning = true
    }
    
    public func stopScanning() {
        centralManager.stopScan()
        isScanning = false
    }
    
    @objc public func connect(toDevice address: String!) -> Bool {
        if let lastClose = lastCloseTime {
            let elapsed = Date().timeIntervalSince(lastClose)
            if elapsed < reconnectCooldown {
                logError("connect(toDevice:): BLOCKED — \(String(format: "%.2f", elapsed))s since last close, cooldown is \(reconnectCooldown)s. Protecting device from rapid reconnect.")
                return false
            }
        }

        guard let uuid = UUID(uuidString: address),
              let peripheral = centralManager.retrievePeripherals(withIdentifiers: [uuid]).first else {
            logError("connect(toDevice:): no peripheral found for address=\(address ?? "nil")")
            return false
        }

        logInfo("connect(toDevice:): peripheral=\(peripheral.name ?? "?") state=\(peripheral.state.rawValue) address=\(address ?? "nil")")
        self.peripheral = peripheral
        peripheral.delegate = self

        if peripheral.state == .connected {
            logInfo("connect(toDevice:): already connected — skipping centralManager.connect()")
            return true
        }
        logInfo("connect(toDevice:): calling centralManager.connect()")
        centralManager.connect(peripheral, options: nil)
        return true
    }
    
    public func connectToStoredDevice(_ uuid: String) -> Bool {
        guard let storedDevice = DeviceStorage.shared.getStoredDevice(uuid: uuid) else {
            return false
        }
        
        return DeviceConfiguration.openBLEDevice(
            name: storedDevice.name,
            deviceAddress: storedDevice.uuid
        )
    }
    
    // MARK: - State Management
    public func clearRetrievalState() {
        DispatchQueue.main.async { [weak self] in
            self?.isRetrievingLogs = false
            self?.currentRetrievalDevice = nil
        }
    }
    
    public func setBackgroundMode(_ enabled: Bool) {
        if enabled {
            // Set connection parameters for background operation
            if let peripheral = peripheral {
                // For iOS/macOS, we can only ensure the connection stays alive
                // by maintaining the peripheral reference and keeping the central manager active
                
                #if os(iOS)
                // On iOS, we can request background execution time
                var backgroundTask: UIBackgroundTaskIdentifier = .invalid
                backgroundTask = UIApplication.shared.beginBackgroundTask { [backgroundTask] in
                    // Cleanup callback
                    if backgroundTask != .invalid {
                        UIApplication.shared.endBackgroundTask(backgroundTask)
                    }
                }
                
                // Store the task identifier for later cleanup
                currentBackgroundTask = backgroundTask
                #endif
            }
        } else {
            #if os(iOS)
            // Clean up any background tasks when disabling background mode
            if let peripheral = peripheral {
                if let task = currentBackgroundTask, task != .invalid {
                    UIApplication.shared.endBackgroundTask(task)
                    currentBackgroundTask = nil
                }
            }
            #endif
        }
    }

    // track background tasks
    #if os(iOS)
    private var currentBackgroundTask: UIBackgroundTaskIdentifier?
    #endif

    public func systemDisconnect(_ peripheral: CBPeripheral) {
        logInfo("Performing system-level disconnect for \(peripheral.name ?? "Unknown Device")")
        DispatchQueue.main.async {
            self.isPeripheralReady = false
            self.connectedDevice = nil
            self.writeCharacteristic = nil
            self.notifyCharacteristic = nil
            self.peripheral = nil
        }
        centralManager.cancelPeripheralConnection(peripheral)
    }
    
    public func clearDiscoveredPeripherals() {
        DispatchQueue.main.async {
            self.discoveredPeripherals.removeAll()
        }
    }
    
    public func addDiscoveredPeripheral(_ peripheral: CBPeripheral) {
        DispatchQueue.main.async {
            if !self.discoveredPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
                self.discoveredPeripherals.append(peripheral)
            }
        }
    }

    public func queueOperation(_ operation: @escaping () -> Void) {
        if isBluetoothReady {
            operation()
        } else {
            pendingOperations.append(operation)
        }
    }
    
    // MARK: - CBCentralManagerDelegate Methods
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            logInfo("Bluetooth is powered on")
            isBluetoothReady = true
            pendingOperations.forEach { $0() }
            pendingOperations.removeAll()
        case .poweredOff:
            logWarning("Bluetooth is powered off")
            isBluetoothReady = false
        case .resetting:
            logWarning("Bluetooth is resetting")
            isBluetoothReady = false
        case .unauthorized:
            logError("Bluetooth is unauthorized")
            isBluetoothReady = false
        case .unsupported:
            logError("Bluetooth is unsupported")
            isBluetoothReady = false
        case .unknown:
            logWarning("Bluetooth state is unknown")
            isBluetoothReady = false
        @unknown default:
            logWarning("Unknown Bluetooth state")
            isBluetoothReady = false
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logInfo("didConnect: name=\(peripheral.name ?? "?") id=\(peripheral.identifier) state=\(peripheral.state.rawValue)")
        // Log negotiated MTU for both write types — if a 14-byte handshake silently truncates,
        // this is where we'd catch it. iOS typically negotiates >= 185 bytes, but cheap BLE
        // stacks on dive computers sometimes report as low as 20.
        let mtuWithRsp = peripheral.maximumWriteValueLength(for: .withResponse)
        let mtuNoRsp = peripheral.maximumWriteValueLength(for: .withoutResponse)
        logInfo("didConnect: MTU withResponse=\(mtuWithRsp) withoutResponse=\(mtuNoRsp)")
        peripheral.delegate = self
        // Live link-quality readout. Result arrives via didReadRSSI callback.
        peripheral.readRSSI()
        DispatchQueue.main.async {
            self.isPeripheralReady = true
            self.connectedDevice = peripheral
            logInfo("didConnect: isPeripheralReady=true connectedDevice set")
        }
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logError("didFailToConnect: name=\(peripheral.name ?? "?") error=\(error?.localizedDescription ?? "none")")
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logInfo("didDisconnect: name=\(peripheral.name ?? "?") error=\(error?.localizedDescription ?? "none") isDisconnecting=\(isDisconnecting) isConnecting=\(isConnecting) isRetrievingLogs=\(isRetrievingLogs)")
        if let error = error {
            logError("didDisconnect error detail: \(error.localizedDescription) code=\((error as NSError).code)")
        }
        
        DispatchQueue.main.async {
            self.isPeripheralReady = false
            self.connectedDevice = nil
            
            // Don't attempt to reconnect if:
            // 1. We initiated the disconnect
            // 2. A download is currently in progress (will cause race conditions)
            // 3. A connection attempt is already in progress
            if !self.isDisconnecting && !self.isRetrievingLogs && !self.isConnecting {
                // Attempt to reconnect if this was a stored device
                if let storedDevice = DeviceStorage.shared.getStoredDevice(uuid: peripheral.identifier.uuidString) {
                    logInfo("Attempting to reconnect to stored device")
                    _ = DeviceConfiguration.openBLEDevice(
                        name: storedDevice.name,
                        deviceAddress: storedDevice.uuid
                    )
                }
            } else if self.isRetrievingLogs {
                logWarning("⚠️ Disconnected during download - NOT auto-reconnecting to avoid race condition")
            } else if self.isConnecting {
                logWarning("⚠️ Disconnected during connection attempt - NOT auto-reconnecting")
            }
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if let name = peripheral.name {
            let uuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
            if !uuids.isEmpty {
                advertisedServiceUUIDs[peripheral.identifier] = uuids
            }
            lastAdvertisedRSSI[peripheral.identifier] = RSSI.intValue
            let isSupported = DeviceStorage.shared.getStoredDevice(uuid: peripheral.identifier.uuidString) != nil ||
                              DeviceConfiguration.fromName(name) != nil
            logInfo("BLE peripheral found: \(name) rssi=\(RSSI) uuids=\(uuids.map { $0.uuidString }) supported=\(isSupported)")
            // Aqualung/Pelagic sometimes encode model/serial identifiers in manufacturer data or
            // service data. Logging full raw blobs only for supported devices to avoid noise from
            // neighbouring Samsung TVs / AirPods.
            if isSupported {
                if let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, !mfg.isEmpty {
                    let hex = mfg.map { String(format: "%02X", $0) }.joined(separator: " ")
                    logInfo("  adv manufacturerData (\(mfg.count)b): \(hex)")
                }
                if let svcData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
                    for (uuid, blob) in svcData {
                        let hex = blob.map { String(format: "%02X", $0) }.joined(separator: " ")
                        logInfo("  adv serviceData[\(uuid.uuidString)] (\(blob.count)b): \(hex)")
                    }
                }
                if let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String, localName != name {
                    logInfo("  adv localName='\(localName)' (differs from peripheral.name='\(name)')")
                }
                if let txPower = advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber {
                    logInfo("  adv txPowerLevel=\(txPower)")
                }
                if let isConnectable = advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber {
                    logInfo("  adv isConnectable=\(isConnectable)")
                }
                addDiscoveredPeripheral(peripheral)
            }
        }
    }

    public func advertisedServiceUUIDs(for peripheralID: UUID) -> [CBUUID] {
        return advertisedServiceUUIDs[peripheralID] ?? []
    }

    @objc public func lastRSSI(for peripheralID: UUID) -> Int {
        return lastAdvertisedRSSI[peripheralID] ?? 0
    }

    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if let error = error {
            logError("didReadRSSI: \(peripheral.name ?? "?") error=\(error.localizedDescription)")
            return
        }
        logInfo("didReadRSSI: \(peripheral.name ?? "?") rssi=\(RSSI)")
    }

    // MARK: - CBPeripheral Methods
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            logError("Error discovering services: \(error.localizedDescription)")
            return
        }
        
        guard let services = peripheral.services else {
            logWarning("No services found")
            return
        }
        
        for service in services {
            if isExcludedService(service.uuid) {
                continue
            }
            
            if let knownService = isKnownSerialService(service.uuid) {
                preferredService = service
                writeCharacteristic = nil
                notifyCharacteristic = nil
            }
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            logError("Error discovering characteristics: \(error.localizedDescription)")
            return
        }

        guard let characteristics = service.characteristics else {
            logWarning("No characteristics found for service: \(service.uuid)")
            return
        }

        // When a preferred known serial service was identified, skip all other services
        // to avoid wrong characteristics from generic services (e.g. Device Information)
        // overwriting the correct ones.
        if let preferred = preferredService, service.uuid != preferred.uuid {
            logInfo("Skipping non-preferred service \(service.uuid.uuidString)")
            return
        }

        logInfo("Using characteristics from service \(service.uuid.uuidString)")
        for characteristic in characteristics {
            let props = characteristic.properties
            var propStrs: [String] = []
            if props.contains(.read) { propStrs.append("read") }
            if props.contains(.write) { propStrs.append("write") }
            if props.contains(.writeWithoutResponse) { propStrs.append("writeNoRsp") }
            if props.contains(.notify) { propStrs.append("notify") }
            if props.contains(.indicate) { propStrs.append("indicate") }
            logInfo("  char \(characteristic.uuid.uuidString): [\(propStrs.joined(separator: ","))]")

            if isWriteCharacteristic(characteristic) {
                // Prefer a dedicated write channel with .writeWithoutResponse. Evidence from
                // Aqualung i300C (log 2026-04-19 22:58): writing to the combined write+notify
                // char (A60B8E5C-...-9764) returned ATT error 0x80 (application reject). The
                // device's BLE bridge has application-layer policy that only accepts protocol
                // writes on the writeNoRsp-capable char (6606AB42-...). Sticking with the
                // original selector.
                let hasNoRsp = characteristic.properties.contains(.writeWithoutResponse)
                let currentHasNoRsp = writeCharacteristic?.properties.contains(.writeWithoutResponse) ?? false
                if writeCharacteristic == nil || (hasNoRsp && !currentHasNoRsp) {
                    writeCharacteristic = characteristic
                    logInfo("  → writeCharacteristic = \(characteristic.uuid.uuidString)")
                }
            }

            if isReadCharacteristic(characteristic) {
                notifyCharacteristic = characteristic
                logInfo("  → notifyCharacteristic = \(characteristic.uuid.uuidString)")
                peripheral.setNotifyValue(true, for: characteristic)
            }

            // Descriptor discovery surfaces the CCCD (0x2902) and any user-description / format
            // descriptors. Mainly useful to confirm notifications are truly activated (CCCD value
            // should be 01 00 after setNotifyValue). Logged via didDiscoverDescriptorsFor.
            peripheral.discoverDescriptors(for: characteristic)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logError("didDiscoverDescriptors: char=\(characteristic.uuid.uuidString) err=\(error.localizedDescription)")
            return
        }
        let descriptors = characteristic.descriptors ?? []
        if descriptors.isEmpty { return }
        logInfo("descriptors for char \(characteristic.uuid.uuidString): \(descriptors.count)")
        for desc in descriptors {
            logInfo("  desc \(desc.uuid.uuidString)")
            // Reading each descriptor's value surfaces via didUpdateValueFor(descriptor:).
            peripheral.readValue(for: desc)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        if let error = error {
            logError("didUpdateValueFor(desc): \(descriptor.uuid.uuidString) err=\(error.localizedDescription)")
            return
        }
        // CCCD (0x2902) value is 2 bytes: 0x0001 = notifications, 0x0002 = indications, 0x0000 = off.
        if let data = descriptor.value as? Data {
            let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
            logInfo("desc value \(descriptor.uuid.uuidString): \(hex)")
        } else if let num = descriptor.value as? NSNumber {
            logInfo("desc value \(descriptor.uuid.uuidString): \(num)")
        } else if let s = descriptor.value as? String {
            logInfo("desc value \(descriptor.uuid.uuidString): '\(s)'")
        } else {
            logInfo("desc value \(descriptor.uuid.uuidString): \(String(describing: descriptor.value))")
        }
    }

    // Fires when iOS is ready to accept more writeWithoutResponse writes after the internal
    // buffer had been full. If a .withoutResponse write silently drops, it's because this
    // didn't fire before the next write attempt.
    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        logInfo("peripheralIsReady(toSendWriteWithoutResponse): name=\(peripheral.name ?? "?")")
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logError("Error receiving data: \(error.localizedDescription)")
            return
        }

        guard let data = characteristic.value else {
            return
        }

        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        logInfo("notify \(data.count)b char=\(characteristic.uuid.uuidString): \(hex)")

        queue.sync {
            // Append new data to our buffer immediately
            receivedData.append(data)
        }

        // Signal that data is available - wake up any waiting read
        dataAvailableSemaphore.signal()

        updateTransferStats(data.count)
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            let ns = error as NSError
            logError("didWriteValueFor: FAILED char=\(characteristic.uuid.uuidString) err=\(error.localizedDescription) code=\(ns.code) domain=\(ns.domain)")
        } else {
            // Success confirms the .withResponse write actually made it to the peer's ATT layer.
            // Absence of this log after ble_write means the write was queued but never ACKed —
            // typically a silent link drop or wrong write-type.
            logInfo("didWriteValueFor: OK char=\(characteristic.uuid.uuidString)")
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logError("notifyState: ERROR on \(characteristic.uuid.uuidString): \(error.localizedDescription)")
        } else {
            logInfo("notifyState: \(characteristic.uuid.uuidString) isNotifying=\(characteristic.isNotifying)")
        }
    }

    // MARK: - Private Helpers
    private func updateTransferStats(_ newBytes: Int) {
        totalBytesReceived += newBytes
        
        if let last = lastDataReceived {
            let interval = Date().timeIntervalSince(last)
            if interval > 0 {
                let currentRate = Double(newBytes) / interval
                averageTransferRate = (averageTransferRate * 0.7) + (currentRate * 0.3)
            }
        }
        
        lastDataReceived = Date()
    }
    
    private func isKnownSerialService(_ uuid: CBUUID) -> SerialService? {
        return knownSerialServices.first { service in
            uuid.uuidString.lowercased() == service.uuid.lowercased()
        }
    }
    
    private func isExcludedService(_ uuid: CBUUID) -> Bool {
        return excludedServices.contains(uuid.uuidString.lowercased())
    }
    
    private func isWriteCharacteristic(_ characteristic: CBCharacteristic) -> Bool {
        return characteristic.properties.contains(.write) ||
               characteristic.properties.contains(.writeWithoutResponse)
    }
    
    private func isReadCharacteristic(_ characteristic: CBCharacteristic) -> Bool {
        return characteristic.properties.contains(.notify) ||
               characteristic.properties.contains(.indicate)
    }

    @objc public func bleLog(_ message: String) {
        logInfo("[C] \(message)")
    }

    @objc public func close() {
        close(clearDevicePtr: false)
    }
}

// MARK: - Extensions
extension Data {
    func hexEncodedString() -> String {
        return map { String(format: "%02hhx", $0) }.joined()
    }
}
