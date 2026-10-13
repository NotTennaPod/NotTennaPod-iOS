// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "NotTennaPodCore",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [.library(name: "NotTennaPodCore", targets: ["NotTennaPodCore"])],
    dependencies: [.package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.9")],
    targets: [
        .binaryTarget(name: "CFFmpegCodec", path: "Vendor/CFFmpegCodec.xcframework"),
        .target(name: "NativePCMTransport", cxxSettings: [
            .unsafeFlags(["-fobjc-arc", "-Wfunction-effects", "-Werror=function-effects"])
        ]),
        .target(name: "NotTennaPodCore", dependencies: ["SwiftSoup", "NativePCMTransport", "CFFmpegCodec"]),
        .testTarget(
            name: "NotTennaPodCoreTests",
            dependencies: ["NotTennaPodCore"],
            resources: [.copy("Fixtures")]
        )
    ],
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx17
)
