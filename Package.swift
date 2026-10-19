// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacToys",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(name: "MacToys", linkerSettings: [
            .linkedFramework("AppKit"), .linkedFramework("ApplicationServices"),
            .linkedFramework("IOKit"), .linkedFramework("ServiceManagement")
        ]),
        .testTarget(name: "MacToysTests", dependencies: ["MacToys"])
    ],
    swiftLanguageModes: [.v5]
)
