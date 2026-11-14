// swift-tools-version: 5.9
// Swift Playgrounds app package (open S50FocusCheck.swiftpm in Swift Playgrounds on an iPad or iPhone, then tap Run).
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "S50 Focus Check",
    platforms: [.iOS("17.0")],
    products: [
        .iOSApplication(
            name: "S50 Focus Check",
            targets: ["AppModule"],
            bundleIdentifier: "local.s50focuscheck",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .leaf),          // change the icon in Swift Playgrounds app settings if you like
            accentColor: .presetColor(.blue),
            supportedDeviceFamilies: [.pad, .phone],
            supportedInterfaceOrientations: [.portrait, .landscapeRight, .landscapeLeft, .portraitUpsideDown(.when(deviceFamilies: [.pad]))],
            capabilities: [.photoLibrary(purposeString: "Checks which photos in the Checked list still exist, so deleted ones drop off. Read only; nothing leaves the iPad.")]
        )
    ],
    targets: [
        .executableTarget(name: "AppModule", path: ".")
    ]
)
