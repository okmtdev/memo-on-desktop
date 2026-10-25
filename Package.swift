// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MemoOnDesktop",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MemoOnDesktop", targets: ["MemoOnDesktop"])
    ],
    targets: [
        .executableTarget(name: "MemoOnDesktop")
    ]
)
