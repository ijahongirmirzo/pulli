// swift-tools-version: 6.2
import PackageDescription

let strictSwift: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "FinderLocations",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RemoteFiles", targets: ["RemoteFiles"]),
        .library(name: "RemoteFilesProvider", targets: ["RemoteFilesProvider"]),
        .library(name: "FinderLocations", targets: ["FinderLocations"]),
    ],
    targets: [
        .target(
            name: "RemoteFiles",
            swiftSettings: strictSwift
        ),
        .target(
            name: "RemoteFilesProvider",
            dependencies: ["RemoteFiles"],
            swiftSettings: strictSwift
        ),
        .target(
            name: "FinderLocations",
            dependencies: ["RemoteFiles"],
            swiftSettings: strictSwift
        ),
        .testTarget(
            name: "FinderLocationsTests",
            dependencies: ["FinderLocations", "RemoteFiles", "RemoteFilesProvider"],
            swiftSettings: strictSwift
        ),
    ],
    swiftLanguageModes: [.v6]
)
