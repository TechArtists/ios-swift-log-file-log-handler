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

public final class CrashHandler: @unchecked Sendable {
    
    public static let shared = CrashHandler()
    private init() {}

    private let isolationQueue = DispatchQueue(label: "com.tech-artists.CrashHandler.queue", attributes: .concurrent)

    private var _previousHandler: ExceptionHandler?
    private typealias ExceptionHandler = @convention(c) (NSException) -> Void
    
    private var previousHandler: ExceptionHandler? {
        get { isolationQueue.sync { _previousHandler } }
        set { isolationQueue.async(flags: .barrier) { self._previousHandler = newValue } }
    }

    private var _logCallback: (@Sendable (String) -> Void)?
    private var logCallback: (@Sendable (String) -> Void)? {
        get { isolationQueue.sync { _logCallback } }
        set { isolationQueue.async(flags: .barrier) { self._logCallback = newValue } }
    }

    // MARK: - Public API
    
    public func register(logCallback: @escaping @Sendable (String) -> Void) {
        self.logCallback = logCallback
        setupExceptionHandler()
        setupSignalHandlers()
        logger.info("CrashHandler registered successfully")
    }

    // MARK: - Exception Handling
    
    private func setupExceptionHandler() {
        previousHandler = NSGetUncaughtExceptionHandler()
        
        let newHandler: ExceptionHandler = { exception in
            logger.error("NSException captured: \(exception.name.rawValue)")
            
            let crashInfo = CrashHandler.formatExceptionCrash(exception)
            CrashHandler.shared.logCallback?(crashInfo)
            
            CrashHandler.shared.previousHandler?(exception)
        }
        
        NSSetUncaughtExceptionHandler(newHandler)
        logger.info("NSException handler configured")
    }

    // MARK: - Signal Handling
    
    private func setupSignalHandlers() {
        let signals = [SIGABRT, SIGSEGV, SIGILL, SIGTRAP, SIGBUS, SIGPIPE, SIGSYS, SIGFPE]

        signals.forEach { sig in
            var action = sigaction()
            action.sa_flags = SA_SIGINFO
            action.__sigaction_u.__sa_sigaction = { signal, info, context in
                
                let stack = Thread.callStackSymbols
                let reason = CrashHandler.inferCrashReason(signal: signal, stack: stack, info: info)

                let crashInfo = CrashHandler.formatSignalCrash(
                    signal: signal,
                    reason: reason,
                    stack: stack
                )
                
                CrashHandler.shared.logCallback?(crashInfo)
                
                var defaultAction = sigaction()
                sigaction(signal, nil, &defaultAction)
                defaultAction.__sigaction_u.__sa_handler = SIG_DFL
                sigaction(signal, &defaultAction, nil)
                
                kill(getpid(), signal)
            }
            sigaction(sig, &action, nil)
        }
    }
}

// MARK: - Formatting

extension CrashHandler {

    /// Formats NSException crash into readable log
    private static func formatExceptionCrash(_ exception: NSException) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let demangledStack = exception.callStackSymbols.map { demangle($0) }

        var output = """
        
        ================================================================================
        CRASH REPORT - NSException
        ================================================================================
        Timestamp:   \(timestamp)
        Exception:   \(exception.name.rawValue)
        Reason:      \(exception.reason ?? "Unknown")
        
        --- Summary ---
        \(extractTopFrame(from: demangledStack))
        
        """
        
        output += formatStackTrace(demangledStack)
        output += "\n================================================================================\n"
        return output
    }

    /// Basic Swift symbol demangling using `swift-demangle` fallback
    private static func demangle(_ symbol: String) -> String {
        // Try to find Swift mangled symbol (with or without underscore prefix)
        var mangled: String?
        
        if let range = symbol.range(of: "_$s") {
            mangled = String(symbol[range.lowerBound...])
        } else if let range = symbol.range(of: "$s") {
            mangled = String(symbol[range.lowerBound...])
        }
        
        guard let mangledSymbol = mangled else { return symbol }
        
        // Extract just the mangled part (before + offset)
        let components = mangledSymbol.components(separatedBy: " + ")
        let pureMangled = components.first ?? mangledSymbol
        
        if let demangled = _stdlib_demangleName(pureMangled) {
            return symbol.replacingOccurrences(of: pureMangled, with: demangled)
        }
        
        return symbol
    }

    @inline(__always)
    private static func _stdlib_demangleName(_ name: String) -> String? {
        guard let cString = name.cString(using: .utf8) else { return nil }
        guard let demangledPtr = swift_demangle(cString, UInt(strlen(cString)),
                                                nil, nil, 0) else { return nil }
        let result = String(cString: demangledPtr)
        free(demangledPtr)
        return result
    }

    @_silgen_name("swift_demangle")
    private static func swift_demangle(
        _ mangledName: UnsafePointer<CChar>?,
        _ mangledNameLength: UInt,
        _ outputBuffer: UnsafeMutablePointer<CChar>?,
        _ outputBufferSize: UnsafeMutablePointer<UInt>?,
        _ flags: UInt32
    ) -> UnsafeMutablePointer<CChar>?
    
    private static func inferCrashReason(signal: Int32, stack: [String], info: UnsafePointer<siginfo_t>?) -> String {
        
        // 1. Signal → Root-cause mapping
        switch signal {
        case SIGTRAP:
            if stack.joined().contains("assertionFailure") { return "Swift assertionFailure triggered" }
            if stack.joined().contains("precondition") { return "Swift precondition failure" }
            return "Trace / breakpoint trap (fatalError or assert)"

        case SIGSEGV:
            return "Invalid memory access (most likely nil pointer dereference)"

        case SIGABRT:
            return "abort() called (usually fatalError or Swift runtime trap)"

        case SIGILL:
            return "Illegal CPU instruction (corrupted memory or invalid executable state)"

        case SIGBUS:
            return "Alignment error or accessing unmapped memory"

        case SIGFPE:
            return "Floating point exception (divide by zero?)"

        case SIGPIPE:
            return "Write to a closed pipe / file descriptor"

        default:
            break
        }
        
        // 2. Analyze stack for Swift crashes
        for frame in stack.prefix(10) {
            if frame.contains("fatalError") { return "fatalError() called" }
            if frame.contains("assertionFailure") { return "assertionFailure()" }
            if frame.contains("Swift/ContiguousArrayBuffer") { return "Array index out of bounds" }
            if frame.contains("_swift_runtime_on_report") { return "Swift runtime internal error" }
            if frame.contains("force unwrap") { return "Force unwrapped optional was nil" }
        }
        
        return "Unknown cause — see stack trace"
    }
    
    private static func formatSignalCrash(signal: Int32, reason: String, stack: [String]) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        
        var output = """
        
        ================================================================================
        CRASH REPORT - SIGNAL
        ================================================================================
        Timestamp:   \(timestamp)
        Signal:      \(getSignalName(signal)) (\(signal))
        Root Cause:  \(reason)

        --- Summary ---
        \(extractTopFrame(from: stack))

        """
        
        output += formatStackTrace(stack, compact: true)
        output += "\n================================================================================\n"
        return output
    }

    private static func extractTopFrame(from stack: [String]) -> String {
        for symbol in stack {

            // Initial cleanup
            var cleaned = clean(symbol)

            // Skip CrashHandler frames
            if cleaned.contains("CrashHandler") { continue }

            // Skip signal handler/trampoline frames
            if cleaned.contains("_sigtramp") { continue }
            if cleaned.contains("sigaction") { continue }

            // Skip assertion internals
            if cleaned.contains("assertionFailure") { continue }
            if cleaned.contains("$ss17_assertionFailure") { continue }

            // Skip Swift runtime traps
            if cleaned.contains("swift_runtime") { continue }

            // Skip setupSignalHandlers frames
            if cleaned.contains("setupSignalHandlers") { continue }

            // ----- BEGIN: Apply same formatting rules as formatStackTrace -----

            // Remove memory address (0x0000...)
            if let addrRange = cleaned.range(of: #"0x[0-9a-fA-F]+"#, options: .regularExpression) {
                cleaned.removeSubrange(addrRange)
            }

            // Remove module name (index + module tokens)
            if let moduleRange = cleaned.range(of: #"^\S+\s+\S+\s+"#, options: .regularExpression) {
                cleaned.removeSubrange(moduleRange)
            }

            // Demangle Swift symbol
            cleaned = demangle(cleaned)

            // Trim whitespace
            cleaned = cleaned.trimmingCharacters(in: .whitespaces)

            // ----- END formatting rules -----

            // First real user frame
            if isLikelyUserCode(cleaned) {
                return cleaned
            }
        }

        return "No identifiable user frame"
    }

    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private static func formatStackTrace(_ stackSymbols: [String], compact: Bool = false) -> String {
        var output = "--- Stack Trace ---\n"

        for (i, symbol) in stackSymbols.enumerated() {
            var cleaned = clean(symbol)

            // Remove memory address (0x0000...)
            if let addrRange = cleaned.range(of: #"0x[0-9a-fA-F]+"#, options: .regularExpression) {
                cleaned.removeSubrange(addrRange)
            }

            // Remove module name (anything up to first space after index)
            if let moduleRange = cleaned.range(of: #"^\S+\s+\S+\s+"#, options: .regularExpression) {
                cleaned.removeSubrange(moduleRange)
            }

            // Demangle Swift symbols
            cleaned = demangle(cleaned)

            // Trim extra spaces
            cleaned = cleaned.trimmingCharacters(in: .whitespaces)

            let isUser = isLikelyUserCode(cleaned)
            
            if compact {
                // Compact mode: only show user frames and first few system frames
                if isUser {
                    output += ">>> #\(i) \(simplifySymbol(cleaned))\n"
                } else if i < 5 {
                    // Show first few system frames for context
                    output += "    #\(i) \(simplifySymbol(cleaned))\n"
                }
            } else {
                // Full mode
                output += "\(isUser ? ">>> " : "    ")#\(i) \(cleaned)\n"
            }
        }

        return output
    }

    /// Simplifies demangled symbols to make them more readable
    private static func simplifySymbol(_ symbol: String) -> String {
        var simplified = symbol
        
        // Remove generic noise like "Swift.Optional<...>"
        simplified = simplified.replacingOccurrences(of: "Swift.Optional<", with: "")
        simplified = simplified.replacingOccurrences(of: "Swift.UnsafeMutablePointer<", with: "")
        simplified = simplified.replacingOccurrences(of: "Swift.UnsafeMutableRawPointer", with: "")
        simplified = simplified.replacingOccurrences(of: "__C.__siginfo", with: "")
        simplified = simplified.replacingOccurrences(of: "Swift.", with: "")
        simplified = simplified.replacingOccurrences(of: "SwiftUI.", with: "")
        simplified = simplified.replacingOccurrences(of: "CoreGraphics.", with: "")
        
        // Remove closure noise patterns
        if simplified.contains("closure #") {
            // Extract just the important part
            if let range = simplified.range(of: #"in (\w+\.\w+\.\w+)"#, options: .regularExpression) {
                return "closure in " + String(simplified[range])
            }
        }
        
        // Remove excessive generic parameters like "<A where A: ...>"
        if let genericStart = simplified.firstIndex(of: "<"),
           let genericEnd = simplified.lastIndex(of: ">"),
           genericStart < genericEnd {
            let beforeGeneric = simplified[..<genericStart]
            let afterGeneric = simplified.index(after: genericEnd) < simplified.endIndex ? 
                simplified[simplified.index(after: genericEnd)...] : ""
            simplified = String(beforeGeneric) + "<...>" + String(afterGeneric)
        }
        
        // Trim to reasonable length
        if simplified.count > 100 {
            simplified = String(simplified.prefix(97)) + "..."
        }
        
        return simplified.trimmingCharacters(in: .whitespaces)
    }

    private static func isLikelyUserCode(_ symbol: String) -> Bool {
        let systemPrefixes = [
            "libswift", "SwiftUI", "UIKit", "UIKitCore", "CoreFoundation",
            "Foundation", "QuartzCore", "libsystem", "GraphicsServices", "dyld"
        ]

        if systemPrefixes.contains(where: { symbol.contains($0) }) {
            return false
        }

        if symbol.contains("CrashHandler") { return false }
        if symbol.contains("_sigtramp") { return false }
        if symbol.contains("sigaction") { return false }
        if symbol.contains("swift_runtime") { return false }

        return true
    }

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
}