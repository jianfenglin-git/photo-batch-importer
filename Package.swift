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
        // Tests use `swift-testing`, which ships with Xcode but NOT with the
        // plain Command Line Tools. If you want to run tests, install Xcode
        // and re-enable this target — the test sources under
        // Tests/PhotoImporterTests stay in the tree either way.
        //
        // .testTarget(
        //     name: "PhotoImporterTests",
        //     dependencies: ["PhotoImporter"],
        //     path: "Tests/PhotoImporterTests",
        //     resources: [.copy("Fixtures")]
        // ),
    ]
)
