//
//  String+Extenion.swift
//  SwiftLogFileLogHandler
//
//  Created by Robert Tataru on 05.11.2024.
//

import Foundation

// MARK: - String Extension for Appending to a File
extension String {
    /// Appends the string as a new line to the specified file.
    ///
    /// - Parameters:
    ///   - url: The URL of the file to append to.
    /// - Throws: An error if the file could not be written to.
    func appendLine(to url: URL) throws {
        let data = (self + "\n").data(using: .utf8)!
        if let fileHandle = try? FileHandle(forWritingTo: url) {
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: data)
            fileHandle.closeFile()
        } else {
            try data.write(to: url)
        }
    }
}
