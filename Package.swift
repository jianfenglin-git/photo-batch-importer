// swift-tools-version: 5.10
// Native macOS build of Photo Importer — SwiftUI + Foundation, no Xcode
// project file. Produce the .app bundle via `Scripts/build_app.sh`.

import PackageDescription

let package = Package(
    name: "PhotoImporter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PhotoImporter",
            path: "Sources/PhotoImporter",
            // Embed Info.plist as a __TEXT,__info_plist section so the
            // executable is recognised as a Mac app binary by LaunchServices
            // when placed inside a .app bundle.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        ),
        // Background login item, nested inside the main app bundle at
        // Contents/Library/LoginItems/. Opens the main app when a card is
        // mounted — the only sandbox-legal way to get launch-on-insert.
        .executableTarget(
            name: "PhotoImporterHelper",
            path: "Sources/PhotoImporterHelper",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/HelperInfo.plist",
                ])
            ]
        ),
        .testTarget(
            name: "PhotoImporterTests",
            dependencies: ["PhotoImporter"],
            path: "Tests/PhotoImporterTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
