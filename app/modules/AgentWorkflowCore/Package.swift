// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "AgentWorkflowCore",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(
      name: "AgentWorkflowCore",
      targets: ["AgentWorkflowCore"]
    ),
    .library(
      name: "AgentWorkflowJiraCLI",
      targets: ["AgentWorkflowJiraCLI"]
    ),
    .library(
      name: "AgentWorkflowLinear",
      targets: ["AgentWorkflowLinear"]
    )
  ],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift", from: "6.24.0")
  ],
  targets: [
    .target(
      name: "AgentWorkflowCore",
      dependencies: [
        .product(name: "GRDB", package: "GRDB.swift")
      ],
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .target(
      name: "AgentWorkflowJiraCLI",
      dependencies: ["AgentWorkflowCore"],
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .testTarget(
      name: "AgentWorkflowCoreTests",
      dependencies: ["AgentWorkflowCore"],
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .target(
      name: "AgentWorkflowLinear",
      dependencies: ["AgentWorkflowCore"],
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .testTarget(
      name: "AgentWorkflowJiraCLITests",
      dependencies: ["AgentWorkflowJiraCLI"],
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .testTarget(
      name: "AgentWorkflowLinearTests",
      dependencies: ["AgentWorkflowLinear"],
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    )
  ]
)
