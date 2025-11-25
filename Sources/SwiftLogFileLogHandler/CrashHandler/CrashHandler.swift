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
//  CrashHandler.swift
//  SwiftLogFileLogHandler
//
//  Created by Tech Artists Agency on 2025.
//

import Foundation
import Darwin
import OSLog

/// Represents a single stack frame with parsed information
private struct StackFrame {
    let index: Int
    let moduleName: String
    let address: String
    let symbol: String?
    let offset: String?
    let fileName: String?
    let lineNumber: Int64?
    let className: String?
    let rawLine: String
    
    var isSystemFramework: Bool {
        let systemModules = [
            "SwiftUI", "UIKitCore", "CoreFoundation", "Foundation",
            "libswiftCore", "SwiftUICore", "Gestures", "UIKit",
            "GraphicsServices", "UpdateCycle", "dyld", "libsystem"
        ]
        
        return systemModules.contains(where: { moduleName.hasPrefix($0) })
    }
    
    var isCrashHandler: Bool {
        // Check if this is a crash handler frame
        return symbol?.contains("CrashHandler") ?? false ||
               symbol?.contains("setupSignalHandlers") ?? false ||
               moduleName.contains("CrashHandler")
    }
    
    var isSignalHandling: Bool {
        return symbol?.contains("_sigtramp") ?? false ||
               symbol?.contains("_assertionFailure") ?? false ||
               symbol?.contains("__sigaction") ?? false
    }
    
    var isUserCode: Bool {
        return !isSystemFramework && !isCrashHandler && !isSignalHandling
    }
    
    var displaySymbol: String {
        guard let symbol = symbol else { return "Unknown" }
        
        // Extract readable parts from mangled Swift symbols
        if symbol.contains("ContentView") {
            return "ContentView"
        } else if symbol.contains("ViewModel") {
            return "ViewModel"
        } else if let match = symbol.range(of: #"(\w+View)"#, options: .regularExpression) {
            return String(symbol[match])
        } else if let match = symbol.range(of: #"(\w+Controller)"#, options: .regularExpression) {
            return String(symbol[match])
        }
        
        // Return truncated symbol if nothing matches
        return symbol.count > 50 ? String(symbol.prefix(47)) + "..." : symbol
    }
}

/// Handler for capturing crashes and logging them to file
public final class CrashHandler: @unchecked Sendable {
    
    // MARK: - Singleton
    public static let shared = CrashHandler()
    
    // MARK: - Type Aliases
    private typealias ExceptionHandler = @convention(c) (NSException) -> Void
    
    // MARK: - Properties
    private let isolationQueue = DispatchQueue(label: "com.tech-artists.CrashHandler.queue", attributes: .concurrent)
    
    private var _previousHandler: ExceptionHandler?
    private var previousHandler: ExceptionHandler? {
        get { isolationQueue.sync { _previousHandler } }
        set { isolationQueue.async(flags: .barrier) { self._previousHandler = newValue } }
    }
    
    private var _logCallback: (@Sendable (String) -> Void)?
    private var logCallback: (@Sendable (String) -> Void)? {
        get { isolationQueue.sync { _logCallback } }
        set { isolationQueue.async(flags: .barrier) { self._logCallback = newValue } }
    }
    
    // MARK: - Lifecycle
    private init() {}
    
    // MARK: - Public Methods
    
    /// Registers crash handlers with a callback to log crash information
    /// - Parameter logCallback: Callback that receives formatted crash information as a string
    public func register(logCallback: @escaping @Sendable (String) -> Void) {
        self.logCallback = logCallback
        setupExceptionHandler()
        setupSignalHandlers()
        logger.info("CrashHandler registered successfully")
    }
    
    // MARK: - Private Methods
    
    private func setupExceptionHandler() {
        previousHandler = NSGetUncaughtExceptionHandler()
        
        let newHandler: ExceptionHandler = { exception in
            logger.error("NSException captured: \(exception.name.rawValue) - \(exception.reason ?? "No reason")")
            
            let crashInfo = CrashHandler.formatExceptionInfo(exception)
            CrashHandler.shared.logCallback?(crashInfo)
            
            // Call previous handler if it exists (e.g., Crashlytics)
            // This allows third-party crash reporters to process the exception
            CrashHandler.shared.previousHandler?(exception)
        }
        
        NSSetUncaughtExceptionHandler(newHandler)
        logger.info("NSException handler configured")
    }
    
    private func setupSignalHandlers() {
        let signals = [SIGABRT, SIGSEGV, SIGILL, SIGTRAP, SIGBUS, SIGPIPE, SIGSYS, SIGFPE]
        
        signals.forEach { sig in
            var action = sigaction()
            action.sa_flags = SA_SIGINFO
            action.__sigaction_u.__sa_sigaction = { (signal, info, context) in
                logger.error("Signal \(signal) captured - starting crash report generation")
                
                let backtraceSymbols = Thread.callStackSymbols
                let crashInfo = CrashHandler.formatSignalCrashInfo(signal: signal, stack: backtraceSymbols)
                
                logger.error("Crash report generated, invoking callback")
                CrashHandler.shared.logCallback?(crashInfo)
                logger.error("Callback completed")
                
                // Reset signal handler to default and re-raise
                // This allows other crash handlers (like Crashlytics) to process the crash
                var defaultAction = sigaction()
                sigaction(signal, nil, &defaultAction)
                defaultAction.__sigaction_u.__sa_handler = SIG_DFL
                sigaction(signal, &defaultAction, nil)
                
                // Re-raise the signal to trigger default behavior and other handlers
                kill(getpid(), signal)
            }
            sigaction(sig, &action, nil)
        }
        
        logger.info("Signal handlers configured for signals: \([SIGABRT, SIGSEGV, SIGILL, SIGTRAP, SIGBUS, SIGPIPE, SIGSYS, SIGFPE])")
    }
    
    // MARK: - Formatting Methods
    
    /// Formats NSException information into a readable crash log string
    private static func formatExceptionInfo(_ exception: NSException) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let frames = parseStackFrames(exception.callStackSymbols)
        let userFrames = frames.filter { $0.isUserCode }
        
        var output = """
        
        ╔════════════════════════════════════════════════════════════════════════════════╗
        ║                            CRASH REPORT - NSException                          ║
        ╚════════════════════════════════════════════════════════════════════════════════╝
        
        📅 Timestamp: \(timestamp)
        💥 Exception:  \(exception.name.rawValue)
        📝 Reason:     \(exception.reason ?? "Unknown")
        
        """
        
        output += formatCrashLocation(userFrames: userFrames, allFrames: frames)
        output += formatUserStack(userFrames: userFrames)
        output += formatCompleteStack(frames: frames)
        
        // Add user info if available
        if let userInfo = exception.userInfo, !userInfo.isEmpty {
            output += "\n┌─ User Info ─────────────────────────────────────────────────────────────────┐\n"
            for (key, value) in userInfo {
                output += "│ \(key): \(value)\n"
            }
            output += "└─────────────────────────────────────────────────────────────────────────────────┘\n"
        }
        
        output += "\n════════════════════════════════════════════════════════════════════════════════\n"
        
        return output
    }
    
    /// Formats signal crash information into a readable crash log string
    private static func formatSignalCrashInfo(signal: Int32, stack: [String]) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let signalName = getSignalName(signal)
        let signalDescription = getSignalDescription(signal)
        let frames = parseStackFrames(stack)
        let userFrames = frames.filter { $0.isUserCode }
        
        var output = """
        
        ╔════════════════════════════════════════════════════════════════════════════════╗
        ║                              CRASH REPORT - Signal                             ║
        ╚════════════════════════════════════════════════════════════════════════════════╝
        
        📅 Timestamp:   \(timestamp)
        💥 Signal:      \(signalName) (\(signal))
        📝 Description: \(signalDescription)
        
        """
        
        output += formatCrashLocation(userFrames: userFrames, allFrames: frames)
        output += formatUserStack(userFrames: userFrames)
        output += formatCompleteStack(frames: frames)
        
        output += "\n════════════════════════════════════════════════════════════════════════════════\n"
        
        return output
    }
    
    private static func formatCrashLocation(userFrames: [StackFrame], allFrames: [StackFrame]) -> String {
        var output = """
        ╔═══════════════════════════════════════════════════════════════════════════════╗
        ║ 🚨 CRASH LOCATION                                                             ║
        ╚═══════════════════════════════════════════════════════════════════════════════╝
        
        """
        
        // Try to find the first meaningful user frame
        if let crashFrame = userFrames.first {
            output += "🔴 CRASHED IN YOUR CODE:\n\n"
            output += "   Frame:    #\(crashFrame.index)\n"
            output += "   Module:   \(crashFrame.moduleName)\n"
            output += "   Function: \(crashFrame.displaySymbol)\n"
            output += "   Address:  \(crashFrame.address) + \(crashFrame.offset ?? "0")\n"
            
            if let fileName = crashFrame.fileName, let lineNumber = crashFrame.lineNumber {
                output += "   File:     \(fileName):\(lineNumber)\n"
            } else {
                output += "\n   ℹ️  Tip: Enable debug symbols (dSYM) for file:line information\n"
            }
            
            output += "\n"
        } else {
            // Show the first few non-crash-handler frames
            output += "⚠️  No user code found in stack trace\n"
            output += "   Showing first application frame:\n\n"
            
            if let firstAppFrame = allFrames.first(where: { !$0.isCrashHandler && !$0.isSignalHandling }) {
                output += "   Frame:    #\(firstAppFrame.index)\n"
                output += "   Module:   \(firstAppFrame.moduleName)\n"
                output += "   Function: \(firstAppFrame.displaySymbol)\n"
                output += "   Address:  \(firstAppFrame.address)\n\n"
            }
        }
        
        return output
    }
    
    private static func formatUserStack(userFrames: [StackFrame]) -> String {
        guard !userFrames.isEmpty else { return "" }
        
        var output = """
        ┌─ Your Application Call Stack ───────────────────────────────────────────────┐
        
        """
        
        for (idx, frame) in userFrames.enumerated().prefix(10) {
            let marker = idx == 0 ? "👉" : "  "
            let symbolDisplay = frame.displaySymbol
            
            output += String(format: "\(marker) #%-2d %-40s", frame.index, symbolDisplay)
            
            if let fileName = frame.fileName, let lineNumber = frame.lineNumber {
                output += " \(fileName):\(lineNumber)\n"
            } else {
                output += " \(frame.moduleName)\n"
            }
        }
        
        if userFrames.count > 10 {
            output += "    ... (\(userFrames.count - 10) more frames in your code)\n"
        }
        
        output += """
        
        └─────────────────────────────────────────────────────────────────────────────────┘
        
        
        """
        
        return output
    }
    
    private static func formatCompleteStack(frames: [StackFrame]) -> String {
        var output = """
        ┌─ Complete Stack Trace ──────────────────────────────────────────────────────┐
        │ Legend: 🔴 Your Code  ⚙️  Crash Handler    System Frameworks             │
        ├─────────────────────────────────────────────────────────────────────────────────┤
        
        """
        
        for frame in frames.prefix(30) {
            let marker: String
            if frame.isCrashHandler {
                marker = "⚙️ "
            } else if frame.isUserCode {
                marker = "🔴"
            } else {
                marker = "  "
            }
            
            let moduleDisplay = frame.moduleName.count > 30
                ? String(frame.moduleName.prefix(27)) + "..."
                : frame.moduleName.padding(toLength: 30, withPad: " ", startingAt: 0)
            
            let symbolDisplay = frame.displaySymbol.count > 35
                ? String(frame.displaySymbol.prefix(32)) + "..."
                : frame.displaySymbol
            
            output += String(format: "\(marker) #%-2d %-30s %s\n", frame.index, moduleDisplay, symbolDisplay)
        }
        
        if frames.count > 30 {
            output += "\n   ... (\(frames.count - 30) more frames omitted)\n"
        }
        
        output += "└─────────────────────────────────────────────────────────────────────────────────┘\n"
        
        return output
    }
    
    /// Parses stack frames from backtrace symbols
    private static func parseStackFrames(_ stackSymbols: [String]) -> [StackFrame] {
        var frames: [StackFrame] = []
        
        // Regex patterns for parsing stack frames
        let framePattern = try! NSRegularExpression(
            pattern: "^(\\d+)\\s+([^\\s]+)\\s+(0x[0-9a-fA-F]+)\\s+(.+?)(?:\\s+\\+\\s+(\\d+))?$"
        )
        let symbolPattern = try! NSRegularExpression(
            pattern: "\\s+\\d+\\s+[^\\s]+\\s+([^\\s]+)\\s+\\+"
        )
        let fileLinePattern = try! NSRegularExpression(
            pattern: "([^/]+(?:\\.swift|\\.m|\\.h|\\.mm)):(\\d+)"
        )
        
        for (idx, symbolString) in stackSymbols.enumerated() {
            let nsString = symbolString as NSString
            let range = NSRange(location: 0, length: nsString.length)
            
            var index = idx
            var moduleName = "Unknown"
            var address = ""
            var symbol: String?
            var offset: String?
            var fileName: String?
            var lineNumber: Int64?
            var className: String?
            
            // Parse main frame structure
            if let match = framePattern.firstMatch(in: symbolString, range: range) {
                if match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound {
                    if let idx = Int(nsString.substring(with: match.range(at: 1))) {
                        index = idx
                    }
                }
                if match.numberOfRanges > 2, match.range(at: 2).location != NSNotFound {
                    moduleName = nsString.substring(with: match.range(at: 2))
                }
                if match.numberOfRanges > 3, match.range(at: 3).location != NSNotFound {
                    address = nsString.substring(with: match.range(at: 3))
                }
                if match.numberOfRanges > 4, match.range(at: 4).location != NSNotFound {
                    symbol = nsString.substring(with: match.range(at: 4))
                }
                if match.numberOfRanges > 5, match.range(at: 5).location != NSNotFound {
                    offset = nsString.substring(with: match.range(at: 5))
                }
            } else {
                // Fallback parsing for malformed frames
                let components = symbolString.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                if components.count > 1 {
                    moduleName = String(components[1])
                }
            }
            
            // Extract symbol/class name
            if let match = symbolPattern.firstMatch(in: symbolString, range: range),
               match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound {
                let fullSymbol = nsString.substring(with: match.range(at: 1))
                className = String(fullSymbol.split(separator: ".", maxSplits: 1).first ?? Substring(fullSymbol))
            }
            
            // Extract file name and line number
            if let match = fileLinePattern.firstMatch(in: symbolString, range: range),
               match.numberOfRanges > 2 {
                fileName = nsString.substring(with: match.range(at: 1))
                if let num = Int64(nsString.substring(with: match.range(at: 2))) {
                    lineNumber = num
                }
            }
            
            frames.append(StackFrame(
                index: index,
                moduleName: moduleName,
                address: address,
                symbol: symbol,
                offset: offset,
                fileName: fileName,
                lineNumber: lineNumber,
                className: className,
                rawLine: symbolString
            ))
        }
        
        return frames
    }
    
    /// Converts signal number to human-readable name
    private static func getSignalName(_ signal: Int32) -> String {
        switch signal {
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGILL: return "SIGILL"
        case SIGTRAP: return "SIGTRAP"
        case SIGBUS: return "SIGBUS"
        case SIGPIPE: return "SIGPIPE"
        case SIGSYS: return "SIGSYS"
        case SIGFPE: return "SIGFPE"
        default: return "Signal \(signal)"
        }
    }
    
    /// Provides human-readable description for signal
    private static func getSignalDescription(_ signal: Int32) -> String {
        switch signal {
        case SIGABRT: return "Abnormal termination (abort)"
        case SIGSEGV: return "Segmentation fault (invalid memory access)"
        case SIGILL: return "Illegal instruction"
        case SIGTRAP: return "Trace/breakpoint trap"
        case SIGBUS: return "Bus error (invalid memory alignment)"
        case SIGPIPE: return "Broken pipe"
        case SIGSYS: return "Bad system call"
        case SIGFPE: return "Floating-point exception"
        default: return "Unknown signal"
        }
    }
}
