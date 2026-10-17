// swift-tools-version: 6.0
//
// MacDuoNext: the iPhone Duo depth effect for MacBook lids, drawn by a small
// Metal 3D engine and steered by head tracking.
//
// The .app bundle is assembled by scripts/build-release.sh; SwiftPM only
// produces the executables and the resource bundle.
//
// Targets, from the bottom up:
//
//   MacDuoNextLidKit   reads the lid hinge angle sensor (IOKit HID)
//   MacDuoNextCore     pure geometry and policy, no Apple frameworks, so it is
//                      tested anywhere: lid poses, angle prediction, the
//                      effect policy, eye estimation and the viewpoint
//   MacDuoNextEngine   the Metal engine: one kernel that casts a ray per pixel
//                      through the frosted glass to the left-behind screen
//   MacDuoNextVision   the camera and Vision face detector
//   MacDuoNextApp      the menu bar app that ties them together
//   MacDuoNextProbe    macduonext-lidprobe, a sensor diagnostic tool
import PackageDescription

let package = Package(
    name: "MacDuoNext",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacDuoNextApp", targets: ["MacDuoNextApp"]),
        .executable(name: "macduonext-lidprobe", targets: ["MacDuoNextProbe"]),
    ],
    targets: [
        .target(
            name: "MacDuoNextLidKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "MacDuoNextCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "MacDuoNextEngine",
            dependencies: ["MacDuoNextCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "MacDuoNextVision",
            dependencies: ["MacDuoNextCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MacDuoNextApp",
            dependencies: ["MacDuoNextLidKit", "MacDuoNextCore", "MacDuoNextEngine", "MacDuoNextVision"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MacDuoNextProbe",
            dependencies: ["MacDuoNextLidKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MacDuoNextCoreTests",
            dependencies: ["MacDuoNextCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MacDuoNextAppTests",
            dependencies: ["MacDuoNextApp"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
