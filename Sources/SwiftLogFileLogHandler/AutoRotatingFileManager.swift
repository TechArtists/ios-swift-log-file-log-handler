//
//  AutoRotatingFileManager.swift
//  SwiftLogFileLogHandler
//
//  Created by Robert Tataru on 04.10.2024.
//

import Foundation
import Compression

final class AutoRotatingFileManager: @unchecked Sendable {
    
    // MARK: - Constants
    public static let autoRotatingFileDefaultMaxFileSize: UInt64 = 1_048_576
    public static let autoRotatingFileDefaultMaxTimeInterval: TimeInterval = 600
    
    // MARK: - Properties
    
    /// File handle for the log file
    private var logFileHandle: FileHandle? = nil
    
    /// URL of the combined archive file
    private var combinedArchiveFileURL: URL? = nil
    
    /// FileURL of the file to log to
    internal var currentLogFileURL: URL? = nil {
        didSet {
            openFile()
        }
    }
    
    /// Option: desired maximum size of a log file, if 0, no maximum (log files may exceed this, it's a guideline only)
    internal var targetMaxFileSize: UInt64 = autoRotatingFileDefaultMaxFileSize {
        didSet {
            if targetMaxFileSize < 1 {
                targetMaxFileSize = .max
            }
        }
    }
    
    /// Option: the desired number of archived log files to keep (number of log files may exceed this, it's a guideline only)
    internal var targetMaxLogFiles: UInt64 = 10 {
        didSet {
            cleanUpOldLogFiles()
        }
    }
    
    /// Option: the URL of the folder to store archived log files (defaults to the same folder as the initial log file)
    internal var archivedLogsFolderURL: URL? = nil {
        didSet {
            guard let archivedLogsFolderURL = archivedLogsFolderURL else { return }
            try? FileManager.default.createDirectory(at: archivedLogsFolderURL, withIntermediateDirectories: true)
        }
    }
    
    private var fileManagerQueue = DispatchQueue(label: "com.ta.AutoRotatingFileManager.queue")
    
    /// A custom date formatter object to use as the suffix of archived log files
    private var _customArchiveSuffixDateFormatter: DateFormatter?
    
    /// The date formatter object to use as the suffix of archived log files
    internal var archiveSuffixDateFormatter: DateFormatter {
        get {
            _customArchiveSuffixDateFormatter ?? {
                let formatter = DateFormatter()
                formatter.locale = .current
                formatter.dateFormat = "_yyyy-MM-dd_HHmmss"
                return formatter
            }()
        }
        set {
            _customArchiveSuffixDateFormatter = newValue
        }
    }
    
    /// Size of the current log file
    internal var currentLogFileSize: UInt64 = 0
    
    /// The base file name of the log file
    internal var baseFileName: String = "ta-file-logger"
    
    /// The extension of the log file name
    internal var fileExtension: String = "log"
    
    /// A default folder for storing archived logs if one isn't supplied
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
    init(
        currentLogFile: Any? = nil,
        logFileHandle: FileHandle? = nil,
        maxFileSize: UInt64 = autoRotatingFileDefaultMaxFileSize,
        targetMaxLogFiles: UInt64 = autoRotatingFileDefaultMaxFileSize
    ) {
        self.logFileHandle = logFileHandle
        self.targetMaxFileSize = maxFileSize < 1 ? .max : maxFileSize
        self.targetMaxLogFiles = targetMaxLogFiles
        if let currentLogFile {
            self.currentLogFileURL = resolveAnyFileToUrl(from: currentLogFile)
        } else {
            self.currentLogFileURL = Self.defaultLogFolderURL.appendingPathComponent("\(baseFileName).\(fileExtension)")
        }
        self.archivedLogsFolderURL = determineArchivedLogsFolderURL(currentLogFileURL)
        self.openFile()
        
        guard let filePath = currentLogFileURL?.path else { return }

        self.currentLogFileSize = fetchCurrentLogFileSize(filePath: filePath)
        
        if shouldRotateArchivedLogs() {
            rotateCurrentLogFile()
        }
    }
    
    deinit {
        // close file stream if open
        closeFile()
    }

    // MARK: - Helper Init Methods

    private func determineArchivedLogsFolderURL(_ logFileURL: URL?) -> URL? {
        guard let filePath = logFileURL?.path else { return Self.defaultLogFolderURL }
        let logFileName = "\(baseFileName).\(fileExtension)"

        if let logFileNameRange = filePath.range(of: logFileName, options: .backwards),
           logFileNameRange.upperBound >= filePath.endIndex {
            let archiveFolderPath = String(filePath[filePath.startIndex ..< logFileNameRange.lowerBound])
            return URL(fileURLWithPath: archiveFolderPath)
        }
        return Self.defaultLogFolderURL
    }

    private func fetchCurrentLogFileSize(filePath: String) -> UInt64 {
        do {
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: filePath)
            return fileAttributes[.size] as? UInt64 ?? 0
        } catch {
            // Handle error or log it
            return 0
        }
    }
    
    // MARK: - Public Methods
    
    public func logToFile(_ message: String) {
        fileManagerQueue.async {
            self.write(message: message)
        }
    }
    
   /// Combines all archived log files into a single file and returns its URL.
   ///
   /// - Returns: The URL of the combined archive file, or `nil` if the operation fails.
   public func combineArchivedLogFiles() -> URL? {
       let archivedLogFiles = archivedLogFileURLs()

       guard !archivedLogFiles.isEmpty else {
           return nil
       }

       let combinedFileName = "\(baseFileName)_combined_archive.\(fileExtension)"
       let combinedFileURL = Self.defaultLogFolderURL.appendingPathComponent(combinedFileName)

       let fileManager = FileManager.default
       if fileManager.fileExists(atPath: combinedFileURL.path) {
           try? fileManager.removeItem(at: combinedFileURL)
       }

       do {
           for fileURL in archivedLogFiles {
               let fileContents = try String(contentsOf: fileURL)
               try fileContents.appendLine(to: combinedFileURL)
           }
       } catch {
           print("Error combining archived log files: \(error)")
           return nil
       }

       combinedArchiveFileURL = combinedFileURL
       return combinedFileURL
   }

   /// Clears the combined archive file from memory.
   public func clearCombinedArchive() {
       guard let combinedArchiveFileURL = combinedArchiveFileURL else { return }

       let fileManager = FileManager.default
       
       do {
           try fileManager.removeItem(at: combinedArchiveFileURL)
       } catch {
           print("Error clearing combined archive: \(error)")
       }

       self.combinedArchiveFileURL = nil
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
        currentLogFileSize += UInt64(message.count)

        if let encodedData = "\(message)\n".data(using: String.Encoding.utf8) {
            do {
                try logFileHandle?.seekToEnd()
                try logFileHandle?.write(contentsOf: encodedData)
            } catch {
                print("Error writing to log file: \(error)")
            }
        }

        if shouldRotateArchivedLogs() {
            rotateCurrentLogFile()
        }
    }
    
    /// Get the URLs of the archived log files.
    ///
    /// - Parameters:   None.
    ///
    /// - Returns:      An array of file URLs pointing to previously archived log files, sorted with the most recent logs first.
    ///
    internal func archivedLogFileURLs() -> [URL] {
        // Determine the archive folder URL
        let archiveFolderURL: URL = self.archivedLogsFolderURL ?? Self.defaultLogFolderURL

        // Retrieve file URLs in the archive folder, or return an empty array if failed
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(at: archiveFolderURL, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]) else {
            return []
        }

        // Retrieve and sort file URLs based on their creation date
        let sortedFileURLs = fileURLs.compactMap { fileURL -> (url: URL, creationDate: Date)? in
            // Get file attributes and extract the creation date
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard let creationDate = attributes?[.creationDate] as? Date else { return nil }
            
            return (url: fileURL, creationDate: creationDate)
        }.sorted { $0.creationDate > $1.creationDate } // Sort by creation date, most recent first

        // Return only the sorted URLs
        return sortedFileURLs.map { $0.url }
    }
    
    /// Rotate the current log file.
    internal func rotateCurrentLogFile() {
        var archivedLogsFolderURL: URL = (self.archivedLogsFolderURL ?? Self.defaultLogFolderURL)
        
        archivedLogsFolderURL = archivedLogsFolderURL.appendingPathComponent("\(baseFileName)\(archiveSuffixDateFormatter.string(from: Date()))")
        archivedLogsFolderURL = archivedLogsFolderURL.appendingPathExtension(fileExtension)
        
        rotateFile(to: archivedLogsFolderURL)

        currentLogFileSize = 0

        cleanUpOldLogFiles()
    }
    
    /// Scan the log folder and delete log files that are no longer relevant.
    internal func cleanUpOldLogFiles() {
        var archivedLogFileURLs: [URL] = self.archivedLogFileURLs()
        guard archivedLogFileURLs.count > Int(targetMaxLogFiles) else { return }

        archivedLogFileURLs.removeFirst(Int(targetMaxLogFiles))

        let fileManager: FileManager = FileManager.default
        for archivedLogFileURL in archivedLogFileURLs {
            do {
                try fileManager.removeItem(at: archivedLogFileURL)
            }
            catch {
//                owner?._logln("Unable to delete old archived log file \(archivedFileURL.path): \(error.localizedDescription)", level: .error)
            }
        }
    }
    
    /// Determine if the log file should be rotated.
    /// - Returns:
    ///     - If the log file should be rotated.
    ///
    internal func shouldRotateArchivedLogs() -> Bool {
        // Do not rotate until critical setup has been completed so that we do not accidentally rotate once to the defaultLogFolderURL before determining the desired log location
        guard let _ = archivedLogsFolderURL else { return false }
        
        // File Size
        guard currentLogFileSize < targetMaxFileSize else { return true }

        return false
    }
    
    internal func purgeArchivedLogFiles() {
        let fileManager: FileManager = FileManager.default
        
        for archivedLogFileURL in archivedLogFileURLs() {
            do {
                try fileManager.removeItem(at: archivedLogFileURL)
            }
            catch {
//                owner?._logln("Unable to delete old archived log file \(archivedLogFileURLs.path): \(error.localizedDescription)", level: .error)
            }
        }
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
                write(message: "\(appendMarker)\n")
            }
        } catch {
            //        owner._logln("Attempt to open log file for \(action) failed: \(error.localizedDescription)", level: .error, source: self)
            logFileHandle = nil
            return
        }

//        owner.logAppDetails(selectedDestination: self)
        logOpeningDetails(fileExists: fileExists)
    }

    internal func logOpeningDetails(fileExists: Bool) {
        guard let currentLogFileURL = currentLogFileURL else { return }

//        let mode = fileExists ? "appending" : "writing"
//        let logMessage = "XCGLogger \(mode) log to: \(currentLogFileURL.absoluteString)"
//        let logDetails = LogDetails(level: .info, date: Date(), message: logMessage, functionName: "", fileName: "", lineNumber: 0, userInfo: XCGLogger.Constants.internalUserInfo)
        print("XCGLoggerlog to: \(currentLogFileURL.absoluteString)")
        //owner._logln(logDetails.message, level: logDetails.level, source: self)

//        if owner.destination(withIdentifier: identifier) == nil {
//            processInternal(logDetails: logDetails)
//        }
    }
    
    @discardableResult
    internal func rotateFile(to archiveToFile: Any) -> Bool {
        guard let archiveToFileURL = resolveAnyFileToUrl(from: archiveToFile) else { return false }

        guard let currentLogFileURL = currentLogFileURL else { return false }

        let fileManager = FileManager.default

        // Check if the destination file already exists
        guard !fileManager.fileExists(atPath: archiveToFileURL.path) else { return false }

        closeFile()

        do {
            try fileManager.moveItem(atPath: currentLogFileURL.path, toPath: archiveToFileURL.path)
        } catch {
            openFile()
//            owner?._logln("Unable to rotate file \(sourcePath) to \(destinationPath): \(error.localizedDescription)", level: .error, source: self)
            return false
        }

//        owner?._logln("Rotated file \(writeToFileURL.path) to \(archiveToFileURL.path)", level: .info, source: self)
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
