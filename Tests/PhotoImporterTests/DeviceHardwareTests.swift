import Testing
import Foundation
import ImageCaptureCore
@testable import PhotoImporter

/// End-to-end against a real, connected, unlocked iPhone (or PTP camera).
/// Skipped unless `PI_DEVICE_TEST=1`:
///
///     PI_DEVICE_TEST=1 swift test --filter DeviceHardware
///
/// Imports a small sample through the real watcher, catalog and
/// `DeviceImportSource`, then checks every file byte-for-byte against the
/// same file saved by ImageCaptureCore's own download (what Image Capture
/// does). Read-only on the device: nothing is deleted or written there.
@Suite("DeviceHardware", .serialized, .enabled(if: ProcessInfo.processInfo.environment["PI_DEVICE_TEST"] != nil))
@MainActor
struct DeviceHardwareTests {
    @Test(.timeLimit(.minutes(5)))
    func importSampleMatchesImageCaptureDownload() async throws {
        let watcher = CameraDeviceWatcher()
        watcher.start()
        var waited = 0
        while watcher.devices.isEmpty && waited < 200 {
            try await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        let device = try #require(watcher.devices.first, "no device connected")
        let catalog = try await watcher.loadCatalog(deviceID: device.id)
        #expect(!catalog.photos.isEmpty)

        // A mix that exercises every path, kept small (~tens of MB) so the
        // run stays quick over USB 2: Live Photos, plain stills, an edited
        // copy, and short videos.
        let byName = { (p: PhotoFile) in p.path.lastPathComponent.uppercased() }
        let live = catalog.photos.filter { p in p.companions.contains { $0.isLivePhotoVideo } }.prefix(3)
        let stillPool = catalog.photos.filter { $0.companions.isEmpty && !byName($0).hasSuffix(".MOV") && !byName($0).hasPrefix("IMG_E") }
            .sorted { $0.sizeBytes < $1.sizeBytes }
        let stills = stillPool.dropFirst(stillPool.count / 2).prefix(3)
        let edited = catalog.photos.filter { byName($0).hasPrefix("IMG_E") && !byName($0).hasSuffix(".MOV") }.prefix(1)
        // An original carrying its .AAE edit file.
        let withEdits = catalog.photos.filter { p in p.companions.contains { !$0.isLivePhotoVideo } }.prefix(2)
        let videos = catalog.photos.filter { (byName($0).hasSuffix(".MOV") || byName($0).hasSuffix(".MP4")) && $0.sizeBytes < 20_000_000 }.prefix(2)
        let sample = Array(live) + Array(stills) + Array(edited) + Array(videos)
            + withEdits.filter { p in !live.contains { $0.id == p.id } }
        #expect(!live.isEmpty, "expected at least one Live Photo on the device")
        #expect(!withEdits.isEmpty, "expected at least one photo with an .AAE on the device")

        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("pi-hw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let plan = ImportEngine.plan(
            photos: sample,
            rules: [CompiledRule(fileType: .all, segments: try Template.parse("{date:YYYY}/{date:YYYY-MM-DD}/IMG_{seq:000000}.{file.ext}"), backupFolder: nil)],
            destination: dest,
            cardLabel: catalog.deviceName,
            seqStart: 1
        )
        let source = catalog.importSource
        let options = ImportOptions(collisionPolicy: .skipSameHash, verify: true)
        let started = Date()
        var landed: [(src: URL, dst: URL)] = []
        let result = await Task.detached {
            ImportEngine.executePrimary(plan: plan, options: options, source: source) { p in
                if case .copied = p.outcome { landed.append((p.currentSrc, p.currentDst)) }
            }
        }.value
        let seconds = Date().timeIntervalSince(started)
        print("imported \(result.copied) files, \(plan.totalBytes) bytes in \(String(format: "%.1f", seconds))s → \(String(format: "%.1f", Double(plan.totalBytes) / seconds / 1e6)) MB/s")
        #expect(result.failed == 0, "failures: \(result.failures)")
        let companions = sample.reduce(0) { $0 + $1.companions.count }
        #expect(result.copied == sample.count + companions)
        #expect(result.verified == result.copied)

        // Every companion sits next to its photo: the Live Photo video as
        // <name>_live.MOV, an .AAE under the photo's exact name.
        for item in plan.items {
            for companion in item.companions {
                let landed = ImportEngine.companionDestination(for: item.dst, companion: companion)
                let stem = item.dst.deletingPathExtension().lastPathComponent
                let expected = stem + companion.suffix
                #expect(landed.deletingPathExtension().lastPathComponent == expected)
                #expect(FileManager.default.fileExists(atPath: landed.path), "\(landed.lastPathComponent) missing")
            }
        }
        print("companions: \(plan.items.flatMap { item in item.companions.map { ImportEngine.companionDestination(for: item.dst, companion: $0).lastPathComponent } })")

        // Byte-for-byte against ImageCaptureCore's own download.
        let reference = dest.appendingPathComponent("_reference")
        try FileManager.default.createDirectory(at: reference, withIntermediateDirectories: true)
        for (src, dst) in landed {
            let file = try #require(catalog.files[src.absoluteString])
            let saveAs = UUID().uuidString + "." + src.pathExtension
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                _ = file.requestDownload(options: [
                    .downloadsDirectoryURL: reference,
                    .saveAsFilename: saveAs,
                    .overwrite: true,
                ]) { _, error in
                    if let error { c.resume(throwing: error) } else { c.resume() }
                }
            }
            let ours = try Data(contentsOf: dst)
            let theirs = try Data(contentsOf: reference.appendingPathComponent(saveAs))
            #expect(ours == theirs, "\(src.lastPathComponent) differs from ImageCaptureCore's download")
            // Finder's Date Modified is the device's, not the import time.
            let modified = try FileManager.default.attributesOfItem(atPath: dst.path)[.modificationDate] as? Date
            let expected = file.fileModificationDate ?? file.modificationDate
            #expect(expected != nil && modified.map { abs($0.timeIntervalSince(expected!)) < 1 } == true,
                    "\(src.lastPathComponent): modified \(String(describing: modified)), device says \(String(describing: expected))")
        }

        // Importing again finds everything already there.
        var notSkipped: [String] = []
        let again = await Task.detached {
            ImportEngine.executePrimary(plan: plan, options: options, source: source) { p in
                switch p.outcome {
                case .skippedIdentical, .skippedExisting: break
                default: notSkipped.append("\(p.currentSrc.path) → \(p.currentDst.lastPathComponent): \(p.outcome)")
                }
            }
        }.value
        notSkipped.forEach { print("REIMPORT not skipped: \($0)") }
        #expect(again.copied == 0)
        #expect(again.skipped == result.copied)

        // Full metadata comes through for a camera shot (a Live Photo always
        // is one), and never moves the date.
        if let shot = live.first {
            let props = try #require(await catalog.metadata(for: shot.path))
            let merged = DeviceCatalog.merging(props, into: shot.meta)
            print("metadata: \(merged.cameraMake ?? "-") \(merged.cameraModel ?? "-") lens=\(merged.lens ?? "-") iso=\(merged.iso.map(String.init) ?? "-")")
            #expect(merged.cameraModel != nil)
            #expect(merged.date == shot.meta.date)
        }
        try? FileManager.default.removeItem(at: dest)
    }

    /// The same flow the window drives: select the device, preview names,
    /// gate on camera details for a `{camera.model}` template, import.
    @Test(.timeLimit(.minutes(5)))
    func viewModelImportsFromDevice() async throws {
        let formKey = "formState.v1", optionsKey = "options.v1"
        let savedForm = UserDefaults.standard.data(forKey: formKey)
        let savedOptions = CloudKVStore.shared.data(forKey: optionsKey)
        defer {
            UserDefaults.standard.set(savedForm, forKey: formKey)
            CloudKVStore.shared.set(savedOptions, forKey: optionsKey)
        }

        func waitUntil(_ what: String, seconds: Double = 60, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() {
                if Date() > deadline { Issue.record("timed out waiting for \(what)"); throw CancellationError() }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        let vm = AppViewModel.makeDefault()
        vm.rules = [
            TemplateRule(fileType: .all, template: "{date:YYYY-MM-DD}/IMG_{seq:000000}.{file.ext}"),
            TemplateRule(fileType: .raw, template: ""),
            TemplateRule(fileType: .video, template: ""),
        ]
        vm.collisionPolicy = .skipSameHash
        vm.verify = true
        vm.deleteAfter = true   // must be ignored for a device
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("pi-hw-vm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        vm.destination = try #require(FolderRef(url: dest))

        vm.startDeviceDiscovery()
        try await waitUntil("a device") { !vm.devices.isEmpty }
        vm.selectDevice(vm.devices[0])
        try await waitUntil("the catalog") { !vm.photos.isEmpty }
        #expect(vm.selectedDevice != nil)
        #expect(vm.sourceLabel == vm.devices[0].name)

        // Camera originals: a Live Photo saved from another app (renamed,
        // e.g. YAEU3241.JPG) legitimately has no camera model.
        let live = vm.photos.filter { p in
            p.companions.contains { $0.isLivePhotoVideo } && p.path.lastPathComponent.hasPrefix("IMG_")
                && p.path.pathExtension.uppercased() == "HEIC"
        }.prefix(2)
        let other = vm.photos.filter { $0.companions.isEmpty && $0.sizeBytes < 5_000_000 }.prefix(2)
        let picked = Array(live) + Array(other)
        vm.selectedPaths = Set(picked.map { $0.id })

        // Preview shows the Live Photo video next to its photo.
        try await waitUntil("destination preview") { picked.allSatisfy { vm.destinations[$0.id] != nil } }
        for p in live {
            let preview = try #require(vm.destinations[p.id])
            #expect(preview.contains("_live."), "preview: \(preview)")
        }

        // A camera-model template blocks import until the selected rows
        // have their details, then names folders by model.
        vm.rules[0].template = "{camera.model}/IMG_{seq:000000}.{file.ext}"
        try await waitUntil("metadata gate to engage", seconds: 5) { vm.awaitingDeviceMetadata || vm.deviceMetadataProgress != nil }
        #expect(!vm.canImport || !vm.awaitingDeviceMetadata)
        try await waitUntil("selected rows' metadata", seconds: 30) { !vm.awaitingDeviceMetadata }
        try await waitUntil("model in preview") { live.allSatisfy { vm.destinations[$0.id]?.hasPrefix("unknown") == false } }
        print("camera-model preview: \(live.compactMap { vm.destinations[$0.id] })")
        // Switching back cancels the rest of the background read.
        vm.rules[0].template = "{date:YYYY-MM-DD}/IMG_{seq:000000}.{file.ext}"
        try await waitUntil("metadata read to stop", seconds: 5) { vm.deviceMetadataProgress == nil }
        try await waitUntil("preview with date template") { picked.allSatisfy { vm.destinations[$0.id]?.hasPrefix("20") == true } }

        #expect(vm.canImport)
        vm.startImport()
        try await waitUntil("import to finish", seconds: 120) { !vm.importing && vm.importResult != nil }
        let result = try #require(vm.importResult)
        #expect(result.primary.failed == 0, "failures: \(result.primary.failures)")
        #expect(result.primary.copied == picked.count + picked.reduce(0) { $0 + $1.companions.count })
        #expect(result.primary.verified == result.primary.copied)
        #expect(vm.deleteConfirm == nil, "delete-after must not apply to a device")

        let written = try FileManager.default.subpathsOfDirectory(atPath: dest.path).filter { !$0.hasSuffix("/") && $0.contains(".") }
        print("written: \(written.sorted())")
        #expect(written.filter { $0.contains("_live.") }.count == live.count)
        try? FileManager.default.removeItem(at: dest)
    }
}
