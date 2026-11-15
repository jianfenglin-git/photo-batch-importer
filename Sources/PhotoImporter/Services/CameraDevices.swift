import Foundation
import ImageCaptureCore
import os

// iPhones, iPads and USB cameras in PTP mode never mount as a volume — macOS
// talks to them over ImageCaptureCore, the framework behind Image Capture.
// This file is everything device-specific: discovery and sessions
// (`CameraDeviceWatcher`), the mapping from the device's catalog to the same
// `PhotoFile` rows a card produces (`DeviceCatalog`, kept free of
// ImageCaptureCore so it's unit-testable), and a byte reader the import engine
// streams from (`DeviceImportSource`). Planning, naming, collision handling,
// verify and backup are the card code paths, unchanged.
//
// Sandbox: ImageCaptureCore only sees devices when the app holds
// `com.apple.security.device.usb`. Without it the browser silently finds
// nothing (`com.apple.security.device.camera` doesn't help — that's for
// AVFoundation capture).

// MARK: - Catalog mapping (pure)

/// One file on a connected device, copied out of ImageCaptureCore so the
/// mapping to `PhotoFile`s can be tested without hardware.
struct DeviceFileInfo: Hashable {
    /// Folder path on the device, e.g. `DCIM/202508_a`.
    var folderPath: String
    var name: String
    var sizeBytes: Int64
    /// When the device says the photo or video was taken. For an iPhone this
    /// is the date Photos shows; it matches EXIF `DateTimeOriginal` for
    /// camera shots and is also right for screenshots and saved images,
    /// which have no EXIF date at all.
    var captureDate: Date?
    var modificationDate: Date?
    /// Files the device attaches to this one: a Live Photo's video, `.AAE`
    /// edit instructions, or a camera's RAW half of a RAW+JPEG pair.
    var sidecars: [DeviceFileInfo] = []
}

enum DeviceCatalog {
    /// URL scheme for files on a device: `icdevice://<device-id>/DCIM/…`.
    /// Not `file://` on purpose, so nothing can mistake one for a local path.
    static let scheme = "icdevice"

    static func url(deviceID: String, file: DeviceFileInfo) -> URL? {
        var encoded: [String] = []
        for part in file.folderPath.split(separator: "/").map(String.init) + [file.name] {
            // `/` is legal in `.urlPathAllowed`; a name containing one must
            // not become an extra path level.
            guard let e = part.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)?
                .replacingOccurrences(of: "/", with: "%2F")
            else { return nil }
            encoded.append(e)
        }
        var c = URLComponents()
        c.scheme = scheme
        c.host = deviceID
        c.percentEncodedPath = "/" + encoded.joined(separator: "/")
        return c.url
    }

    /// Turn a device's media list into the rows the app shows and imports.
    ///
    /// - Every file with a known photo/video extension becomes a row.
    /// - A still's video sidecar is its Live Photo video. It is not a row of
    ///   its own: it rides along as a companion and lands as
    ///   `<photo name>_live.<ext>` (see `CompanionFile`).
    /// - Image sidecars the device doesn't also list on their own (a camera's
    ///   RAW behind its JPEG) become rows, and `ImportEngine.plan` pairs them
    ///   with the JPEG by stem exactly as it does on a card.
    /// - `.AAE` edit sidecars ride along too, under the photo's own name
    ///   (`FileType.sidecarExtensions`).
    /// - Other sidecars (`.XMP`, `.THM`) are skipped, as on a card.
    static func photos(from files: [DeviceFileInfo], deviceID: String) -> [PhotoFile] {
        func ext(_ f: DeviceFileInfo) -> String { (f.name as NSString).pathExtension.lowercased() }
        func isStill(_ f: DeviceFileInfo) -> Bool {
            FileType.jpgExtensions.contains(ext(f)) || FileType.rawExtensions.contains(ext(f))
        }
        func isVideo(_ f: DeviceFileInfo) -> Bool { FileType.videoExtensions.contains(ext(f)) }
        func isSidecar(_ f: DeviceFileInfo) -> Bool { FileType.sidecarExtensions.contains(ext(f)) }
        func liveVideo(of f: DeviceFileInfo) -> DeviceFileInfo? {
            isStill(f) ? f.sidecars.first(where: isVideo) : nil
        }

        // A Live Photo video is imported once, as its photo's companion, even
        // if a device also lists it as a top-level file.
        var claimed: Set<String> = []
        for f in files {
            if let video = liveVideo(of: f), let u = url(deviceID: deviceID, file: video) {
                claimed.insert(u.absoluteString)
            }
        }

        var seen: Set<String> = []
        var rows: [PhotoFile] = []
        func addRow(_ f: DeviceFileInfo) -> Int? {
            guard FileType.allKnownExtensions.contains(ext(f)),
                  let u = url(deviceID: deviceID, file: f),
                  !claimed.contains(u.absoluteString),
                  seen.insert(u.absoluteString).inserted
            else { return nil }
            rows.append(PhotoFile(path: u, sizeBytes: f.sizeBytes, meta: placeholderMeta(f)))
            return rows.count - 1
        }

        for f in files {
            guard let row = addRow(f) else { continue }
            if let video = liveVideo(of: f), let u = url(deviceID: deviceID, file: video) {
                rows[row].companions.append(CompanionFile(
                    path: u,
                    sizeBytes: video.sizeBytes,
                    suffix: CompanionFile.livePhotoSuffix
                ))
            }
            let photoStem = (f.name as NSString).deletingPathExtension
            for sidecar in f.sidecars where isSidecar(sidecar) {
                guard let u = url(deviceID: deviceID, file: sidecar) else { continue }
                rows[row].companions.append(CompanionFile(
                    path: u,
                    sizeBytes: sidecar.sizeBytes,
                    suffix: CompanionFile.sidecarSuffix(
                        photoStem: photoStem,
                        sidecarStem: (sidecar.name as NSString).deletingPathExtension
                    )
                ))
            }
            rows[row].companions = CompanionFile.uniquified(rows[row].companions)
            for sidecar in f.sidecars where isStill(sidecar) {
                _ = addRow(sidecar)
            }
        }
        return rows
    }

    /// Metadata available straight from the catalog: just the date. Camera,
    /// lens and exposure fields arrive later via `merging(_:into:)`, and only
    /// when a template asks for them.
    static func placeholderMeta(_ f: DeviceFileInfo) -> PhotoMeta {
        PhotoMeta(
            date: f.captureDate ?? f.modificationDate,
            cameraMake: nil, cameraModel: nil, cameraSerial: nil, cameraOwner: nil,
            lens: nil,
            iso: nil, shutter: nil, aperture: nil, focalLength: nil,
            subSecond: nil,
            fromExif: false
        )
    }

    /// Fold an ImageCaptureCore metadata dictionary into a row's metadata.
    /// The date stays the device's capture date, so fetching details never
    /// moves a photo to a different date folder.
    static func merging(_ properties: [String: Any], into current: PhotoMeta) -> PhotoMeta {
        var merged = PhotoScanner.meta(fromProperties: properties, fallbackDate: current.date)
        if let date = current.date { merged.date = date }
        return merged
    }

    /// Template tokens whose values only exist in the full EXIF metadata,
    /// which costs one request per file on a device (~50 files/s on an
    /// iPhone). Dates, names, sequence and source label don't need it.
    static func needsFullMetadata(_ token: TemplateToken) -> Bool {
        switch token {
        case .cameraMake, .cameraModel, .cameraSerial, .cameraOwner,
             .lens, .iso, .shutter, .aperture, .focalLength, .subSecond:
            return true
        case .date, .time, .seq, .fileStem, .fileExt, .fileName, .cardLabel:
            return false
        }
    }
}

// MARK: - Errors + liveness

enum CameraDeviceError: LocalizedError {
    case disconnected
    case fileMissing
    case timedOut
    case readFailed(String)
    case moreDataThanReported
    case notResponding(String)

    var errorDescription: String? {
        switch self {
        case .disconnected:
            return "The device was disconnected."
        case .fileMissing:
            return "This file is no longer on the device."
        case .timedOut:
            return "The device stopped responding."
        case .readFailed(let message):
            return "read failed: \(message)"
        case .notResponding(let name):
            return "Couldn’t read “\(name)”. Make sure it’s unlocked and click it again, or unplug it and plug it back in."
        case .moreDataThanReported:
            // An iPhone set to convert photos on transfer can serve a file of
            // a different length than it lists. Fail rather than keep a
            // truncated copy.
            return "the device sent more data than the file size it reported. On an iPhone, set Settings ▸ Apps ▸ Photos ▸ Transfer to Mac or PC to Keep Originals."
        }
    }
}

/// "Is the device still attached", readable from the import thread, so a
/// pulled cable fails the remaining files at once instead of each one
/// waiting out a read timeout.
final class DeviceLiveness: @unchecked Sendable {
    private let lock = NSLock()
    private var alive = true

    var isAlive: Bool {
        lock.lock(); defer { lock.unlock() }
        return alive
    }

    func markGone() {
        lock.lock(); alive = false; lock.unlock()
    }
}

/// Holds the result of an asynchronous ImageCaptureCore request so a
/// blocking caller can pick it up after a semaphore wait, and makes sure a
/// continuation resumed by either a completion or a timeout resumes once.
private final class OneShot<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var claimed = false

    /// True for exactly one caller.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }

    func set(_ v: Value) {
        lock.lock(); value = v; lock.unlock()
    }

    func get() -> Value? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

// MARK: - Catalog handle

/// A loaded device catalog: the rows to show plus the ImageCaptureCore file
/// objects behind them, for reading bytes and metadata. Immutable after
/// creation; ImageCaptureCore's request methods are safe to call from any
/// thread and complete on a queue of their own.
final class DeviceCatalogHandle: @unchecked Sendable {
    let deviceID: String
    let deviceName: String
    let photos: [PhotoFile]
    let liveness: DeviceLiveness
    /// Keyed by `PhotoFile.path.absoluteString` (companions included).
    let files: [String: ICCameraFile]

    fileprivate init(deviceID: String, deviceName: String, photos: [PhotoFile], files: [String: ICCameraFile], liveness: DeviceLiveness) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.photos = photos
        self.files = files
        self.liveness = liveness
    }

    var importSource: DeviceImportSource {
        DeviceImportSource(files: files, liveness: liveness)
    }

    /// The device's metadata dictionary for one file (`{Exif}`, `{TIFF}`, …),
    /// or nil if it has none or doesn't answer within `timeout`.
    func metadata(for url: URL, timeout: TimeInterval = 15) async -> [String: Any]? {
        guard liveness.isAlive, let file = files[url.absoluteString] else { return nil }
        return await withCheckedContinuation { continuation in
            let once = OneShot<Void>()
            file.requestMetadataDictionary(options: nil) { dict, error in
                guard once.claim() else { return }
                guard error == nil, let dict else {
                    continuation.resume(returning: nil)
                    return
                }
                var out: [String: Any] = [:]
                for (key, value) in dict {
                    if let k = key as? String { out[k] = value }
                }
                continuation.resume(returning: out)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }
}

// MARK: - Import source

/// Streams file bytes off a device with `requestReadData`, into the same
/// copy/hash/verify loop a card uses. Reading ourselves (rather than letting
/// ImageCaptureCore download to a folder) keeps every write inside the
/// sandbox-granted destination and gives the engine the bytes to hash as
/// they stream.
final class DeviceImportSource: ImportSource, @unchecked Sendable {
    /// Per-request size. An iPhone over USB 2 sustains ~29 MB/s at 8 MB;
    /// much smaller requests pay per-request latency, and 16 MB requests
    /// were seen to fail.
    static let chunkSize: UInt64 = 8 << 20
    static let requestTimeout: TimeInterval = 60

    private let files: [String: ICCameraFile]
    private let liveness: DeviceLiveness

    init(files: [String: ICCameraFile], liveness: DeviceLiveness) {
        self.files = files
        self.liveness = liveness
    }

    func exists(_ url: URL) -> Bool {
        liveness.isAlive && files[url.absoluteString] != nil
    }

    func size(of url: URL) -> UInt64? {
        files[url.absoluteString].map { UInt64(max(0, $0.fileSize)) }
    }

    func dates(of url: URL) -> SourceDates {
        guard let file = files[url.absoluteString] else { return SourceDates() }
        return SourceDates(
            created: file.fileCreationDate ?? file.creationDate,
            modified: file.fileModificationDate ?? file.modificationDate
        )
    }

    func open(_ url: URL) throws -> SourceReader {
        guard liveness.isAlive else { throw CameraDeviceError.disconnected }
        guard let file = files[url.absoluteString] else { throw CameraDeviceError.fileMissing }
        return DeviceSourceReader(file: file, liveness: liveness)
    }
}

final class DeviceSourceReader: SourceReader {
    let length: UInt64
    private let file: ICCameraFile
    private let liveness: DeviceLiveness
    private var offset: UInt64 = 0
    private var checkedEnd = false

    fileprivate init(file: ICCameraFile, liveness: DeviceLiveness) {
        self.file = file
        self.liveness = liveness
        self.length = UInt64(max(0, file.fileSize))
    }

    func read() throws -> Data {
        if offset >= length {
            if !checkedEnd {
                checkedEnd = true
                try assertNothingPastEnd()
            }
            return Data()
        }
        let count = min(DeviceImportSource.chunkSize, length - offset)
        let data = try readChunk(at: offset, count: count, timeout: DeviceImportSource.requestTimeout)
        offset += UInt64(data.count)
        // An empty chunk before `length` ends the stream; the copy loop then
        // reports it as a short read.
        return data
    }

    func close() {}

    /// The copy loop trusts `length` (the size the device listed). If the
    /// device would actually serve more — an iPhone converting HEIC on the
    /// fly — stopping at `length` would keep a silently truncated file, so
    /// ask for one byte past the end. A device answers that with an error,
    /// which is the expected outcome.
    private func assertNothingPastEnd() throws {
        guard liveness.isAlive else { throw CameraDeviceError.disconnected }
        if let extra = try? readChunk(at: length, count: 1, timeout: 15), !extra.isEmpty {
            throw CameraDeviceError.moreDataThanReported
        }
    }

    private func readChunk(at offset: UInt64, count: UInt64, timeout: TimeInterval) throws -> Data {
        guard liveness.isAlive else { throw CameraDeviceError.disconnected }
        let box = OneShot<(Data?, Error?)>()
        let done = DispatchSemaphore(value: 0)
        file.requestReadData(atOffset: off_t(offset), length: off_t(count)) { data, error in
            box.set((data, error))
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            throw liveness.isAlive ? CameraDeviceError.timedOut : CameraDeviceError.disconnected
        }
        let (data, error) = box.get() ?? (nil, nil)
        if let error {
            throw liveness.isAlive
                ? CameraDeviceError.readFailed(error.localizedDescription)
                : CameraDeviceError.disconnected
        }
        return data ?? Data()
    }
}

// MARK: - Discovery + sessions

/// A connected device as the UI sees it.
struct CameraDevice: Identifiable, Hashable {
    enum Status: Hashable {
        /// Listed; nothing has been asked of it yet.
        case idle
        case connecting
        /// Passcode-locked; the message is ImageCaptureCore's
        /// ("Please unlock “iPhone”").
        case locked(String)
        /// Catalog loaded with this many photos/videos.
        case ready(Int)
        /// Catalog loaded empty right after the device said it was locked: a
        /// phone plugged in while locked hides its photos until it's unlocked
        /// (they then arrive on their own — see `catalogRevision`).
        case hidden
        /// Unlocked, but the device keeps serving an empty photo list. Seen
        /// after an iPhone had been locked for a long time: on unlock it
        /// resets its storage and re-lists it as empty, and only a re-plug
        /// makes it list its photos again (ptpcamerad logs
        /// `AssetGroup | Received: 0`). The view model re-selects the device
        /// when it comes back.
        case needsReplug
        case failed(String)
    }

    var id: String
    var name: String
    /// SF Symbol the system suggests for it (`iphone`, `ipad`, `camera`).
    var symbolName: String
    var status: Status
}

/// Lists connected iPhones, iPads and PTP cameras, opens sessions on demand,
/// and hands out catalogs. Cameras that also mount as a volume (mass-storage
/// mode) are left to `VolumeWatcher`, so nothing is listed twice.
@MainActor
final class CameraDeviceWatcher: NSObject, ObservableObject {
    @Published private(set) var devices: [CameraDevice] = []
    /// Bumped when a loaded device's contents change (photos appearing after
    /// an unlock, or taken/deleted while connected). The view model reloads
    /// the selected device's list when its entry moves.
    @Published private(set) var catalogRevision: [String: Int] = [:]

    private let browser = ICDeviceBrowser()
    private var started = false
    private var cameras: [String: ICCameraDevice] = [:]
    private var liveness: [String: DeviceLiveness] = [:]
    private var catalogReady: Set<String> = []
    private var catalogWaiters: [String: [CheckedContinuation<Void, Error>]] = [:]

    // Connection supervision. A passcode-locked iPhone refuses the session
    // (-9943), and after the user unlocks it ImageCaptureCore does not
    // reliably say so, nor finish the half-open session — the app sat on
    // "Please unlock" forever, and a second click waited forever on
    // "Connecting…" because the session already counted as open. So while
    // anyone waits on a catalog, a 1 s poll watches the device itself and
    // starts a fresh session once it's unlocked or stalled.
    private var pollTimer: Timer?
    /// Last open attempt or sign of catalog progress, per device.
    private var lastActivity: [String: Date] = [:]
    private var lastCatalogPercent: [String: Int] = [:]
    /// When the device was first seen unlocked while we still show it locked.
    private var unlockedSince: [String: Date] = [:]
    /// When the device last reported being unlocked during this attempt.
    private var unlockedAt: [String: Date] = [:]
    private var automaticReopens: [String: Int] = [:]
    /// Devices whose session we closed on purpose, to open a fresh one.
    private var reopenAfterClose: Set<String> = []
    /// Devices that answered the current connection attempt with "locked".
    private var sawPasscodeLock: Set<String> = []
    /// Devices whose catalog came back empty while locked: their media count
    /// is watched so the list can fill in once photos appear.
    private var watchedCounts: [String: (count: Int, stableTicks: Int)] = [:]

    private static let log = Logger(subsystem: "com.jianfenglin.photoimporter", category: "devices")
    /// Seconds without progress before a fresh session is tried, and how
    /// many automatic tries before giving up with an error.
    private static let stallSeconds: TimeInterval = 15
    private static let maxAutomaticReopens = 2
    /// Every connection starts with a "please unlock" answer for a few dozen
    /// milliseconds — even from an unlocked phone. Only show it if it lasts.
    private static let lockedGraceSeconds: TimeInterval = 1.5
    /// After an unlock the photo list normally follows within a second. This
    /// long with nothing means the phone is in the empty-after-unlock state.
    private static let replugAfterUnlockSeconds: TimeInterval = 6

    /// ImageCaptureCore holds its delegates unretained (`assign`): a device
    /// callback arriving after this object is gone messages freed memory
    /// (seen as a crash in -[ICDeviceBrowser removeDevice:moreGoing:] once a
    /// test's watcher had been released). Detach before going away — but
    /// don't `stop()` the browser: that ends device browsing for the whole
    /// process, so a later watcher never sees the device. The app keeps one
    /// watcher for its whole life; tests make several.
    deinit {
        browser.delegate = nil
        for camera in cameras.values {
            camera.delegate = nil
        }
        pollTimer?.invalidate()
    }

    /// Begin browsing. Called once the UI is up rather than at init, so
    /// tests that build an `AppViewModel` don't start talking to hardware.
    func start() {
        guard !started else { return }
        started = true
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        ) ?? .camera
        browser.start()
    }

    /// Open a session if needed and wait for the device's complete catalog.
    /// While the device is passcode-locked this keeps waiting (its status
    /// reads `.locked`) and finishes once it's unlocked; it throws if the
    /// device goes away or refuses the session.
    func loadCatalog(deviceID: String) async throws -> DeviceCatalogHandle {
        guard let camera = cameras[deviceID] else { throw CameraDeviceError.disconnected }
        // A click on a device that loaded empty while locked: connect afresh.
        if catalogReady.contains(deviceID), sawPasscodeLock.contains(deviceID),
           camera.mediaFiles?.isEmpty ?? true {
            catalogReady.remove(deviceID)
        }
        // The session can already be open with its catalog complete (opened
        // earlier, or by another browser in this process), in which case the
        // "became ready" callback has come and gone and won't repeat.
        if !catalogReady.contains(deviceID), Self.catalogLooksComplete(camera) {
            catalogReady.insert(deviceID)
        }
        if !catalogReady.contains(deviceID) {
            // A click while an earlier attempt is still pending — or on a
            // session that's open without a catalog — is a retry: start over
            // with a fresh session rather than wait on the old one.
            let retry = catalogWaiters[deviceID] != nil || camera.hasOpenSession
            automaticReopens[deviceID] = 0
            unlockedSince.removeValue(forKey: deviceID)
            unlockedAt.removeValue(forKey: deviceID)
            sawPasscodeLock.remove(deviceID)
            setStatus(.connecting, for: deviceID)
            if retry {
                reopenSession(camera, id: deviceID, reason: "retry")
            } else {
                openSession(camera, id: deviceID)
            }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                catalogWaiters[deviceID, default: []].append(c)
                startPolling()
            }
        }
        guard let camera = cameras[deviceID], let alive = liveness[deviceID] else {
            throw CameraDeviceError.disconnected
        }

        var lookup: [String: ICCameraFile] = [:]
        func info(_ file: ICCameraFile) -> DeviceFileInfo {
            let sidecars = (file.sidecarFiles ?? []).compactMap { $0 as? ICCameraFile }
            let i = DeviceFileInfo(
                folderPath: Self.folderPath(of: file),
                name: file.name ?? "",
                sizeBytes: Int64(file.fileSize),
                captureDate: file.creationDate ?? file.exifCreationDate ?? file.fileCreationDate,
                modificationDate: file.modificationDate ?? file.fileModificationDate,
                sidecars: sidecars.map(info)
            )
            if let u = DeviceCatalog.url(deviceID: deviceID, file: i) {
                lookup[u.absoluteString] = file
            }
            return i
        }
        let media = (camera.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        let infos = media.map(info)
        let photos = DeviceCatalog.photos(from: infos, deviceID: deviceID)
        if media.isEmpty && (sawPasscodeLock.contains(deviceID) || camera.isAccessRestrictedAppleDevice) {
            setStatus(.hidden, for: deviceID)
            watchedCounts[deviceID] = (0, 0)
            startPolling()
        } else {
            watchedCounts.removeValue(forKey: deviceID)
            setStatus(.ready(photos.count), for: deviceID)
        }
        return DeviceCatalogHandle(
            deviceID: deviceID,
            deviceName: name(of: deviceID),
            photos: photos,
            files: lookup,
            liveness: alive
        )
    }

    /// The delegate-reporting open. Kept out of async functions, where Swift
    /// would otherwise pick the SDK's `async` overload — which reports a
    /// passcode lock as a thrown error instead of waiting for the unlock.
    private func openSession(_ camera: ICCameraDevice, id: String) {
        Self.log.notice("open session \(id, privacy: .public)")
        lastActivity[id] = Date()
        camera.requestOpenSession()
    }

    /// Close whatever session there is and open a fresh one — what an app
    /// restart did, which is how the stuck states were cleared before.
    private func reopenSession(_ camera: ICCameraDevice, id: String, reason: String) {
        Self.log.notice("reopen session \(id, privacy: .public) (\(reason, privacy: .public)), open=\(camera.hasOpenSession)")
        lastActivity[id] = Date()
        guard camera.hasOpenSession else {
            openSession(camera, id: id)
            return
        }
        reopenAfterClose.insert(id)
        camera.requestCloseSession()
        // If the close is never acknowledged, open anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.reopenAfterClose.remove(id) != nil,
                      let camera = self.cameras[id] else { return }
                self.openSession(camera, id: id)
            }
        }
    }

    private static func catalogLooksComplete(_ camera: ICCameraDevice) -> Bool {
        camera.hasOpenSession
            && !camera.isAccessRestrictedAppleDevice
            && camera.contentCatalogPercentCompleted >= 100
            && camera.mediaFiles != nil
    }

    // MARK: Supervision

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPollingIfIdle() {
        guard catalogWaiters.isEmpty, watchedCounts.isEmpty else { return }
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func bumpRevision(_ id: String) {
        catalogRevision[id, default: 0] += 1
    }

    private func poll() {
        let now = Date()

        // Devices that loaded empty while locked: their photos show up some
        // time after the unlock (in batches). Watch until the count is
        // non-zero and has held still for a couple of seconds.
        for (id, watch) in watchedCounts {
            guard let camera = cameras[id] else {
                watchedCounts.removeValue(forKey: id)
                continue
            }
            let count = camera.mediaFiles?.count ?? 0
            if count == 0, !camera.isAccessRestrictedAppleDevice,
               let at = unlockedAt[id], now.timeIntervalSince(at) >= Self.replugAfterUnlockSeconds {
                if devices.first(where: { $0.id == id })?.status != .needsReplug {
                    Self.log.notice("unlocked but still empty \(id, privacy: .public): needs re-plug")
                }
                setStatus(.needsReplug, for: id)
            }
            if count != watch.count {
                Self.log.notice("media count \(id, privacy: .public): \(watch.count) → \(count)")
                watchedCounts[id] = (count, 0)
                bumpRevision(id)
            } else if count > 0 {
                if watch.stableTicks >= 2 {
                    watchedCounts.removeValue(forKey: id)
                } else {
                    watchedCounts[id] = (count, watch.stableTicks + 1)
                }
            }
        }

        for id in Array(catalogWaiters.keys) {
            guard let camera = cameras[id] else { continue }

            // The "ready" callback can be missed (or never come for a
            // session that opened while locked); the device itself knows.
            if Self.catalogLooksComplete(camera) {
                Self.log.notice("catalog complete by poll \(id, privacy: .public)")
                catalogCompleted(camera)
                continue
            }

            let percent = camera.contentCatalogPercentCompleted
            if percent != lastCatalogPercent[id] {
                lastCatalogPercent[id] = percent
                lastActivity[id] = now
            }

            let status = devices.first(where: { $0.id == id })?.status
            if status == .needsReplug { continue }   // only a re-plug helps; wait for it
            if case .locked = status {
                // Shown as locked. Once the device reports unlocked for a
                // couple of seconds without the catalog following, start a
                // fresh session (in case the unlock notification was missed).
                if camera.isAccessRestrictedAppleDevice {
                    unlockedSince.removeValue(forKey: id)
                } else if let since = unlockedSince[id] {
                    if now.timeIntervalSince(since) >= 2 {
                        unlockedSince.removeValue(forKey: id)
                        if unlockedAt[id] == nil { unlockedAt[id] = since }
                        setStatus(.connecting, for: id)
                        reopenSession(camera, id: id, reason: "unlocked")
                    }
                } else {
                    unlockedSince[id] = now
                }
                continue
            }

            // Unlocked a while ago and the photo list hasn't come, with no
            // catalog progress either: the phone is serving an empty list,
            // and new sessions won't change that (they're refused as
            // "locked" while it's in this state). Say so instead of spinning.
            if let at = unlockedAt[id], now.timeIntervalSince(at) >= Self.replugAfterUnlockSeconds,
               now.timeIntervalSince(lastActivity[id] ?? .distantPast) >= Self.replugAfterUnlockSeconds - 1,
               !camera.isAccessRestrictedAppleDevice {
                Self.log.notice("unlocked \(Int(now.timeIntervalSince(at)))s, no catalog (\(camera.contentCatalogPercentCompleted)%) \(id, privacy: .public): needs re-plug")
                setStatus(.needsReplug, for: id)
                continue
            }

            // Connecting with nothing happening: try a fresh session, then
            // give up with an error the user can act on (click to retry).
            let idle = now.timeIntervalSince(lastActivity[id] ?? now)
            guard idle >= Self.stallSeconds else { continue }
            let tries = automaticReopens[id, default: 0]
            if tries < Self.maxAutomaticReopens {
                automaticReopens[id] = tries + 1
                reopenSession(camera, id: id, reason: "stalled")
            } else {
                Self.log.error("giving up on \(id, privacy: .public)")
                let error = CameraDeviceError.notResponding(name(of: id))
                setStatus(.failed(error.localizedDescription), for: id)
                finishWaiters(for: id, with: error)
            }
        }
        stopPollingIfIdle()
    }

    private func name(of id: String) -> String {
        devices.first(where: { $0.id == id })?.name ?? "Device"
    }

    private func setStatus(_ status: CameraDevice.Status, for id: String) {
        guard let i = devices.firstIndex(where: { $0.id == id }), devices[i].status != status else { return }
        devices[i].status = status
    }

    private func finishWaiters(for id: String, with error: Error?) {
        let waiters = catalogWaiters.removeValue(forKey: id) ?? []
        for w in waiters {
            if let error { w.resume(throwing: error) } else { w.resume() }
        }
        unlockedSince.removeValue(forKey: id)
        stopPollingIfIdle()
    }

    private static func id(of device: ICDevice) -> String {
        device.uuidString ?? String(UInt(bitPattern: ObjectIdentifier(device).hashValue))
    }

    private static func folderPath(of item: ICCameraItem) -> String {
        var parts: [String] = []
        var folder = item.parentFolder
        while let f = folder {
            if let n = f.name, !n.isEmpty { parts.insert(n, at: 0) }
            folder = f.parentFolder
        }
        return parts.joined(separator: "/")
    }

    // MARK: Delegate plumbing (main thread)

    fileprivate func added(_ device: ICDevice) {
        guard let camera = device as? ICCameraDevice, camera.mountPoint == nil else { return }
        let id = Self.id(of: camera)
        guard cameras[id] == nil else { return }
        cameras[id] = camera
        liveness[id] = DeviceLiveness()
        camera.delegate = self
        devices.append(CameraDevice(
            id: id,
            name: camera.name ?? camera.productKind ?? "Camera",
            symbolName: camera.systemSymbolName ?? "camera",
            status: .idle
        ))
    }

    fileprivate func removed(_ device: ICDevice) {
        let id = Self.id(of: device)
        guard cameras.removeValue(forKey: id) != nil else { return }
        Self.log.notice("device removed \(id, privacy: .public)")
        reopenAfterClose.remove(id)
        sawPasscodeLock.remove(id)
        unlockedAt.removeValue(forKey: id)
        watchedCounts.removeValue(forKey: id)
        liveness.removeValue(forKey: id)?.markGone()
        catalogReady.remove(id)
        devices.removeAll { $0.id == id }
        finishWaiters(for: id, with: CameraDeviceError.disconnected)
    }

    fileprivate func renamed(_ device: ICDevice) {
        let id = Self.id(of: device)
        guard let i = devices.firstIndex(where: { $0.id == id }), let name = device.name else { return }
        devices[i].name = name
    }

    fileprivate func openedSession(_ device: ICDevice, error: Error?) {
        let id = Self.id(of: device)
        let code = (error as NSError?)?.code ?? 0
        Self.log.notice("session opened \(id, privacy: .public) error=\(code)")
        lastActivity[id] = Date()
        guard let error = error as NSError? else { return }
        // ICReturnDeviceIsPasscodeLocked. Its Swift spelling has moved
        // between SDKs (it's an NS_ERROR_ENUM case), so match the value.
        if error.code == -9943 {
            // Keep the waiters: the catalog arrives once the user unlocks.
            sawPasscodeLock.insert(id)
            showLockedIfItLasts(id, message: error.localizedDescription)
        } else if !catalogReady.contains(id) {
            setStatus(.failed(error.localizedDescription), for: id)
            finishWaiters(for: id, with: error)
        }
    }

    fileprivate func closedSession(_ device: ICDevice) {
        let id = Self.id(of: device)
        Self.log.notice("session closed \(id, privacy: .public)")
        catalogReady.remove(id)
        if reopenAfterClose.remove(id) != nil, let camera = cameras[id] {
            openSession(camera, id: id)
        } else if catalogWaiters[id] != nil {
            // Closed under someone still waiting. Don't reopen from here — a
            // locked phone could bounce sessions in a tight loop; `poll`
            // retries at its own pace (on unlock, or after a stall).
            lastActivity[id] = Date()
        } else {
            setStatus(.idle, for: id)
        }
    }

    private func showLockedIfItLasts(_ id: String, message: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lockedGraceSeconds) { [weak self] in
            MainActor.assumeIsolated {
                // Only if the device still says it's locked: a phone that's
                // unlocked but in the empty-after-unlock state refuses new
                // sessions as "locked" too, and telling the user to unlock a
                // phone they just unlocked is what made this so confusing.
                guard let self, self.catalogWaiters[id] != nil,
                      let camera = self.cameras[id], camera.isAccessRestrictedAppleDevice,
                      self.devices.first(where: { $0.id == id })?.status != .needsReplug
                else { return }
                self.setStatus(.locked(message), for: id)
            }
        }
    }

    fileprivate func itemsChanged(_ device: ICCameraDevice) {
        let id = Self.id(of: device)
        guard catalogReady.contains(id) else { return }
        bumpRevision(id)
    }

    fileprivate func catalogCompleted(_ device: ICCameraDevice) {
        let id = Self.id(of: device)
        Self.log.notice("catalog complete \(id, privacy: .public): \(device.mediaFiles?.count ?? -1) files")
        catalogReady.insert(id)
        finishWaiters(for: id, with: nil)
    }

    fileprivate func accessRestrictionChanged(_ device: ICDevice, restricted: Bool) {
        let id = Self.id(of: device)
        Self.log.notice("access restriction \(id, privacy: .public): \(restricted ? "on" : "off", privacy: .public)")
        if !restricted, watchedCounts[id] != nil {
            unlockedAt[id] = Date()
        }
        guard catalogWaiters[id] != nil else { return }
        if restricted {
            unlockedSince.removeValue(forKey: id)
            showLockedIfItLasts(id, message: "Please unlock “\(name(of: id))”")
        } else {
            // Unlocked. Normally the catalog follows within moments; if it
            // doesn't, `poll` notices and says to re-plug.
            unlockedAt[id] = Date()
            if devices.first(where: { $0.id == id })?.status != .needsReplug {
                setStatus(.connecting, for: id)
            }
            lastActivity[id] = Date()
            if let camera = cameras[id], !camera.hasOpenSession {
                openSession(camera, id: id)
            }
        }
    }
}

/// ImageCaptureCore calls its delegates on the main thread (checked on
/// macOS 27). Hop there anyway if that ever changes, rather than trapping.
private func onMain(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated(body) }
    }
}

extension CameraDeviceWatcher: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        onMain { self.added(device) }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        onMain { self.removed(device) }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, deviceDidChangeName device: ICDevice) {
        onMain { self.renamed(device) }
    }
}

extension CameraDeviceWatcher: ICCameraDeviceDelegate {
    nonisolated func didRemove(_ device: ICDevice) {
        onMain { self.removed(device) }
    }

    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        onMain { self.openedSession(device, error: error) }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        onMain { self.closedSession(device) }
    }

    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        onMain { self.catalogCompleted(device) }
    }

    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        onMain { self.accessRestrictionChanged(device, restricted: true) }
    }

    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        onMain { self.accessRestrictionChanged(device, restricted: false) }
    }

    /// Thumbnails are never shown, so don't let ImageCaptureCore pull them
    /// over USB in the background. (Deliberately no `shouldGetMetadataOf`
    /// override: returning false there cancels explicit metadata requests.)
    nonisolated func cameraDevice(_ camera: ICCameraDevice, shouldGetThumbnailOf item: ICCameraItem) -> Bool {
        false
    }

    /// Photos appearing after an unlock, or taken/deleted while connected.
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        onMain { self.itemsChanged(camera) }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        onMain { self.itemsChanged(camera) }
    }

    // Required by the protocol; nothing to do.
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
}
