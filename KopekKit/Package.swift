// swift-tools-version: 6.0
// La ligne ci-dessus est lue par le compilateur : elle active le mode de langage Swift 6.
import PackageDescription

let package = Package(
    name: "KopekKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15), // permet `swift test` directement sur le Mac
    ],
    products: [
        .library(name: "KopekKit", targets: ["KopekKit"]),
    ],
    targets: [
        .target(name: "KopekKit"),
        .testTarget(name: "KopekKitTests", dependencies: ["KopekKit"]),
    ]
)
