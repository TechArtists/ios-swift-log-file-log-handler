/*
MIT License

Copyright (c) 2025 Tech Artists Agency

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

//
//  AutoRotatingFileManager.swift
//  SwiftLogFileLogHandler
//
//  Created by Robert Tataru on 04.10.2024.
//

import Foundation
import Compression
import Logging

public final class AutoRotatingFileManager: @unchecked Sendable {
    
    // MARK: - Constants
    public static let autoRotatingFileDefaultMaxFileSize: UInt64 = 1_048_576
    public static let autoRotatingFileDefaultMaxTimeInterval: TimeInterval = 600
    
    // MARK: - Properties
    
    /// File handle for the log file
    private var logFileHandle: FileHandle? = nil
    
    /// URL of the combined stashed log files into one file
    private var combinedStashedLogFilesURL: URL? = nil
    
    /// FileURL of the file to log to
    internal var currentLogFileURL: URL? = nil {
        didSet {
            openFile()
        }
    }
    
    /// Option: desired maximum size of a log file, if 0, no maximum (log files may exceed this, it's a guideline only)
    internal var maxLogFileSize: UInt64 {
        didSet {
            if maxLogFileSize < 1 {
                maxLogFileSize = .max
            }
        }
    }
    
    /// Option: the desired number of stashed log files to keep (number of log files may exceed this, it's a guideline only)
    internal var maxLogFilesCount: UInt64 {
        didSet {
            cleanUpOldLogFiles()
        }
    }
    
    /// Option: the URL of the folder to store rotated log files (defaults to the same folder as the initial log file)
    internal var stashedLogsFolderURL: URL? = nil {
        didSet {
            guard let stashedLogsFolderURL = stashedLogsFolderURL else { return }
            try? FileManager.default.createDirectory(at: stashedLogsFolderURL, withIntermediateDirectories: true)
        }
    }
    
    private var fileManagerQueue = DispatchQueue(label: "com.tech-artists.AutoRotatingFileManager.queue")
    
    /// A custom date formatter object to use as the suffix of rotated log files
    private var _customStashedSuffixDateFormatter: DateFormatter?
    
    /// The date formatter object to use as the suffix of stored log files
    internal var stashedSuffixDateFormatter: DateFormatter {
        get {
            _customStashedSuffixDateFormatter ?? {
                let formatter = DateFormatter()
                formatter.locale = .current
                formatter.dateFormat = "_yyyy-MM-dd_HHmmss"
                return formatter
            }()
        }
        set {
            _customStashedSuffixDateFormatter = newValue
        }
    }
    
    /// Size of the current log file
    internal var currentLogFileSize: UInt64 = 0
    
    /// The base file name of the log file
    internal var baseFileName: String = "ta-file-logger"
    
    /// The extension of the log file name
    internal var fileExtension: String = "log"
    
    /// A default folder for storing stashed logs if one isn't supplied
    internal static var defaultLogFolderURL: URL {
        let defaultDirectory: URL

        #if os(OSX)
            defaultDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
        #elseif os(iOS) || os(tvOS) || os(watchOS)
            defaultDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        #else
            fatalError("Unsupported platform")
        #endif

        let defaultLogFolderURL = defaultDirectory.appendingPathComponent("log")
        try? FileManager.default.createDirectory(at: defaultLogFolderURL, withIntermediateDirectories: true)
        return defaultLogFolderURL
    }
    
    // MARK: - Life Cycle
    public init(
        maxLogFileSize: UInt64 = autoRotatingFileDefaultMaxFileSize,
        maxLogFilesCount: UInt64 = 10
    ) {
        self.maxLogFileSize = maxLogFileSize < 1 ? .max : maxLogFileSize
        self.maxLogFilesCount = maxLogFilesCount
        self.currentLogFileURL = Self.defaultLogFolderURL.appendingPathComponent("\(baseFileName).\(fileExtension)")
        self.stashedLogsFolderURL = determineStashedLogsFolderURL(currentLogFileURL)
        self.openFile()
        
        guard let filePath = currentLogFileURL?.path else { return }

        self.currentLogFileSize = fetchCurrentLogFileSize(filePath: filePath)
        
        if shouldRotateCurrentLogFile() {
            rotateCurrentLogFile()
        }
    }
    
    deinit {
        closeFile()
    }

    // MARK: - Helper Init Methods

    private func determineStashedLogsFolderURL(_ logFileURL: URL?) -> URL? {
        guard let filePath = logFileURL?.path else { return Self.defaultLogFolderURL }
        let logFileName = "\(baseFileName).\(fileExtension)"

        if let logFileNameRange = filePath.range(of: logFileName, options: .backwards),
           logFileNameRange.upperBound >= filePath.endIndex {
            let stashedFolderPath = String(filePath[filePath.startIndex ..< logFileNameRange.lowerBound])
            return URL(fileURLWithPath: stashedFolderPath)
        }
        return Self.defaultLogFolderURL
    }

    private func fetchCurrentLogFileSize(filePath: String) -> UInt64 {
        do {
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: filePath)
            return fileAttributes[.size] as? UInt64 ?? 0
        } catch {
            TALogger.main.error("Error fetching curren log file size \(error.localizedDescription)")
            return 0
        }
    }
    
    // MARK: - Public Methods
    
    public func logToFile(_ message: String) {
        fileManagerQueue.async {
            self.write(message: message)
        }
    }
    
    public func getCurrentLogFileURL() -> URL? {
        currentLogFileURL
    }
    
    public func getCurrentLogsCount() -> Int {
        let stashedLogsFolderURL: URL = self.stashedLogsFolderURL ?? Self.defaultLogFolderURL

        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: stashedLogsFolderURL,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        let sortedLogFileURLs = fileURLs
            .filter { $0.pathExtension == "log" }

        return sortedLogFileURLs.count
    }
    
    /// Combines all stashed log files into a single file and optionally compresses the file using Apple’s Compression library.
    /// - Parameters:
    ///   - includeCurrentLogFile: If true, also includes the current log file.
    ///   - compress: If true, compresses the combined log file using the Compression framework.
    /// - Returns: The URL of the combined (or compressed) log file, or `nil` if the operation fails.
    public func combineStashedLogFiles(includeCurrentLogFile: Bool = false, archive: Bool = false) -> URL? {
        let combinedFileName = "\(baseFileName)_combined_stashed.\(fileExtension)"
        let combinedFileURL = Self.defaultLogFolderURL.appendingPathComponent(combinedFileName)
        
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: combinedFileURL.path) {
            try? fileManager.removeItem(at: combinedFileURL)
        }
        
        var stashedLogFileURLs = Array(stashedLogFileURLs().reversed())
        
        if let currentLogFileURL, includeCurrentLogFile {
            stashedLogFileURLs.append(currentLogFileURL)
        }
        
        guard !stashedLogFileURLs.isEmpty else {
            return nil
        }
        
        do {
            for fileURL in stashedLogFileURLs {
                let fileContents = try String(contentsOf: fileURL)
                try fileContents.appendLine(to: combinedFileURL)
            }
        } catch {
            TALogger.main.error("Error combining stashed log files: \(error.localizedDescription)")
            return nil
        }
        
        combinedStashedLogFilesURL = combinedFileURL
        
        if archive {
            let zipFileName = "\(baseFileName)_archived.zip"
            let zipFileURL = Self.defaultLogFolderURL.appendingPathComponent(zipFileName)
            
            if fileManager.fileExists(atPath: zipFileURL.path) {
                try? fileManager.removeItem(at: zipFileURL)
            }

            do {
                let zipArchiveURL = try ZipUtility.createZipArchive(from: combinedFileURL, to: zipFileURL)
                return zipArchiveURL
            } catch {
                TALogger.main.error("Failed to create ZIP archive. \(error.localizedDescription) ")
            }
        }
        
        return combinedFileURL
    }

    /// Clears the combined stashed file from memory.
    public func clearCombinedStashedLogsFile() {
        guard let combinedStashedLogFilesURL = combinedStashedLogFilesURL else { return }
        
        let fileManager = FileManager.default
        
        do {
            try fileManager.removeItem(at: combinedStashedLogFilesURL)
        } catch {
            TALogger.main.error("Error clearing combined stashed: \(error.localizedDescription)")
        }
        
        self.combinedStashedLogFilesURL = nil
    }
    
    /// Purge all stashed log files (include the current one if specified
    /// - Parameters:
    ///   - includeCurrentLogFile: If true, also includes the current log file.
    public func purgeLogFiles(includeCurrentLogFile: Bool = false) {
        let fileManager: FileManager = FileManager.default
        
        var stashedLogFileURLs = stashedLogFileURLs()
        
        defer {
            if includeCurrentLogFile {
                self.currentLogFileURL = Self.defaultLogFolderURL.appendingPathComponent("\(baseFileName).\(fileExtension)")
            }
        }
        
        if includeCurrentLogFile, let currentLogFileURL {
            stashedLogFileURLs.append(currentLogFileURL)
        }
        
        for stashedLogFileURL in stashedLogFileURLs {
            do {
                try fileManager.removeItem(at: stashedLogFileURL)
            }
            catch {
                TALogger.main.error("Unable to delete old stashed log file \(stashedLogFileURL.path): \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Internal Methods
    
    /// Write the log to the log file.
    ///
    /// - Parameters:
    ///     - message:   Formatted/processed message ready for output.
    ///
    /// - Returns:  Nothing
    ///
    internal func write(message: String) {
        currentLogFileSize += UInt64(message.data(using: .utf8)?.count ?? 0)

        if let encodedData = "\(message)".data(using: String.Encoding.utf8) {
            do {
                try logFileHandle?.seekToEnd()
                try logFileHandle?.write(contentsOf: encodedData)
            } catch {
                TALogger.main.error("Error writing to log file: \(error.localizedDescription)")
            }
        }

        if shouldRotateCurrentLogFile() {
            rotateCurrentLogFile()
        }
    }
    
    /// Get the URLs of the stashed log files.
    ///
    /// - Parameters:   None.
    ///
    /// - Returns:      An array of file URLs pointing to previously stashed log files, sorted with the most recent logs first.
    ///
    internal func stashedLogFileURLs() -> [URL] {
        // Determine the stashed folder URL
        let stashedLogsFolderURL: URL = self.stashedLogsFolderURL ?? Self.defaultLogFolderURL

        // Retrieve file URLs in the stashed folder, or return an empty array if failed
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: stashedLogsFolderURL,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        // Filter for .log files, remove the current log file, and sort by creation date
        let sortedLogFileURLs = fileURLs
            .filter { $0.pathExtension == "log" && $0.lastPathComponent != currentLogFileURL?.lastPathComponent }
            .compactMap { fileURL -> (url: URL, creationDate: Date)? in
                let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                guard let creationDate = attributes?[.creationDate] as? Date else { return nil }
                return (url: fileURL, creationDate: creationDate)
            }
            .sorted { $0.creationDate > $1.creationDate } // Sort by creation date, most recent first

        return sortedLogFileURLs.map { $0.url }
    }
    
    /// Rotate the current log file.
    internal func rotateCurrentLogFile() {
        var stashedLogsFolderURL: URL = (self.stashedLogsFolderURL ?? Self.defaultLogFolderURL)
        
        stashedLogsFolderURL = stashedLogsFolderURL.appendingPathComponent("\(baseFileName)\(stashedSuffixDateFormatter.string(from: Date()))")
        stashedLogsFolderURL = stashedLogsFolderURL.appendingPathExtension(fileExtension)
        
        rotateFile(to: stashedLogsFolderURL)

        currentLogFileSize = 0

        cleanUpOldLogFiles()
    }
    
    /// Scan the log folder and delete log files that are no longer relevant.
    internal func cleanUpOldLogFiles() {
        var stashedLogFileURLs: [URL] = self.stashedLogFileURLs()
        
        guard stashedLogFileURLs.count > Int(maxLogFilesCount) else { return }

        stashedLogFileURLs.removeFirst(Int(maxLogFilesCount))

        let fileManager: FileManager = FileManager.default
        for stashedLogFileURL in stashedLogFileURLs {
            do {
                try fileManager.removeItem(at: stashedLogFileURL)
            }
            catch {
                TALogger.main.error("Unable to delete old stashed log file \(stashedLogFileURL.path): \(error.localizedDescription)")
            }
        }
    }
    
    /// Determine if the log file should be rotated.
    /// - Returns:
    ///     - If the log file should be rotated.
    ///
    internal func shouldRotateCurrentLogFile() -> Bool {
        // Do not rotate until critical setup has been completed so that we do not accidentally rotate once to the defaultLogFolderURL before determining the desired log location
        guard let _ = stashedLogsFolderURL else { return false }
        
        guard currentLogFileSize < maxLogFileSize else { return true }

        return false
    }
    
    internal func openFile() {
        guard let currentLogFileURL = currentLogFileURL else { return }

        if logFileHandle != nil {
            closeFile()
        }

        let fileManager = FileManager.default
        let fileExists = fileManager.fileExists(atPath: currentLogFileURL.path)

        if !fileExists {
            fileManager.createFile(atPath: currentLogFileURL.path, contents: nil, attributes: nil)
        }

        do {
            logFileHandle = try FileHandle(forWritingTo: currentLogFileURL)

            if fileExists {
                let appendMarker = "-- ** ** ** --"
                write(message: "\(appendMarker)")
            }
        } catch {
            TALogger.main.error("Attempt to open log file failed: \(error.localizedDescription)")
            logFileHandle = nil
            return
        }

        logOpeningDetails(fileExists: fileExists)
    }

    internal func logOpeningDetails(fileExists: Bool) {
        guard let currentLogFileURL = currentLogFileURL else { return }
        
        TALogger.main.info("SwiftLogFileLogHandler opened log file at: \(currentLogFileURL.absoluteString)")
    }
    
    @discardableResult
    internal func rotateFile(to stashToFile: Any) -> Bool {
        guard let stashToFileURL = resolveAnyFileToUrl(from: stashToFile) else { return false }

        guard let currentLogFileURL = currentLogFileURL else { return false }

        let fileManager = FileManager.default

        guard !fileManager.fileExists(atPath: stashToFileURL.path) else { return false }

        closeFile()

        do {
            try fileManager.moveItem(atPath: currentLogFileURL.path, toPath: stashToFileURL.path)
        } catch {
            openFile()
            TALogger.main.error("Unable to rotate file \(currentLogFileURL.path) to \(stashToFileURL.path): \(error.localizedDescription)")
            return false
        }

        TALogger.main.info("Rotated file \(currentLogFileURL.path) to \(stashToFileURL.path)")
        openFile()
        
        return true
    }
    
    // MARK: - Private Methods
    
    private func closeFile() {
        logFileHandle?.synchronizeFile()
        logFileHandle?.closeFile()
        logFileHandle = nil
    }
    
    private func resolveAnyFileToUrl(from logFile: Any) -> URL? {
        if let filePath = logFile as? String {
            return URL(fileURLWithPath: filePath)
        } else if let fileURL = logFile as? URL, fileURL.isFileURL {
            return fileURL
        } else {
            return nil
        }
    }
}
