// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "SMBClient",
  platforms: [
    .macOS(.v10_15),
    .iOS(.v13),
    .visionOS(.v1)
  ],
  products: [
    .library(
      name: "SMBClient",
      targets: ["SMBClient"]
    ),
  ],
  targets: [
    .target(
      name: "SMBClient",
      // library evolution support 를 활성화한다
      swiftSettings: [
              .unsafeFlags(["-enable-library-evolution"])
          ]
    ),
    .testTarget(
      name: "SMBClientTests",
      dependencies: ["SMBClient"],
      resources: [.copy("Fixtures")]
    ),
  ]
)
