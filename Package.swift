// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Workday",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "QS668Core", targets: ["QS668Core"]),
    .library(name: "WorkdayMac", targets: ["WorkdayMac"]),
    .executable(name: "Workday", targets: ["WorkdayLauncher"]),
  ],
  targets: [
    .target(name: "QS668Core"),
    // Only the two macOS static binaries are needed for on-device speaker inference.
    .binaryTarget(
      name: "SherpaOnnxMacOS",
      url:
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v2.0.1-macos-static.xcframework.zip",
      checksum: "3c378789ebcbf3b1fb2e7cf0c58dae8e5629001598148aee2edd4494dc939a27"),
    .binaryTarget(
      name: "OnnxruntimeMacOS",
      url:
        "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.28.1/onnxruntime-macos-static-xcframework-1.28.1.xcframework.zip",
      checksum: "38c9a1e8bcf2497ff5eb721195743e4b4367ade3cd1eb9869c0cfd1bd367c36b"),
    .target(
      name: "WorkdayCore",
      dependencies: [
        "QS668Core",
        "SherpaOnnxMacOS", "OnnxruntimeMacOS",
      ],
      resources: [.copy("Resources/campplus.onnx"), .copy("Resources/silero_vad.onnx")],
      linkerSettings: [
        .linkedLibrary("c++"), .linkedFramework("CoreML"), .linkedFramework("Accelerate"),
      ]),
    .target(
      name: "WorkdayMac",
      dependencies: ["WorkdayCore", "QS668Core"],
      resources: [.copy("Resources/DockArtwork")]),
    .executableTarget(
      name: "WorkdayLauncher", dependencies: ["WorkdayMac"], path: "WorkRecorder",
      exclude: ["Assets.xcassets"]),
    .testTarget(name: "QS668CoreTests", dependencies: ["QS668Core"]),
    .testTarget(
      name: "WorkdayCoreTests",
      dependencies: ["WorkdayCore", "QS668Core"]),
    .testTarget(name: "WorkdayMacTests", dependencies: ["WorkdayMac"]),
  ],
  swiftLanguageModes: [.v5]
)
