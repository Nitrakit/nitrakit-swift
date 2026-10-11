// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Nitrakit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "Nitrakit", targets: ["Nitrakit"]),
        .library(name: "NitrakitUI", targets: ["NitrakitUI"]),
    ],
    targets: [
        .binaryTarget(name: "NitrakitFFI", url: "https://github.com/Nitrakit/nitrakit-swift/releases/download/0.2.0/NitrakitFFI.xcframework.zip", checksum: "ddadc7a4eeaa59ee1fc8320032bcf8268a3163e61f4376d2b0a5dd68e0214b4a"),
        .target(name: "Nitrakit", dependencies: ["NitrakitFFI"]),
        .target(name: "NitrakitUI", dependencies: ["Nitrakit"]),
    ]
)
