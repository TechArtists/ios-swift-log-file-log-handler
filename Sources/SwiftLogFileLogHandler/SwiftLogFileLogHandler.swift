// The Swift Programming Language
// https://docs.swift.org/swift-book


import Logging
import Foundation

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

    public init(label: String, fileLoggerManager: AutoRotatingFileManager = .init()) {
        self.label = label
        self.fileLoggerManager = fileLoggerManager
    }
    
    public func log(level: Logger.Level,
                    message: Logger.Message,
                    metadata: Logger.Metadata?,
                    source: String,
                    file: String = #file,
                    function: String = #function,
                    line: UInt = #line) {
        
        let effectiveMetadata = SwiftLogFileLogHandler.prepareMetadata(
            base: self.metadata,
            provider: self.metadataProvider,
            explicit: metadata
        )

        let prettyMetadata: String?
        if let effectiveMetadata = effectiveMetadata {
            prettyMetadata = self.prettify(effectiveMetadata)
        } else {
            prettyMetadata = nil
        }
        
        fileLoggerManager.logToFile(
            "\(self.timestamp()) \(level) \(self.label) :\(prettyMetadata.map { " \($0)" } ?? "") [\(source)] \(message)\n"
        )
    }
    
    public func getCombinedStashedLogFilesURL() -> URL? {
        fileLoggerManager.combineStashedLogFiles()
    }
    
    public func getCurrentLogFileURL() -> URL? {
        fileLoggerManager.currentLogFileURL
    }
    
    public func getCurrentStashedCount() -> Int {
        fileLoggerManager.stashedLogFileURLs().count
    }
    
    // MARK: Private Functions
    
    private static func prepareMetadata(
        base: Logger.Metadata,
        provider: Logger.MetadataProvider?,
        explicit: Logger.Metadata?
    ) -> Logger.Metadata? {
        var metadata = base

        let provided = provider?.get() ?? [:]

        guard !provided.isEmpty || !((explicit ?? [:]).isEmpty) else {
            // all per-log-statement values are empty
            return nil
        }

        if !provided.isEmpty {
            metadata.merge(provided, uniquingKeysWith: { _, provided in provided })
        }

        if let explicit = explicit, !explicit.isEmpty {
            metadata.merge(explicit, uniquingKeysWith: { _, explicit in explicit })
        }

        return metadata
    }

    private func prettify(_ metadata: Logger.Metadata) -> String? {
        if metadata.isEmpty {
            return nil
        } else {
            return metadata.lazy.sorted(by: { $0.key < $1.key }).map { "\($0)=\($1)" }.joined(separator: " ")
        }
    }
    
    private func timestamp() -> String {
        var buffer = [Int8](repeating: 0, count: 255)

        var timestamp = time(nil)
        guard let localTime = localtime(&timestamp) else {
            return "<unknown>"
        }
        strftime(&buffer, buffer.count, "%Y-%m-%dT%H:%M:%S%z", localTime)

        return buffer.withUnsafeBufferPointer {
            $0.withMemoryRebound(to: CChar.self) {
                String(cString: $0.baseAddress!)
            }
        }
    }
}
