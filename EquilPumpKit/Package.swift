// swift-tools-version:5.9
import PackageDescription

// EquilPumpKit：微泰 Equil 泵的 Trio/LoopKit 泵驱动层。
//
// 依赖：
// - EquilKit：协议层（命令、AES、链路状态机、Core Bluetooth 传输）。
// - LoopKit：泵抽象接口（PumpManager）、剂量模型与存储。
// - LoopKitUI：向导/设置界面所需的 PumpManagerUI / HUDProvider / 颜色与环境。
//
// 说明：LoopKit 在 Trio 中通过 Xcode 子工程集成（本目录旁的 ../LoopKit）。
// 这里用本地路径依赖是为了能在 Mac 上单独 `swift build` 验证本驱动层；
// 真正接入 Trio 时用同目录下的 EquilPumpKit.xcodeproj（按 MedtrumKit 的方式
// 加入 Trio.xcworkspace），并在 DeviceCatalog.pumps 登记 EquilPumpManager 即可。
let package = Package(
    name: "EquilPumpKit",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(name: "EquilPumpKit", targets: ["EquilPumpKit"]),
        .library(name: "EquilPumpKitUI", targets: ["EquilPumpKitUI"])
    ],
    dependencies: [
        .package(path: "../EquilKit"),
        .package(path: "../LoopKit")
    ],
    targets: [
        .target(
            name: "EquilPumpKit",
            dependencies: [
                "EquilKit",
                .product(name: "LoopKit", package: "LoopKit")
            ],
            path: "EquilPumpKit"
        ),
        .target(
            name: "EquilPumpKitUI",
            dependencies: [
                "EquilPumpKit",
                "EquilKit",
                .product(name: "LoopKit", package: "LoopKit"),
                .product(name: "LoopKitUI", package: "LoopKit")
            ],
            path: "EquilPumpKitUI"
        )
    ]
)