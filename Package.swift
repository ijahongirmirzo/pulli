// swift-tools-version: 6.2
import Foundation
import PackageDescription

// libmtp and libusb are built by Vendor/build-deps.sh into Vendor/out. During development the
// binaries find them through an absolute rpath into that folder; the app bundle instead uses
// @executable_path/../Frameworks (set in project.yml). Linker settings of MTPKit propagate to
// everything that links it, so they are declared only there.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let vendorLib = "\(root)/Vendor/out/lib"
let linkVendoredLibs: [LinkerSetting] = [
    .unsafeFlags(["-L", vendorLib, "-Xlinker", "-rpath", "-Xlinker", vendorLib]),
]

let isAppStore = ProcessInfo.processInfo.environment["PULLI_APP_STORE"] != nil

var strictSwift: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]
if isAppStore {
    strictSwift.append(.define("PULLI_APP_STORE"))
}

var pulliDependencies: [Target.Dependency] = [
    "DeviceAPI",
    "PulliClient", "PulliProtocol", "PulliHost", "WorkerIPC", "PulliWidgetViews",
    .product(name: "FinderLocations", package: "FinderLocations"),
    .product(name: "RemoteFiles", package: "FinderLocations"),
    "TransferCore",
]
if !isAppStore {
    pulliDependencies.append(.product(name: "Sparkle", package: "Sparkle"))
}

let package = Package(
    name: "Pulli",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "pulli-cli", targets: ["pulli-cli"]),
        .executable(name: "Pulli", targets: ["Pulli"]),
        // Pulli's core, for other apps (docs/REUSING.md): the phone-session seam, the resumable
        // transfer engine and journal, and a simulated phone with fault injection for tests.
        .library(name: "DeviceAPI", targets: ["DeviceAPI"]),
        .library(name: "TransferCore", targets: ["TransferCore"]),
        .library(name: "MockDevice", targets: ["MockDevice"]),
    ],
    dependencies: [
        .package(path: "Packages/FinderLocations"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // The seam between the engine and devices. Foundation only.
        .target(name: "DeviceAPI", swiftSettings: strictSwift),

        // IOKit: USB identity, link speed, interface holders, camera daemons.
        .target(name: "USBKit", dependencies: ["DeviceAPI"], swiftSettings: strictSwift),

        // C module over the vendored libmtp header. Linking is declared by the module map.
        .systemLibrary(name: "CLibMTP", path: "Sources/CLibMTP"),

        .target(
            name: "MTPKit",
            dependencies: ["CLibMTP", "DeviceAPI", "USBKit", "TransferCore"],
            swiftSettings: strictSwift,
            linkerSettings: linkVendoredLibs
        ),

        .target(name: "MockDevice", dependencies: ["DeviceAPI"], swiftSettings: strictSwift),

        // Phones through Apple's ImageCaptureCore (macOS's camera service): the App Store
        // edition's backend, which needs neither libmtp nor stopping ptpcamerad (docs/APP_STORE.md).
        .target(name: "ICCKit", dependencies: ["DeviceAPI"], swiftSettings: strictSwift),

        .target(
            name: "TransferCore",
            dependencies: ["DeviceAPI", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: strictSwift
        ),

        // The versioned vocabulary between the app and the helper. Foundation only.
        .target(name: "PulliProtocol", swiftSettings: strictSwift),

        // The app's side: connection protocol and the state reducer. No TransferCore, no libmtp.
        .target(name: "PulliClient", dependencies: ["PulliProtocol"], swiftSettings: strictSwift),

        // The helper's core: phones, batches, events. Transport-independent (XPC or loopback).
        .target(
            name: "HelperCore",
            dependencies: ["PulliProtocol", "PulliClient", "TransferCore", "DeviceAPI", "USBKit", "WorkerIPC"],
            swiftSettings: strictSwift
        ),

        .executableTarget(
            name: "pulli-cli",
            dependencies: [
                "MTPKit", "USBKit", "TransferCore", "DeviceAPI", "PulliClient", "PulliProtocol", "WorkerIPC", "pulli-mtp-worker", "ICCKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: strictSwift
        ),

        .testTarget(name: "DeviceAPITests", dependencies: ["DeviceAPI"], swiftSettings: strictSwift),
        .testTarget(name: "MTPKitTests", dependencies: ["MTPKit"], swiftSettings: strictSwift),
        .testTarget(name: "ICCKitTests", dependencies: ["ICCKit", "DeviceAPI", "TransferCore"], swiftSettings: strictSwift),
        // Helper-to-worker frames and the worker-process DeviceConnector (with the stall watchdog).
        .target(name: "WorkerIPC", dependencies: ["DeviceAPI"], swiftSettings: strictSwift),

        // One phone's MTP session in its own process; the only code that loads libmtp in the app.
        .executableTarget(
            name: "pulli-mtp-worker",
            dependencies: ["WorkerIPC", "MTPKit", "DeviceAPI", "MockDevice"],
            swiftSettings: strictSwift
        ),

        // Runs a HelperEngine: in the background helper, or inside the app when the helper is not
        // installed. Also the simulated phone used without USB.
        .target(
            name: "PulliHost",
            dependencies: ["HelperCore", "WorkerIPC", "USBKit", "PulliProtocol", "PulliClient", "TransferCore", "DeviceAPI", "MockDevice", "ICCKit"],
            swiftSettings: strictSwift
        ),

        // The background helper: HelperEngine over XPC, phones through worker processes.
        .executableTarget(
            name: "pulli-helper",
            dependencies: ["PulliHost", "HelperCore", "WorkerIPC", "USBKit", "PulliProtocol", "PulliClient", "TransferCore", "DeviceAPI", "MockDevice"],
            swiftSettings: strictSwift
        ),

        // The SwiftUI app. Talks to the engine only through PulliClient; PulliHost starts an
        // in-process engine when the background helper is not running (docs/DECISIONS.md, D-021).
        .executableTarget(
            name: "Pulli",
            dependencies: pulliDependencies,
            resources: [.copy("Resources/Fonts"), .copy("Resources/Sounds")],
            swiftSettings: strictSwift
        ),

        .testTarget(
            name: "HelperCoreTests",
            dependencies: ["HelperCore", "PulliClient", "PulliProtocol", "TransferCore", "MockDevice", "DeviceAPI",
                           "WorkerIPC", "pulli-mtp-worker"],
            swiftSettings: strictSwift
        ),
        // Integration tests for the WebDAV source against Pulli's phone drive server.
        .testTarget(
            name: "PulliFinderLocationTests",
            dependencies: [
                .product(name: "RemoteFiles", package: "FinderLocations"),
                "HelperCore", "MockDevice", "DeviceAPI", "PulliClient", "PulliProtocol",
            ],
            swiftSettings: strictSwift
        ),
        // Pulli's File Provider extension: a phone in Finder's Locations (scripts/make-app.sh
        // bundles it as an .appex).
        // An extension has no main(): NSExtensionMain (Foundation) is its entry point, and the code
        // may only use extension-safe API.
        .executableTarget(
            name: "PulliFileProvider",
            dependencies: [
                "PulliProtocol",
                .product(name: "RemoteFiles", package: "FinderLocations"),
                .product(name: "RemoteFilesProvider", package: "FinderLocations"),
            ],
            swiftSettings: strictSwift,
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain", "-Xlinker", "-application_extension"])]
        ),

        // The shared SwiftUI views for the desktop widget. Used by PulliWidget and by the app
        // for --widget-snapshots.
        .target(name: "PulliWidgetViews", dependencies: ["PulliProtocol"], swiftSettings: strictSwift),

        // The desktop widget (a WidgetKit extension; scripts/make-app.sh bundles it as an .appex).
        // Like Xcode's widget targets, it starts in NSExtensionMain, which sets the extension up and
        // then calls the @main widget bundle. Starting at main directly trapped in
        // ExtensionFoundation (ExtensionMain.shared was never set): the widget never ran.
        .executableTarget(name: "PulliWidget", dependencies: ["PulliProtocol", "PulliWidgetViews"], swiftSettings: strictSwift,
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain", "-Xlinker", "-application_extension"])]),

        .testTarget(name: "PulliAppTests", dependencies: ["Pulli", "PulliClient", "PulliProtocol", "PulliWidgetViews"], swiftSettings: strictSwift),
        .testTarget(
            name: "TransferCoreTests",
            dependencies: ["TransferCore", "MockDevice", "DeviceAPI"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "PulliCLITests",
            dependencies: [
                "pulli-cli",
                "WorkerIPC",
                "USBKit",
                "DeviceAPI",
                "TransferCore",
                "MTPKit",
            ],
            swiftSettings: strictSwift
        ),
    ],
    swiftLanguageModes: [.v6]
)
