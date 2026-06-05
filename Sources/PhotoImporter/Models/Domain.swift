import Foundation

/// A removable volume candidate (SD/CF card).
struct Volume: Identifiable, Hashable, Codable {
    var id: String { mountPoint.path }
    var label: String
    var mountPoint: URL
    var totalBytes: Int64
    var availableBytes: Int64
}

/// Metadata extracted from a photo file. `fromExif` is true iff ImageIO
/// produced at least one identifying field; otherwise `date` is the file's
/// mtime fallback and everything else is nil.
struct PhotoMeta: Hashable, Codable {
    var date: Date?
    var cameraMake: String?
    var cameraModel: String?
    var cameraSerial: String?
    var cameraOwner: String?
    var lens: String?
    var iso: Int?
    var shutter: String?
    var aperture: String?
    var focalLength: String?
    /// Sub-second portion of `DateTimeOriginal` (e.g. `"123"` for 123 ms).
    /// Useful in filenames for high-burst sequences where HH-mm-ss collides.
    var subSecond: String?
    var fromExif: Bool
}

struct PhotoFile: Identifiable, Hashable, Codable {
    var id: String { path.path }
    var path: URL
    var sizeBytes: Int64
    var meta: PhotoMeta
}

/// Broad buckets used by the template-rule filter dropdown. `all` catches
/// every known-extension file; the others narrow to a specific family.
enum FileType: String, Codable, CaseIterable, Identifiable {
    case all, jpg, raw, video

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "all"
        case .jpg: return "jpg"
        case .raw: return "raw"
        case .video: return "video"
        }
    }

    static let jpgExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "tif", "tiff", "png", "gif",
    ]

    static let rawExtensions: Set<String> = [
        "cr2", "cr3", "nef", "arw", "dng", "raf", "rw2", "orf",
        "srf", "x3f", "pef", "3fr", "sr2", "srw",
        "erf", "mef", "mos", "mrw", "nrw", "rwl",
    ]

    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "mts", "m2ts", "avi", "3gp",
    ]

    /// Union of every extension this app is willing to import. Drives the
    /// scanner's walk filter as well as rule matching.
    static let allKnownExtensions: Set<String> = {
        var s: Set<String> = []
        s.formUnion(jpgExtensions)
        s.formUnion(rawExtensions)
        s.formUnion(videoExtensions)
        return s
    }()

    func matches(extension ext: String) -> Bool {
        let lc = ext.lowercased()
        switch self {
        case .all: return Self.allKnownExtensions.contains(lc)
        case .jpg: return Self.jpgExtensions.contains(lc)
        case .raw: return Self.rawExtensions.contains(lc)
        case .video: return Self.videoExtensions.contains(lc)
        }
    }

    /// Tooltip for the filter picker: reflects the currently-selected
    /// category so the help always matches what the row filters.
    var tooltip: String {
        func fmt(_ set: Set<String>) -> String {
            // Use insertion-ish order: not sorted, but consistent.
            set.sorted().joined(separator: ", ")
        }
        switch self {
        case .all: return "All jpg, raw and video files"
        case .jpg: return fmt(Self.jpgExtensions)
        case .raw: return fmt(Self.rawExtensions)
        case .video: return fmt(Self.videoExtensions)
        }
    }
}

/// One row of the naming-template editor: a file-type filter + a template
/// + an optional backup folder. An empty `template` marks the row as
/// inactive and is skipped during rule matching.
///
/// When `backupFolder` is non-nil, every successful primary copy also
/// mirrors to the same relative path under the backup folder.
struct TemplateRule: Identifiable, Hashable, Codable {
    var id: UUID
    var fileType: FileType
    var template: String
    /// Optional mirror location. Security-scoped bookmark form so access
    /// persists across app launches under the sandbox.
    var backupFolder: FolderRef?

    init(id: UUID = UUID(), fileType: FileType, template: String, backupFolder: FolderRef? = nil) {
        self.id = id
        self.fileType = fileType
        self.template = template
        self.backupFolder = backupFolder
    }

    var isActive: Bool { !template.trimmingCharacters(in: .whitespaces).isEmpty }
}

enum CollisionPolicy: String, Codable, CaseIterable, Identifiable {
    /// Hash both sides; skip if identical, rename if different.
    case skipSameHash
    /// Skip silently when any file with that name already exists at dest.
    case skipAll
    /// Always rename if destination exists (append `-2`, `-3`, …).
    case renameIfDifferent
    /// Overwrite destination unconditionally.
    case overwrite

    var id: String { rawValue }
    var label: String {
        switch self {
        case .skipSameHash: return "Skip if file content is identical"
        case .skipAll: return "Skip if file name is identical"
        case .renameIfDifferent: return "Always rename if file name exists"
        case .overwrite: return "Overwrite"
        }
    }
}

/// A single rule inside a saved preset: what file-type filter it matches
/// and what template it produces. Deliberately does NOT include the
/// per-rule backup folder — bookmarks are device-local and wouldn't
/// resolve across iCloud-synced Macs anyway. The UI-level `TemplateRule`
/// carries backupFolder as device-only state.
struct PresetRule: Hashable, Codable {
    var fileType: FileType
    var template: String
}

/// A user-saved naming-template configuration. iCloud-synced. Carries
/// only the 3-row rule list (file-type + template each) — destination
/// folder, backup folders, and the import-behavior options (collision,
/// verify, delete-after, auto-eject) intentionally live elsewhere so
/// they don't get clobbered when switching presets.
///
/// Swift Codable decoding ignores unknown keys, so older presets saved
/// with extra fields (destination, collisionPolicy, …) or richer
/// `TemplateRule` rules (with backupFolder) deserialize fine — the
/// extra data is silently dropped.
struct Preset: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var rules: [PresetRule]

    init(id: String, name: String, rules: [PresetRule]) {
        self.id = id
        self.name = name
        self.rules = rules
    }
}

struct ImportOptions: Hashable {
    var collisionPolicy: CollisionPolicy
    var verify: Bool
}

struct ImportItem: Hashable {
    var src: URL
    var dst: URL
    var seq: UInt64
    var sizeBytes: Int64
    /// Optional mirror location: when set, the same file content is also
    /// copied to this path after the primary write succeeds. Defaults to
    /// nil so existing callers (and tests) compile unchanged.
    var backupDst: URL? = nil
}

struct ImportPlan {
    var items: [ImportItem]
    var totalBytes: Int64
}

enum ImportOutcome: Hashable {
    case copied
    case copiedAs(URL)
    case skippedIdentical
    case skippedExisting
    case overwritten
    case verifyFailed
    case failed(String)

    var isEligibleForDelete: Bool {
        switch self {
        case .copied, .copiedAs, .overwritten, .skippedIdentical:
            return true
        case .skippedExisting, .verifyFailed, .failed:
            return false
        }
    }
}

enum ImportPhase: String, Hashable { case primary, backup }

struct ImportProgress: Hashable {
    var phase: ImportPhase
    var itemIndex: Int
    var totalItems: Int
    var bytesDone: Int64
    var bytesTotal: Int64
    var currentSrc: URL
    var currentDst: URL
    var outcome: ImportOutcome
}

struct ImportResult {
    var copied: Int = 0
    var skipped: Int = 0
    var overwritten: Int = 0
    var failed: Int = 0
    var verified: Int = 0
    var verifyFailed: Int = 0
    var failures: [(URL, String)] = []
}

/// Bundles the primary + optional backup phase results. When the plan
/// contains no backup-folder rules, `backup` is nil.
struct TwoPhaseResult {
    var primary: ImportResult
    var backup: ImportResult?
}

struct Preflight: Hashable {
    var requiredBytes: Int64
    var availableBytes: Int64
    var ok: Bool
}

struct DeleteResult {
    var deleted: Int = 0
    var failed: Int = 0
    var failures: [(URL, String)] = []
}
