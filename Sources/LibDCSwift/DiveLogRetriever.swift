import Foundation
import CoreBluetooth
import Clibdivecomputer
import LibDCBridge
#if canImport(UIKit)
import UIKit
#endif

public class DiveLogRetriever {
    public class CallbackContext {
        var logCount: Int = 1
        let viewModel: DiveDataViewModel
        var lastFingerprint: Data?
        let deviceName: String
        let deviceUUID: String
        var deviceSerial: String?
        var deviceTypeFromLibDC: String?  // Exact device type string from libdivecomputer
        var hasNewDives: Bool = false
        weak var bluetoothManager: CoreBluetoothManager?
        var devicePtr: UnsafeMutablePointer<device_data_t>?
        var hasDeviceInfo: Bool = false
        var storedFingerprint: Data?
        var isCompleted: Bool = false
        var fingerprintMatched: Bool = false  // Track if we stopped due to fingerprint match
        
        var detectedFamily: dc_family_t = DC_FAMILY_NULL
        var detectedModel: UInt32 = 0
        
        init(viewModel: DiveDataViewModel, deviceName: String, deviceUUID: String, storedFingerprint: Data?, bluetoothManager: CoreBluetoothManager) {
            self.viewModel = viewModel
            self.deviceName = deviceName
            self.deviceUUID = deviceUUID
            self.storedFingerprint = storedFingerprint
            self.bluetoothManager = bluetoothManager
        }
    }

    private static let diveCallbackClosure: @convention(c) (
        UnsafePointer<UInt8>?,
        UInt32,
        UnsafePointer<UInt8>?,
        UInt32,
        UnsafeMutableRawPointer?
    ) -> Int32 = { data, size, fingerprint, fsize, userdata in
        guard let data = data,
              let userdata = userdata,
              let fingerprint = fingerprint else {
            return 0
        }
        
        let context = Unmanaged<CallbackContext>.fromOpaque(userdata).takeUnretainedValue()
        
        if context.bluetoothManager?.isRetrievingLogs == false {
            logInfo("🛑 Download cancelled")
            return 0
        }
        
        // 1. Capture Device Info (Once)
        if !context.hasDeviceInfo,
           let devicePtr = context.devicePtr,
           devicePtr.pointee.have_devinfo != 0 {
            context.deviceSerial = String(format: "%08x", devicePtr.pointee.devinfo.serial)
            context.detectedModel = devicePtr.pointee.devinfo.model
            
            // Capture the exact device type string from libdivecomputer
            if let modelCStr = devicePtr.pointee.model {
                context.deviceTypeFromLibDC = String(cString: modelCStr)
            }
            
            if let desc = devicePtr.pointee.descriptor {
                context.detectedFamily = dc_descriptor_get_type(desc)
            }

            // Update stored device with serial for fingerprint cleanup when forgetting
            if let serial = context.deviceSerial {
                DeviceStorage.shared.updateDeviceSerial(uuid: context.deviceUUID, serial: serial)
            }

            // Now that we have device info, load the stored fingerprint if we don't have it yet
            if context.storedFingerprint == nil,
               let deviceType = context.deviceTypeFromLibDC,
               let serial = context.deviceSerial {
                context.storedFingerprint = context.viewModel.getFingerprint(forDeviceType: deviceType, serial: serial)
            }

            // Update storage if hardware tells us something different (e.g. 13 vs 9)
            DeviceConfiguration.updateDeviceConfigurationFromHardware(
                deviceAddress: context.deviceUUID,
                deviceDataPtr: devicePtr,
                deviceName: context.deviceName
            )
            
            context.hasDeviceInfo = true
        }
        
        let fingerprintData = Data(bytes: fingerprint, count: Int(fsize))

        // Capture the FIRST dive's fingerprint (most recent dive on the device)
        // This is what we'll compare against on the next download
        if context.logCount == 1 {
            context.lastFingerprint = fingerprintData
        }
        
        // Check if this dive matches our stored fingerprint (already downloaded)
        if let storedFingerprint = context.storedFingerprint {
            if storedFingerprint == fingerprintData {
                logInfo("✨ Found matching fingerprint - all new dives downloaded")
                context.fingerprintMatched = true
                return 0  // Stop enumeration - we've reached already-downloaded dives
            }
        }
        
        // 4. Parse & Store Dive
        var familyToUse: dc_family_t
        var modelToUse: UInt32
        
        // PRIORITY ORDER FOR MODEL SELECTION:
        // 1. Hardware Detection (Most reliable if available)
        // 2. Stored/Forced Configuration (What the user selected)
        // 3. Name-based Detection (Fallback)
        
        if context.detectedModel != 0 {
            familyToUse = context.detectedFamily
            modelToUse = context.detectedModel
        } else if let stored = DeviceStorage.shared.getStoredDevice(uuid: context.deviceUUID) {
            familyToUse = stored.family.asDCFamily
            modelToUse = stored.model
        } else if let deviceInfo = DeviceConfiguration.fromName(context.deviceName) {
            familyToUse = deviceInfo.family.asDCFamily
            modelToUse = deviceInfo.model
        } else {
            logError("❌ Unknown device configuration")
            return 0
        }

        guard let deviceFamily = DeviceConfiguration.DeviceFamily(dcFamily: familyToUse) else {
            logError("❌ Failed to map C family ID \(familyToUse) to Swift DeviceFamily enum")
            return 0
        }

        do {
            let diveData = try GenericParser.parseDiveData(
                family: deviceFamily,
                model: modelToUse, 
                diveNumber: context.logCount,
                diveData: data,
                dataSize: Int(size)
            )
            
            // IMPORTANT: appendDives() and updateProgress() each internally do a
            // DispatchQueue.main.async, so just call them directly from the retrieval
            // thread. The previous wrapper here caused a double-dispatch: this outer
            // block ran on main, which enqueued ANOTHER main block for the actual
            // append — and meanwhile the completion handler (also a single main.async)
            // ran BEFORE those nested appends executed. Result: completion read an
            // empty `viewModel.dives`, reported "0 dives imported" to the UI, and
            // nothing got saved to WatermelonDB even though the download succeeded.
            context.viewModel.appendDives([diveData])
            context.viewModel.updateProgress(count: context.logCount)

            context.hasNewDives = true
            context.logCount += 1
            return 1
        } catch {
            logError("❌ Failed to parse dive #\(context.logCount): \(error)")
            return 1 
        }
    }
    
    #if os(iOS)
    private static var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif
    
    private static let fingerprintLookup: @convention(c) (
        UnsafeMutableRawPointer?, 
        UnsafePointer<CChar>?, 
        UnsafePointer<CChar>?, 
        UnsafeMutablePointer<Int>?
    ) -> UnsafeMutablePointer<UInt8>? = { context, deviceType, serial, size in
        guard let context = context, let size = size else {
            logWarning("⚠️ Fingerprint lookup called with nil context or size")
            return nil
        }
        
        let viewModel = Unmanaged<DiveDataViewModel>.fromOpaque(context).takeUnretainedValue()
        
        if let serialStr = serial.map({ String(cString: $0) }),
           let typeStr = deviceType.map({ String(cString: $0) }) {
             
             if let fingerprint = viewModel.getFingerprint(forDeviceType: typeStr, serial: serialStr) {
                // Sanity check: Shearwater fingerprints should be exactly 4 bytes
                if fingerprint.count != 4 {
                    logWarning("⚠️ Fingerprint size mismatch! Expected 4 bytes, got \(fingerprint.count)")
                }

                size.pointee = fingerprint.count
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: fingerprint.count)
                fingerprint.copyBytes(to: buffer, count: fingerprint.count)
                return buffer
            } else {
                // No stored fingerprint - return a sentinel value (0xFFFFFFFF) that won't match any real dive
                // This is necessary because libdivecomputer defaults to 0x00000000 if no fingerprint is set,
                // which could accidentally match a dive with fingerprint 0x00000000 and stop enumeration
                let sentinelFingerprint: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF]
                size.pointee = sentinelFingerprint.count
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: sentinelFingerprint.count)
                buffer.initialize(from: sentinelFingerprint, count: sentinelFingerprint.count)
                return buffer
            }
        } else {
            logWarning("⚠️ Fingerprint lookup called with nil device type or serial")
        }
        return nil
    }
    
    private static var currentContext: CallbackContext?
    
    public static func retrieveDiveLogs(
            from devicePtr: UnsafeMutablePointer<device_data_t>,
            device: CBPeripheral,
            viewModel: DiveDataViewModel,
            bluetoothManager: CoreBluetoothManager,
            onProgress: ((Int, Int) -> Void)? = nil,
            completion: @escaping (Bool) -> Void
        ) {
            let retrievalQueue = DispatchQueue(label: "com.libdcswift.retrieval", qos: .userInitiated)
            
            retrievalQueue.async {
                DispatchQueue.main.async { viewModel.resetProgress() }
                
                guard let dcDevice = devicePtr.pointee.device else {
                    DispatchQueue.main.async {
                        viewModel.setDetailedError("No device connection found", status: DC_STATUS_IO)
                        completion(false)
                    }
                    return
                }

                let deviceName = device.name ?? "Unknown Device"

                // Pre-lookup using the same key format as the save path (libdc's own model
                // string, via devicePtr.pointee.model). Only works if device_open already
                // populated have_devinfo — on a fresh open it usually hasn't, in which case
                // the diveCallbackClosure does the lookup once have_devinfo flips to 1.
                var storedFingerprint: Data? = nil
                if devicePtr.pointee.have_devinfo != 0 {
                    let serial = String(format: "%08x", devicePtr.pointee.devinfo.serial)
                    DeviceStorage.shared.updateDeviceSerial(uuid: device.identifier.uuidString, serial: serial)
                    let deviceType: String
                    if let modelCStr = devicePtr.pointee.model {
                        deviceType = String(cString: modelCStr)
                    } else {
                        deviceType = deviceName
                    }
                    storedFingerprint = viewModel.getFingerprint(forDeviceType: deviceType, serial: serial)
                    logInfo("🔎 Pre-lookup fingerprint key='\(deviceType)' serial=\(serial) found=\(storedFingerprint != nil)")
                }

                let context = CallbackContext(
                    viewModel: viewModel,
                    deviceName: deviceName,
                    deviceUUID: device.identifier.uuidString,
                    storedFingerprint: storedFingerprint,
                    bluetoothManager: bluetoothManager
                )
                context.devicePtr = devicePtr
                
                let contextPtr = UnsafeMutableRawPointer(Unmanaged.passRetained(context).toOpaque())
                
                // Progress timer MUST run on a queue that isn't blocked by the main transfer.
                // The retrieval queue is synchronously occupied by dc_device_foreach for the
                // whole download, so scheduling the timer on it silently drops every tick.
                // A Timer.scheduledTimer on a DispatchQueue worker also fails (no RunLoop).
                // DispatchSourceTimer on .global() is the one combination that actually fires.
                let progressQueue = DispatchQueue.global(qos: .utility)
                let progressTimer = DispatchSource.makeTimerSource(queue: progressQueue)
                progressTimer.schedule(deadline: .now() + 0.2, repeating: 0.2)
                progressTimer.setEventHandler {
                    if devicePtr.pointee.have_progress != 0 {
                        let cur = Int(devicePtr.pointee.progress.current)
                        let max = Int(devicePtr.pointee.progress.maximum)
                        onProgress?(cur, max)
                    }
                }
                progressTimer.resume()
                
                devicePtr.pointee.fingerprint_context = Unmanaged.passUnretained(viewModel).toOpaque()
                devicePtr.pointee.lookup_fingerprint = fingerprintLookup
                
                let enumStatus = dc_device_foreach(dcDevice, diveCallbackClosure, contextPtr)

                // Log errors for debugging
                if enumStatus != DC_STATUS_SUCCESS && enumStatus != DC_STATUS_PROTOCOL {
                    let errorName: String
                    switch enumStatus {
                    case DC_STATUS_UNSUPPORTED: errorName = "UNSUPPORTED"
                    case DC_STATUS_INVALIDARGS: errorName = "INVALIDARGS"
                    case DC_STATUS_NOMEMORY: errorName = "NOMEMORY"
                    case DC_STATUS_NODEVICE: errorName = "NODEVICE"
                    case DC_STATUS_NOACCESS: errorName = "NOACCESS"
                    case DC_STATUS_IO: errorName = "IO"
                    case DC_STATUS_TIMEOUT: errorName = "TIMEOUT"
                    case DC_STATUS_DATAFORMAT: errorName = "DATAFORMAT"
                    case DC_STATUS_CANCELLED: errorName = "CANCELLED"
                    default: errorName = "UNKNOWN(\(enumStatus))"
                    }
                    logError("❌ Download failed: DC_STATUS_\(errorName)")
                }

                progressTimer.cancel()

                DispatchQueue.main.async {
                    // Determine the outcome of the download
                    let downloadSucceeded: Bool
                    let shouldSaveFingerprint: Bool
                    
                    switch enumStatus {
                    case DC_STATUS_SUCCESS:
                        // Normal successful completion
                        downloadSucceeded = true
                        shouldSaveFingerprint = context.hasNewDives
                        
                    case DC_STATUS_PROTOCOL:
                        // Protocol error - could be genuine error OR early termination from callback
                        if context.fingerprintMatched {
                            // We stopped because we found matching fingerprint (no new dives)
                            downloadSucceeded = true
                            shouldSaveFingerprint = false  // Don't update fingerprint if no new dives
                        } else if context.hasNewDives {
                            // We got some dives but then hit protocol error - partial download
                            logWarning("⚠️ Protocol error after downloading \(context.logCount - 1) dive(s)")
                            downloadSucceeded = false
                            shouldSaveFingerprint = false  // Don't save partial download fingerprint
                        } else if context.storedFingerprint != nil {
                            // Protocol error with fingerprint but no dives downloaded
                            downloadSucceeded = true
                            shouldSaveFingerprint = false
                        } else {
                            // Protocol error before getting any dives - genuine error
                            logError("❌ Protocol error before downloading any dives")
                            downloadSucceeded = false
                            shouldSaveFingerprint = false
                        }
                        
                    default:
                        // Any other error status
                        downloadSucceeded = false
                        shouldSaveFingerprint = false
                    }
                    
                    // Handle the outcome
                    if !downloadSucceeded {
                        viewModel.setDetailedError("Download incomplete - DC_STATUS error code: \(enumStatus)", status: enumStatus)
                        completion(false)
                    } else {
                        // Download completed successfully
                        if shouldSaveFingerprint, let lastFP = context.lastFingerprint, let serial = context.deviceSerial {
                            // Use libdc's own model string as the fingerprint key — it's the only
                            // value that is consistent between the save path here and the in-callback
                            // lookup path (diveCallbackClosure). The prior implementation saved with
                            // modelInfo.name (e.g. "Aqualung i300C") but the callback looked up with
                            // deviceTypeFromLibDC (e.g. "i300C"), so the fingerprint was never found
                            // on subsequent connects and every download re-read the full memory.
                            let deviceType = context.deviceTypeFromLibDC ?? context.deviceName
                            logInfo("✅ Download completed - \(context.logCount - 1) dive(s) downloaded, fingerprint key='\(deviceType)' serial=\(serial)")
                            viewModel.saveFingerprint(lastFP, deviceType: deviceType, serial: serial)
                            viewModel.finalizeDiveNumbering()  // Sort by date and renumber (oldest = #1)
                            viewModel.updateProgress(.completed)
                        } else if context.fingerprintMatched || (context.storedFingerprint != nil && !context.hasNewDives) {
                            logInfo("ℹ️ No new dives found")
                            viewModel.updateProgress(.noNewDives)
                        } else {
                            viewModel.finalizeDiveNumbering()  // Sort by date and renumber (oldest = #1)
                            viewModel.updateProgress(.completed)
                        }
                        completion(true)
                    }
                    
                    context.isCompleted = true
                    Unmanaged<CallbackContext>.fromOpaque(contextPtr).release()
                    
                    #if os(iOS)
                    endBackgroundTask()
                    #endif
                }
                
                currentContext = context
            }
        }
    
    #if os(iOS)
    private static func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
    #endif
    
    public static func getCurrentContext() -> CallbackContext? {
        return currentContext
    }
}
