// The Swift Programming Language
// https://docs.swift.org/swift-book


import Logging
import Foundation

/// `XCGLoggerHandler` is an implementation of `LogHandler` that makes use of the XCGLogger.
public struct SwiftLogFileLogHandler: LogHandler {
    private var fileLoggerManager: AutoRotatingFileManager
    private var label: String
    
    public var logLevel: Logger.Level = .info

    public var metadata = Logger.Metadata()

    public subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get {
            return self.metadata[metadataKey]
        }
        set {
            self.metadata[metadataKey] = newValue
        }
    }

    public init(label: String) {
        self.label = label
        self.fileLoggerManager = AutoRotatingFileManager()
    }
    
    public func log(level: Logger.Level,
                    message: Logger.Message,
                    metadata: Logger.Metadata?,
                    source: String,
                    file: String = #file,
                    function: String = #function,
                    line: UInt = #line) {
        fileLoggerManager.logToFile("\(message)")
    }
    
    public func getArchiveURL() -> URL? {
        fileLoggerManager.combineArchivedLogFiles()
    }
    
    public func clearArchivedLogFiles() {
        fileLoggerManager.clearCombinedArchive()
    }
}
