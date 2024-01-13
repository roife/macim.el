// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "MacIM",
  platforms: [.macOS(.v10_15)],
  products: [
    .library(
      name: "MacIM",
      type: .dynamic,
      targets: ["MacIM"]),
  ],
  dependencies: [
    .package(url: "https://github.com/SavchenkoValeriy/emacs-swift-module.git", branch: "main")
  ],
  targets: [
    .target(
      name: "MacIM",
      dependencies: [
        .product(name: "EmacsSwiftModule", package: "emacs-swift-module")
      ],
      plugins: [
        .plugin(name: "ModuleFactoryPlugin", package: "emacs-swift-module")
      ]),
  ]
)
