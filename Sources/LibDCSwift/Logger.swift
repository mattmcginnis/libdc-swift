import Foundation

public enum LogLevel: Int {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
    
    public var prefix: String {
        switch self {
        case .debug: return "🔍 DEBUG"
        case .info: return "ℹ️ INFO"
        case .warning: return "⚠️ WARN"
        case .error: return "❌ ERROR"
        }
    }
}

public class Logger {
    public static let shared = Logger()
    private var isEnabled = true
    private var minLevel: LogLevel = .debug
    public var shouldShowRawData = false  // Toggle for full hex dumps
    private var dataCounter = 0  // Track number of data packets
    private var totalBytesReceived = 0  // Track total bytes
    
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    
    public var minimumLogLevel: LogLevel {
        get { minLevel }
        set { minLevel = newValue }
    }
    
    public func setMinLevel(_ level: LogLevel) {
        minLevel = level
    }
    
    /// Optional external handler — set by the host app to capture log lines.
    public var logHandler: ((String) -> Void)?

    private init() {
        isEnabled = true
        minLevel = .debug
    }

    public func log(_ message: String, level: LogLevel = .debug, file: String = #file, function: String = #function) {
        let timestamp = dateFormatter.string(from: Date())
        let fileName = (file as NSString).lastPathComponent
        let line = "\(level.prefix) [\(timestamp)] [\(fileName)] \(message)"
        print(line)
        logHandler?(line)
    }
    
    private func handleBLEDataLog(_ message: String, _ timestamp: String) {
        dataCounter += 1
        
        // Extract byte count from message
        if let bytesStart = message.range(of: "("),
           let bytesEnd = message.range(of: " bytes)") {
            let bytesStr = message[bytesStart.upperBound..<bytesEnd.lowerBound]
            if let bytes = Int(bytesStr) {
                totalBytesReceived += bytes
                
                // Only print summary at the end or for significant events
                if message.contains("completed") || message.contains("error") {
                    print("📱 [\(timestamp)] BLE: Total received: \(totalBytesReceived) bytes in \(dataCounter) packets")
                }
            }
        }
    }
    
    private func formatHexData(_ hexString: String) -> String {
        // Format hex data in chunks of 8 bytes (16 characters)
        var formatted = ""
        var index = hexString.startIndex
        let chunkSize = 16
        
        while index < hexString.endIndex {
            let endIndex = hexString.index(index, offsetBy: chunkSize, limitedBy: hexString.endIndex) ?? hexString.endIndex
            let chunk = hexString[index..<endIndex]
            formatted += chunk
            if endIndex != hexString.endIndex {
                formatted += "\n\t\t\t"  // Indent continuation lines
            }
            index = endIndex
        }
        
        return formatted
    }
    
    public func setShowRawData(_ show: Bool) {
        shouldShowRawData = show
    }
    
    public func resetDataCounters() {
        dataCounter = 0
        totalBytesReceived = 0
    }

}

// Global convenience functions
public func logDebug(_ message: String, file: String = #file, function: String = #function) {
    Logger.shared.log(message, level: .debug, file: file, function: function)
}

public func logInfo(_ message: String, file: String = #file, function: String = #function) {
    Logger.shared.log(message, level: .info, file: file, function: function)
}

public func logWarning(_ message: String, file: String = #file, function: String = #function) {
    Logger.shared.log(message, level: .warning, file: file, function: function)
}

public func logError(_ message: String, file: String = #file, function: String = #function) {
    Logger.shared.log(message, level: .error, file: file, function: function)
} 