import Foundation

class DebugLogger {
    static let shared = DebugLogger()
    private var isEnabled = true
    
    private init() {
        // Initialize with environment check
        #if DEBUG
        isEnabled = true
        #else
        isEnabled = false
        #endif
    }
    
    enum LogLevel: String {
        case debug = "📘 DEBUG"
        case info = "📗 INFO"
        case warning = "📙 WARNING"
        case error = "📕 ERROR"
        case haptic = "📳 HAPTIC"
    }
    
    func log(_ message: String, level: LogLevel = .debug, file: String = #file, function: String = #function, line: Int = #line) {
        guard isEnabled else { return }
        
        let fileName = (file as NSString).lastPathComponent
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        
        let logMessage = "\(timestamp) \(level.rawValue) [\(fileName):\(line)] \(function) - \(message)"
        
        // Print to console
        print(logMessage)
        
        // Optional: Save to file or send to logging service
        saveToFile(logMessage)
    }
    
    private func saveToFile(_ message: String) {
        // Get documents directory
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        
        let logFileURL = documentsPath.appendingPathComponent("app.log")
        
        // Append log to file
        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            handle.seekToEndOfFile()
            handle.write("\(message)\n".data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? message.write(to: logFileURL, atomically: true, encoding: .utf8)
        }
    }
}

// Extension for easy access
extension ViewController {
    func debugLog(_ message: String, level: DebugLogger.LogLevel = .debug) {
        DebugLogger.shared.log(message, level: level)
    }
}

