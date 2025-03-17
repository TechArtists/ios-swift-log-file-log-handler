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
//  ZipUtility.swift
//  SwiftLogFileLogHandler
//
//  Created by Robert Tataru on 05.02.2025.
//
import Foundation

/// Custom errors for the zip archive creation process.
enum ZipArchiveError: Error {
    case coordinationFailed(Error)
    case archiveNotCreated
    case sourceDoesNotExist
}

struct ZipUtility {
    
    // MARK: - Helper Methods
    
    /// Checks if the given URL represents a folder.
    /// - Parameter url: The URL to check.
    /// - Returns: `true` if the URL is a folder; `false` otherwise.
    /// - Throws: `ZipArchiveError.sourceDoesNotExist` if the item does not exist.
    static func isFolder(url: URL) throws -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ZipArchiveError.sourceDoesNotExist
        }
        return isDirectory.boolValue
    }
    
    /// Ensures that the provided source URL points to a folder.
    ///
    /// If the source URL is a file, creates a temporary folder in the same directory (using the file’s base name),
    /// copies the file into that folder, and returns the folder's URL.
    ///
    /// - Parameter sourceURL: The file or directory URL.
    /// - Returns: A tuple containing:
    ///   - `folderURL`: A URL that points to a folder containing the source item.
    ///   - `isTemporary`: `true` if a temporary folder was created (because the source was a file); otherwise `false`.
    /// - Throws: An error if the source does not exist or if file operations fail.
    static func ensureFolder(for sourceURL: URL) throws -> (folderURL: URL, isTemporary: Bool) {
        let fileManager = FileManager.default
        
        if try isFolder(url: sourceURL) {
            return (sourceURL, false)
        } else {
            let folderName = sourceURL.deletingPathExtension().lastPathComponent
            let folderURL = sourceURL.deletingLastPathComponent().appendingPathComponent(folderName)
            
            if !fileManager.fileExists(atPath: folderURL.path) {
                try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true, attributes: nil)
            }
            
            let destinationURL = folderURL.appendingPathComponent(sourceURL.lastPathComponent)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            
            return (folderURL, true)
        }
    }
    
    // MARK: - Main Method
    
    /// Creates a zip archive for the item at `sourceURL` (after ensuring it is a folder)
    /// and moves it to the specified destination URL.
    ///
    /// If the source is a file, it will be wrapped in a temporary folder that is cleaned up after archiving.
    ///
    /// - Parameters:
    ///   - sourceURL: The file or directory URL to zip.
    ///   - destinationURL: A destination URL for the zip archive.
    /// - Returns: The URL of the created zip archive.
    /// - Throws: An error if the archiving process fails.
    static func createZipArchive(from sourceURL: URL, to destinationURL: URL) throws -> URL {
        let fileManager = FileManager.default
        
        let (folderURL, isTemporaryFolder) = try ensureFolder(for: sourceURL)
        
        defer {
            if isTemporaryFolder {
                do {
                    try fileManager.removeItem(at: folderURL)
                } catch ZipArchiveError.sourceDoesNotExist {
                    TALogger.main.warning("Warning: Source URL \(sourceURL) does not exist")
                } catch {
                    TALogger.main.warning("Warning: Failed to remove temporary folder at \(folderURL): \(error)")
                }
            }
        }
        
        var finalArchiveURL: URL?
        var coordinatorError: NSError?
        var blockError: Error?
        
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: folderURL, options: [.forUploading], error: &coordinatorError) { tempZipURL in
            do {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.moveItem(at: tempZipURL, to: destinationURL)
                finalArchiveURL = destinationURL
            } catch {
                blockError = error
            }
        }
        
        if let coordinationError = coordinatorError {
            throw ZipArchiveError.coordinationFailed(coordinationError)
        }
        
        if let error = blockError {
            throw error
        }
        
        guard let archiveURL = finalArchiveURL else {
            throw ZipArchiveError.archiveNotCreated
        }
        
        return archiveURL
    }
}
