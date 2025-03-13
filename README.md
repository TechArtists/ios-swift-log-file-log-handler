# SwiftLogFileLogHandler

**SwiftLogFileLogHandler** is a file-based logging backend for Apple’s [swift-log](https://github.com/apple/swift-log). It provides automatic log file rotation and structured metadata handling.

---

## Features

- **File-based Logging**: Persist logs to files for later analysis.
- **Automatic Log Rotation**: Ensures that log files are managed efficiently.
- **Metadata Support**: Includes structured metadata with each log entry.

---

## Installation

### Swift Package Manager

To include **SwiftLogFileLogHandler** in your project, add it to your `Package.swift` file:

```swift
let package = Package(
    name: "YourProject",
    platforms: [
        .iOS(.v14),
        .macOS(.v10_13)
    ],
    dependencies: [
        .package(
            url: "git@github.com:TechArtists/ios-swift-log-file-log-handler.git",
            from: "1.0.0"
        )
    ],
    targets: [
        .target(
            name: "YourTarget",
            dependencies: [
                .product(name: "SwiftLogFileLogHandler", package: "ios-swift-log-file-log-handler")
            ]
        )
    ]
)
```

Alternatively, to add the package using Xcode:

    1. Navigate to File > Add Packages.
    2. Enter the repository URL: `git@github.com:YourRepo/SwiftLogFileLogHandler.git`.
    3. Add the package to your target.

## Usage

### Basic Logging Example

```swift
import Logging
import SwiftLogFileLogHandler

let logger = Logger(label: "com.yourapp.main") { label in
    SwiftLogFileLogHandler(label: label)
}

logger.info("Application started successfully.")
logger.warning("Low disk space detected.")
```

### Accessing Log Files

To retrieve the current log file or combined stashed logs:

```swift
if let logFileURL = logger.getCurrentLogFileURL() {
    print("Current log file located at: \(logFileURL)")
}

if let combinedLogsURL = logger.getCombinedStashedLogFilesURL() {
    print("Combined log file at: \(combinedLogsURL)")
}

let stashedCount = logger.getCurrentStashedCount()
print("Number of stashed log files: \(stashedCount)")
```

## License

This project is licensed under the MIT License. See the LICENSE file for more details.
