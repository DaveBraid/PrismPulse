// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PrismPulse",
    platforms: [.macOS("14.4")],
    products: [.executable(name: "PrismPulse", targets: ["PrismPulse"])],
    targets: [
        .target(name: "CPulseRing"),
        .target(name: "SpectrumCore", dependencies: ["CPulseRing"]),
        .executableTarget(name: "PrismPulse", dependencies: ["SpectrumCore", "CPulseRing"]),
        .executableTarget(name: "SpectrumCheck", dependencies: ["SpectrumCore"], path: "Tests/SpectrumCoreTests"),
    ],
    cLanguageStandard: .c11
)
