// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PrismPulse",
    platforms: [.macOS("14.4")],
    products: [.executable(name: "PrismPulse", targets: ["PrismPulse"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
        .package(url: "https://github.com/2dubu/PaletteKit", exact: "2.2.0"),
    ],
    targets: [
        .target(name: "CPulseRing"),
        .target(name: "SpectrumCore", dependencies: ["CPulseRing", .product(name: "PaletteKit", package: "PaletteKit")]),
        .executableTarget(name: "PrismPulse",
                          dependencies: ["SpectrumCore", "CPulseRing", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "SpectrumCheck", dependencies: ["SpectrumCore"], path: "Tests/SpectrumCoreTests"),
    ],
    cLanguageStandard: .c11
)
