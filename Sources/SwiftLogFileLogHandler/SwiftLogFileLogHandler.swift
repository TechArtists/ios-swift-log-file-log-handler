// The Swift Programming Language
// https://docs.swift.org/swift-book


import Logging
import Foundation
import ZIPFoundation

public struct SwiftLogFileLogHandler: LogHandler {
    private var fileLoggerManager: AutoRotatingFileManager
    private var label: String
    
    public var logLevel: Logger.Level = .debug

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
    
    public func getArchiveURL(asZip: Bool = false, zipFileName: String = "combined_archive.zip") -> URL? {
        if asZip {
            guard let combinedArchiveURL = fileLoggerManager.combineArchivedLogFiles() else {
                logger.error("Failed to combine archived log files.")
                return nil
            }
            
            let fileManager = FileManager.default
            
            let destinationFileURL = AutoRotatingFileManager.defaultLogFolderURL.appendingPathComponent(zipFileName)
            
            do {
                if fileManager.fileExists(atPath: destinationFileURL.path) {
                    try fileManager.removeItem(at: destinationFileURL)
                }
                
                try fileManager.zipItem(
                    at: combinedArchiveURL,
                    to: destinationFileURL,
                    compressionMethod: .deflate
                )
                
                return destinationFileURL
            } catch {
                logger.error("Failed to create ZIP file: \(error.localizedDescription)")
                return nil
            }
        } else {
            return fileLoggerManager.combineArchivedLogFiles()
        }
    }
}
