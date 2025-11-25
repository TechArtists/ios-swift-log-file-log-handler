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
            
            let crashInfo = CrashHandler.formatExceptionCrash(exception)
            CrashHandler.shared.logCallback?(crashInfo)
            
            // Call previous handler if it exists (e.g., Crashlytics)
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
                let crashInfo = CrashHandler.formatSignalCrash(signal: signal, stack: backtraceSymbols)
                
                logger.error("Crash report generated, invoking callback")
                CrashHandler.shared.logCallback?(crashInfo)
                logger.error("Callback completed")
                
                // Reset signal handler to default and re-raise
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
    
    /// Formats NSException crash into readable log
    private static func formatExceptionCrash(_ exception: NSException) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let stack = exception.callStackSymbols
        
        var output = """
        
        ================================================================================
        CRASH REPORT - NSException
        ================================================================================
        Timestamp:   \(timestamp)
        Exception:   \(exception.name.rawValue)
        Reason:      \(exception.reason ?? "Unknown")
        
        """
        
        output += formatStackTrace(stack)
        
        // Add user info if available
        if let userInfo = exception.userInfo, !userInfo.isEmpty {
            output += "\n--- User Info ---\n"
            for (key, value) in userInfo {
                output += "\(key): \(value)\n"
            }
        }
        
        output += "\n================================================================================\n"
        
        return output
    }
    
    /// Formats signal crash into readable log
    private static func formatSignalCrash(signal: Int32, stack: [String]) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let signalName = getSignalName(signal)
        let signalDescription = getSignalDescription(signal)
        
        var output = """
        
        ================================================================================
        CRASH REPORT - Signal
        ================================================================================
        Timestamp:   \(timestamp)
        Signal:      \(signalName) (\(signal))
        Description: \(signalDescription)
        
        """
        
        output += formatStackTrace(stack)
        output += "\n================================================================================\n"
        
        return output
    }
    
    /// Formats stack trace with intelligent filtering
    private static func formatStackTrace(_ stackSymbols: [String]) -> String {
        var output = "--- Stack Trace ---\n"
        
        let maxFrames = 50
        let framesToShow = min(stackSymbols.count, maxFrames)
        
        for (index, symbol) in stackSymbols.prefix(framesToShow).enumerated() {
            // Clean up the symbol string
            let cleaned = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Mark frames that might be from user code
            let marker = isLikelyUserCode(cleaned) ? ">>> " : "    "
            
            output += "\(marker)#\(index) \(cleaned)\n"
        }
        
        if stackSymbols.count > maxFrames {
            output += "    ... (\(stackSymbols.count - maxFrames) more frames)\n"
        }
        
        return output
    }
    
    /// Simple heuristic to identify potential user code
    private static func isLikelyUserCode(_ symbol: String) -> Bool {
        // Exclude common system frameworks
        let systemPrefixes = [
            "libswift", "SwiftUI", "UIKitCore", "CoreFoundation",
            "Foundation", "QuartzCore", "UIKit", "AppKit",
            "libdispatch", "libsystem", "dyld", "GraphicsServices"
        ]
        
        // Exclude signal handling
        if symbol.contains("_sigtramp") || symbol.contains("CrashHandler") {
            return false
        }
        
        // Check if it's a system framework
        for prefix in systemPrefixes {
            if symbol.contains(prefix) {
                return false
            }
        }
        
        return true
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