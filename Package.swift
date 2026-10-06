// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LinglongtaiHUD",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "LinglongtaiHUD", targets: ["LinglongtaiHUD"]),
        .executable(name: "linglongtaictl", targets: ["LinglongtaiCtl"]),
        .executable(name: "linglongtai-acceptance", targets: ["LinglongtaiAcceptance"])
    ],
    targets: [
        .target(
            name: "LinglongtaiShared"
        ),
        .executableTarget(
            name: "LinglongtaiHUD",
            dependencies: ["LinglongtaiShared"]
        ),
        .executableTarget(
            name: "LinglongtaiCtl",
            dependencies: ["LinglongtaiShared"]
        ),
        .executableTarget(
            name: "LinglongtaiAcceptance",
            dependencies: ["LinglongtaiShared"]
        )
    ]
)
