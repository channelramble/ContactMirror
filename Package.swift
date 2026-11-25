// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ContactMirror",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ContactMirror", targets: ["ContactMirror"]),
    ],
    targets: [
        .target(
            name: "ObjCSupport",
            path: "Sources/ObjCSupport"
        ),
        .target(
            name: "ContactMirrorCore",
            dependencies: ["ObjCSupport"],
            path: "Sources/ContactMirrorCore"
        ),
        .executableTarget(
            name: "ContactMirror",
            dependencies: ["ContactMirrorCore"],
            path: "Sources/ContactMirror"
        ),
        .testTarget(
            name: "ContactMirrorCoreTests",
            dependencies: ["ContactMirrorCore"],
            path: "Tests/ContactMirrorCoreTests"
        ),
    ]
)
