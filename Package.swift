// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UsageHUD",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UsageHUDKit", targets: ["UsageHUDKit"]),
        .executable(name: "UsageHUD", targets: ["UsageHUD"]),
        // Installed as Contents/Helpers/usagehud: a distinct product name because UsageHUD and
        // usagehud would collide on a case-insensitive volume.
        .executable(name: "UsageHUDCLI", targets: ["UsageHUDCLI"]),
    ],
    dependencies: [
        // Sibling checkout: ~/dev/hudkit next to ~/dev/usagehud.
        .package(path: "../hudkit"),
    ],
    targets: [
        // Pure core: models, parsing, persistence. No AppKit UI; everything here is unit-tested.
        .target(
            name: "UsageHUDKit",
            path: "Sources/UsageHUDKit"
        ),
        .executableTarget(
            name: "UsageHUD",
            dependencies: ["UsageHUDKit", .product(name: "HUDKit", package: "hudkit")],
            path: "Sources/UsageHUD",
            // Bundle files, assembled into the .app by hudkit/scripts/hud-build.sh.
            exclude: ["Resources"]
        ),
        // `usagehud <command> [key=value ...]`: a thin client for the MacHUD control socket.
        .executableTarget(
            name: "UsageHUDCLI",
            dependencies: [.product(name: "HUDKit", package: "hudkit")],
            path: "Sources/UsageHUDCLI"
        ),
        .testTarget(
            name: "UsageHUDKitTests",
            dependencies: ["UsageHUDKit"],
            path: "Tests/UsageHUDKitTests"
        ),
        // Host logic in the app target and the shipped manifest/settings schema.
        .testTarget(
            name: "UsageHUDTests",
            dependencies: ["UsageHUD", "UsageHUDKit", .product(name: "HUDKit", package: "hudkit")],
            path: "Tests/UsageHUDTests"
        ),
    ]
)
