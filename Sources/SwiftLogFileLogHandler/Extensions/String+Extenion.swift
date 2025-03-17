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
        let data = (self + "
").data(using: .utf8)!
        if let fileHandle = try? FileHandle(forWritingTo: url) {
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: data)
            fileHandle.closeFile()
        } else {
            try data.write(to: url)
        }
    }
}
