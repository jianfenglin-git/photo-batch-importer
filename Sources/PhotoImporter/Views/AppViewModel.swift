import Foundation
import SwiftUI
import AppKit
import Combine

/// Play the macOS "Glass" system chime. Used on primary-phase completion
/// and backup-phase completion — clean bell tone that reads as "done"
/// without the theatrics of Hero.
func playCompletionChime() {
    let url = URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")
    if let sound = NSSound(contentsOf: url, byReference: true) {
        sound.play()
    } else {
        NSSound.beep()
    }
}

/// Single owner of user-facing state. Services (VolumeWatcher, SequenceStore,
/// PresetStore) are separate @ObservableObjects passed in. Heavy work (scan,
/// import) runs on Tasks; published properties are only mutated from the
/// main actor.
@MainActor
final class AppViewModel: ObservableObject {
    // Services
    let volumeWatcher: VolumeWatcher
    let sequenceStore: SequenceStore
    let presetStore: PresetStore
    let cardAccessStore: CardAccessStore

    // Card / scan
    @Published var volumes: [Volume] = []
    @Published var selectedVolume: Volume?
    @Published var photos: [PhotoFile] = []
    @Published var scanning: Bool = false
    @Published var scanError: String?
    /// True when a card is selected but the sandbox blocks reading it until
    /// the user grants access via an Open panel. Drives the modal
    /// "Grant Access" sheet. Always false in unsandboxed dev builds.
    @Published var needsCardAccess: Bool = false

    // Selection (by PhotoFile.id — path string). SwiftUI Table feeds this.
    @Published var selectedPaths: Set<String> = []

    // Destination, template, derived state
    /// User-picked destination folder. Stored as a security-scoped
    /// bookmark (FolderRef) so it survives app restarts + sandboxing; the
    /// displayPath is what the UI shows.
    @Published var destination: FolderRef?
    /// Fixed-length array of three rule slots. Defaults: Jpg and Raw share
    /// the `IMG_` image template (so a dual-format pair lands with matching
    /// names under `IMG_000001.JPG` / `IMG_000001.RAF`); Video uses a `VID_`
    /// prefix so movies sort separately from stills.
    @Published var rules: [TemplateRule] = AppViewModel.defaultRules
    /// Per-row template parse errors, keyed by row index. Clean rows omitted.
    @Published var ruleErrors: [Int: String] = [:]
    @Published var focusedRuleIndex: Int = 0
    /// Cursor range for each rule row, kept independently so each editor's
    /// selection is preserved while the user clicks across rows. The
    /// focused row's entry drives chip insertion.
    @Published var ruleSelections: [Int: NSRange] = [:]
    @Published var destinations: [String: String] = [:]   // photo.id → rel dst

    // Options
    @Published var collisionPolicy: CollisionPolicy = .skipSameHash
    @Published var verify: Bool = false
    @Published var deleteAfter: Bool = false
    @Published var autoEject: Bool = false

    // Presets
    @Published var activePresetID: String?

    // Import lifecycle
    @Published var importing: Bool = false
    @Published var currentPhase: ImportPhase?   // nil when idle
    @Published var totalItemsPlanned: Int = 0
    @Published var totalBytesPlanned: Int64 = 0
    @Published var progress: ImportProgress?
    @Published var importResult: TwoPhaseResult?
    @Published var deleteResult: DeleteResult?
    /// Message shown next to the Start-Import button: typically only set
    /// between phases (primary done / backup running).
    @Published var phaseMessage: String?

    // Sheet / modal state
    @Published var deleteConfirm: DeleteConfirmState?
    @Published var preflightError: Preflight?
    @Published var presetSaveSheet: PresetSaveSheetState?
    @Published var presetDeleteConfirm: Preset?
    @Published var showAllTokens: Bool = false

    // Eject feedback
    @Published var ejectingMounts: Set<String> = []
    @Published var ejectErrors: [String: String] = [:]

    // Runtime state that isn't published to the UI
    private var scanTask: Task<Void, Never>?
    private var destinationsTask: Task<Void, Never>?
    private var runOptions: RunOptions?
    private var eligibleSources: [URL] = []
    private var cancellables: Set<AnyCancellable> = []
    /// Set while we're assigning published options from an iCloud push, so
    /// the per-field sinks know not to echo the same value back to iCloud
    /// and trigger an external-change loop.
    private var applyingSyncedOptions = false

    static let defaultImageTemplate = "{date:YYYY}/{date:YYYY-MM-DD}/IMG_{seq:000000}.{file.ext}"
    static let defaultVideoTemplate = "{date:YYYY}/{date:YYYY-MM-DD}/VID_{seq:000000}.{file.ext}"

    static let defaultRules: [TemplateRule] = [
        TemplateRule(fileType: .jpg, template: defaultImageTemplate),
        TemplateRule(fileType: .raw, template: defaultImageTemplate),
        TemplateRule(fileType: .video, template: defaultVideoTemplate),
    ]

    // MARK: - Built-in presets

    static let builtInAllTogetherName = "all in the same folder"
    static let builtInSeparatedName = "jpg/raw/video in separate folders"

    /// Device-local working state: the user's last-used rules, destination
    /// bookmark, and which preset was active. Different Macs typically want
    /// different destinations + bookmark paths that don't resolve across
    /// devices, so this intentionally stays out of iCloud.
    private struct LocalFormState: Codable {
        var activePresetID: String?
        var rules: [TemplateRule]
        var destination: FolderRef?
    }

    /// Import-behavior options that DO sync across the user's Macs via the
    /// iCloud key-value store. Changing verify on one Mac shows up on the
    /// other within seconds.
    private struct SyncedOptions: Codable {
        var collisionPolicy: CollisionPolicy
        var verify: Bool
        var deleteAfter: Bool
        var autoEject: Bool
    }

    private static let localStateKey = "formState.v1"
    private static let syncedOptionsKey = "options.v1"

    /// Two starter presets seeded on first launch when the user has no
    /// presets yet. The first is the default selection.
    static var builtInPresets: [Preset] {
        [
            Preset(
                id: "",
                name: builtInAllTogetherName,
                rules: [
                    PresetRule(fileType: .all,   template: "{date:YYYY}/{date:YYYY-MM-DD}/IMG_{seq:000000}.{file.ext}"),
                    PresetRule(fileType: .raw,   template: ""),
                    PresetRule(fileType: .video, template: ""),
                ]
            ),
            Preset(
                id: "",
                name: builtInSeparatedName,
                rules: [
                    PresetRule(fileType: .jpg,   template: "{date:YYYY}/{date:YYYY-MM-DD}/jpg/IMG_{seq:000000}.{file.ext}"),
                    PresetRule(fileType: .raw,   template: "{date:YYYY}/{date:YYYY-MM-DD}/raw/IMG_{seq:000000}.{file.ext}"),
                    PresetRule(fileType: .video, template: "{date:YYYY}/{date:YYYY-MM-DD}/video/VID_{seq:000000}.{file.ext}"),
                ]
            ),
        ]
    }

    struct DeleteConfirmState {
        var paths: [URL]
        var verified: Bool
        var volumeMount: URL
    }

    struct PresetSaveSheetState {
        var name: String
        var mode: Mode
        enum Mode { case new, overwrite }
    }

    private struct RunOptions {
        var verify: Bool
        var deleteAfter: Bool
        var autoEject: Bool
        var volumeMount: URL
    }

    init(volumeWatcher: VolumeWatcher, sequenceStore: SequenceStore, presetStore: PresetStore, cardAccessStore: CardAccessStore) {
        self.volumeWatcher = volumeWatcher
        self.sequenceStore = sequenceStore
        self.presetStore = presetStore
        self.cardAccessStore = cardAccessStore

        // Mirror the watcher's list and clear selection when the current
        // volume disappears (ejected / unmounted externally).
        volumeWatcher.$volumes
            .receive(on: RunLoop.main)
            .sink { [weak self] newList in
                guard let self = self else { return }
                self.volumes = newList
                if let current = self.selectedVolume,
                   !newList.contains(where: { $0.id == current.id }) {
                    self.selectedVolume = nil
                    self.photos = []
                    self.selectedPaths = []
                    self.needsCardAccess = false
                }
            }
            .store(in: &cancellables)

        // Whenever volume / rules / selection / destination change, rebuild
        // destination previews.
        Publishers.CombineLatest4($selectedPaths, $rules, $destination, $selectedVolume)
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _, _, _, _ in
                self?.recomputeDestinations()
            }
            .store(in: &cancellables)

        $photos
            .sink { [weak self] _ in self?.recomputeDestinations() }
            .store(in: &cancellables)

        // A sequence-counter change (user edit or an import bumping it)
        // shifts the seq numbers rendered in the Destination column, so
        // refresh the preview.
        sequenceStore.$lastSeq
            .dropFirst()  // initial value is already reflected
            .sink { [weak self] _ in self?.recomputeDestinations() }
            .store(in: &cancellables)

        // Live per-row template validation.
        $rules
            .removeDuplicates()
            .sink { [weak self] rs in
                guard let self = self else { return }
                var errors: [Int: String] = [:]
                for (i, rule) in rs.enumerated() where rule.isActive {
                    do {
                        _ = try Template.parse(rule.template)
                    } catch {
                        errors[i] = error.localizedDescription
                    }
                }
                self.ruleErrors = errors
            }
            .store(in: &cancellables)

        // Restore the last-used form state BEFORE the seed/apply logic so
        // we don't clobber what the user saw at quit time.
        let restoredLocal = AppViewModel.loadLocalState()
        if let state = restoredLocal {
            rules = state.rules
            destination = state.destination
            activePresetID = state.activePresetID
        }
        // Synced options come from the cloud KV store (UserDefaults mirror
        // in dev builds). Any value pulled here takes precedence over the
        // field initializers above.
        if let opts = CloudKVStore.shared.codable(SyncedOptions.self, forKey: Self.syncedOptionsKey) {
            collisionPolicy = opts.collisionPolicy
            verify = opts.verify
            deleteAfter = opts.deleteAfter
            autoEject = opts.autoEject
        }

        // First-run seeding: if the user has no presets (neither local nor
        // iCloud-synced), install the two built-in starters and default to
        // the first one.
        let seeded = presetStore.seedBuiltInPresetsIfEmpty(Self.builtInPresets)
        if seeded && restoredLocal == nil {
            if let standard = presetStore.presets.first(where: { $0.name == Self.builtInAllTogetherName }) {
                activePresetID = standard.id
                applyPreset(standard)
            }
        }

        // Invariant: always have an active preset. If the restored ID is
        // missing (first launch of a later app version, or the preset was
        // deleted on another Mac) fall back to the first preset in the list.
        // The picker has no "none" option any more so this ensures it
        // always shows a valid selection.
        if activePresetID == nil || presetStore.presets.first(where: { $0.id == activePresetID }) == nil {
            if let first = presetStore.presets.first {
                activePresetID = first.id
            }
        }

        // Persist on every subsequent change. Two things to note:
        //   1. `.dropFirst()` drops the replay of the current value that
        //      every @Published publisher fires at subscription time.
        //   2. `.receive(on: DispatchQueue.main)` defers the sink body to
        //      the next runloop tick. @Published emits in willSet — BEFORE
        //      the property's storage actually updates — so a synchronous
        //      sink would see the stale value when reading the property.
        //      Running async on main guarantees the storage is current.
        $rules.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.persistLocalState() }
            .store(in: &cancellables)
        $destination.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.persistLocalState() }
            .store(in: &cancellables)
        $activePresetID.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.persistLocalState() }
            .store(in: &cancellables)

        // Synced-option sinks: skip writing when we're reflecting an
        // incoming iCloud change, to avoid echoing the same value back.
        $collisionPolicy.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self, !self.applyingSyncedOptions else { return }
                self.persistSyncedOptions()
            }.store(in: &cancellables)
        $verify.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self, !self.applyingSyncedOptions else { return }
                self.persistSyncedOptions()
            }.store(in: &cancellables)
        $deleteAfter.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self, !self.applyingSyncedOptions else { return }
                self.persistSyncedOptions()
            }.store(in: &cancellables)
        $autoEject.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self, !self.applyingSyncedOptions else { return }
                self.persistSyncedOptions()
            }.store(in: &cancellables)

        // When another Mac pushes an options change via iCloud, adopt it.
        CloudKVStore.shared.externalChanges
            .sink { [weak self] keys in
                guard let self = self, keys.contains(Self.syncedOptionsKey) else { return }
                guard let opts = CloudKVStore.shared.codable(SyncedOptions.self, forKey: Self.syncedOptionsKey) else { return }
                self.applyingSyncedOptions = true
                self.collisionPolicy = opts.collisionPolicy
                self.verify = opts.verify
                self.deleteAfter = opts.deleteAfter
                self.autoEject = opts.autoEject
                self.applyingSyncedOptions = false
            }
            .store(in: &cancellables)
    }

    private func persistLocalState() {
        let state = LocalFormState(
            activePresetID: activePresetID,
            rules: rules,
            destination: destination
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.localStateKey)
        }
    }

    private func persistSyncedOptions() {
        let opts = SyncedOptions(
            collisionPolicy: collisionPolicy,
            verify: verify,
            deleteAfter: deleteAfter,
            autoEject: autoEject
        )
        CloudKVStore.shared.setCodable(opts, forKey: Self.syncedOptionsKey)
    }

    private static func loadLocalState() -> LocalFormState? {
        guard let data = UserDefaults.standard.data(forKey: localStateKey) else {
            return nil
        }
        return try? JSONDecoder().decode(LocalFormState.self, from: data)
    }

    /// True when every active rule parses cleanly. Import is blocked when false.
    var rulesValid: Bool { ruleErrors.isEmpty && rules.contains(where: { $0.isActive }) }

    /// User-initiated change to the "next sequence number" value. Unlike
    /// the import-time bump (which flows through Combine to recompute),
    /// we call recomputeDestinations explicitly here as a belt-and-
    /// suspenders guarantee that the Destination column refreshes
    /// immediately — independent of any Combine-chain timing.
    func setSequenceStart(_ nextValue: UInt64) {
        sequenceStore.setNextStart(nextValue)
        recomputeDestinations()
    }

    /// Compile the active rules for the import engine.
    ///
    /// - `resolveBookmarks`: when true, each active rule's backup folder
    ///   bookmark is resolved and its URL is used (for actual imports).
    ///   When false, the displayPath is used directly (for preview-only).
    ///   Returns the list of `FolderRef.Resolved` tokens alongside so the
    ///   caller can keep them alive (they auto-stop on deinit).
    func compiledRules(resolveBookmarks: Bool = false) -> ([CompiledRule], [FolderRef.Resolved]) {
        var compiled: [CompiledRule] = []
        var tokens: [FolderRef.Resolved] = []
        for rule in rules {
            guard rule.isActive, let segs = try? Template.parse(rule.template) else { continue }
            var backupURL: URL? = nil
            if let ref = rule.backupFolder {
                if resolveBookmarks {
                    if let resolved = ref.resolve() {
                        tokens.append(resolved)
                        backupURL = resolved.url
                    }
                    // If resolve failed, the backup silently skips for
                    // that rule — primary copy still happens. UI shows
                    // the bookmark path so the user can re-pick.
                } else {
                    backupURL = URL(fileURLWithPath: ref.displayPath)
                }
            }
            compiled.append(CompiledRule(
                fileType: rule.fileType,
                segments: segs,
                backupFolder: backupURL
            ))
        }
        return (compiled, tokens)
    }

    /// Open an NSOpenPanel and set the selected folder as the backup folder
    /// for rule at `index`. Silently no-ops on cancel.
    func pickBackupFolder(forRuleAt index: Int) {
        guard index < rules.count else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose backup folder for \(rules[index].fileType.label) files"
        if panel.runModal() == .OK, let url = panel.url, let ref = FolderRef(url: url) {
            rules[index].backupFolder = ref
        }
    }

    func clearBackupFolder(forRuleAt index: Int) {
        guard index < rules.count else { return }
        rules[index].backupFolder = nil
    }

    static func makeDefault() -> AppViewModel {
        let vw = VolumeWatcher()
        let cloud = CloudKVStore.shared
        let seq = SequenceStore(cloud: cloud)
        let pre = PresetStore(cloud: cloud)
        let cardAccess = CardAccessStore()
        return AppViewModel(volumeWatcher: vw, sequenceStore: seq, presetStore: pre, cardAccessStore: cardAccess)
    }

    // MARK: - Card selection + scan

    func selectVolume(_ v: Volume) {
        if selectedVolume?.id == v.id { return }
        selectedVolume = v
        photos = []
        selectedPaths = []
        destinations = [:]
        scanError = nil
        needsCardAccess = false
        scanTask?.cancel()

        // Under the sandbox, reading the card requires a user grant persisted
        // as a security-scoped bookmark. Try a stored grant first; if none
        // resolves, go straight to the system Open panel — which IS the macOS
        // permission grant (Powerbox extends the sandbox only to a path the
        // user picks there). In unsandboxed dev builds there's no stored
        // bookmark and no sandbox, so we scan the raw mount path directly
        // (resolved == nil, sandboxed == false).
        let resolved = cardAccessStore.resolve(forMountPath: v.mountPoint.path)
        if resolved == nil && Sandbox.isActive {
            requestCardAccess(for: v)
            return
        }
        scanning = true
        scan(volume: v, access: resolved)
    }

    /// Present the system Open panel pre-pointed at the card so the user can
    /// grant read access. This single panel is the whole permission step —
    /// there's no sandbox-legal way to grant card access without it, so we
    /// show it directly (no extra confirmation modal in front). On approval
    /// the security-scoped bookmark is persisted (future inserts skip this)
    /// and the scan starts immediately.
    private func requestCardAccess(for v: Volume) {
        // `needsCardAccess` drives the Photos pane's "waiting for permission"
        // text while the panel is up. runModal() blocks the runloop, so open
        // it on the next turn to let SwiftUI settle the selection first.
        needsCardAccess = true
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = v.mountPoint
            panel.message = "Allow Photo Batch Importer to read photos from “\(v.label)”. "
                + "Keep this card selected and click Grant Access."
            panel.prompt = "Grant Access"
            self.needsCardAccess = false
            guard panel.runModal() == .OK, let url = panel.url, let ref = FolderRef(url: url) else {
                // User cancelled the panel: drop back to a neutral state so the
                // card looks unselected rather than stuck "Scanning…".
                guard self.selectedVolume?.id == v.id else { return }
                self.selectedVolume = nil
                self.photos = []
                self.selectedPaths = []
                return
            }
            self.cardAccessStore.store(ref, forMountPath: v.mountPoint.path)
            // The volume could have changed while the panel was up; only scan
            // if this card is still the selected one.
            guard self.selectedVolume?.id == v.id else { return }
            self.scanError = nil
            self.scanning = true
            self.scan(volume: v, access: self.cardAccessStore.resolve(forMountPath: v.mountPoint.path))
        }
    }

    /// Scan `volume`, holding the security-scoped access token (if any) alive
    /// for the duration so sandboxed reads succeed, then releasing it.
    private func scan(volume v: Volume, access: FolderRef.Resolved?) {
        let mount = v.mountPoint
        scanTask = Task.detached(priority: .userInitiated) { [weak self, access] in
            let found = PhotoScanner.scan(at: mount)
            // Keep `access` alive across the scan; stop the scope now that
            // file enumeration + metadata reads are done.
            access?.stop()
            await MainActor.run {
                guard let self = self else { return }
                guard self.selectedVolume?.mountPoint == mount else { return }
                self.photos = found
                self.selectedPaths = Set(found.map { $0.id })
                self.scanning = false
            }
        }
    }

    // MARK: - Destination preview

    private func recomputeDestinations() {
        destinationsTask?.cancel()
        if photos.isEmpty || !rulesValid {
            destinations = [:]
            return
        }
        let selected = photos.filter { selectedPaths.contains($0.id) }
        guard !selected.isEmpty else {
            destinations = [:]
            return
        }
        let (rulesCopy, _) = compiledRules(resolveBookmarks: false)
        guard !rulesCopy.isEmpty else {
            destinations = [:]
            return
        }
        // For the preview we only need path-string output, not actual I/O;
        // skip the security scope dance and use the display path or an
        // empty URL placeholder. Real file writes below go through
        // `resolve()` + `startAccessing…`.
        let destPath = destination?.displayPath ?? ""
        let destURL = destPath.isEmpty ? URL(fileURLWithPath: "") : URL(fileURLWithPath: destPath)
        let cardLabel = selectedVolume?.label ?? ""
        let seqStart = sequenceStore.nextStart()
        destinationsTask = Task.detached(priority: .utility) { [weak self] in
            let plan = ImportEngine.plan(
                photos: selected,
                rules: rulesCopy,
                destination: destURL,
                cardLabel: cardLabel,
                seqStart: seqStart
            )
            let prefix = destURL.path
            var map: [String: String] = [:]
            map.reserveCapacity(plan.items.count)
            for item in plan.items {
                var rel = item.dst.path
                if !prefix.isEmpty, rel.hasPrefix(prefix) {
                    rel = String(rel.dropFirst(prefix.count))
                    if rel.hasPrefix("/") { rel.removeFirst() }
                }
                map[item.src.path] = rel
            }
            await MainActor.run {
                self?.destinations = map
            }
        }
    }

    // MARK: - Destination picker

    func pickDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose destination folder"
        if panel.runModal() == .OK, let url = panel.url, let ref = FolderRef(url: url) {
            destination = ref
        }
    }

    // MARK: - Presets

    func applyPreset(_ p: Preset) {
        // Preserve each file-type's current backup folder across a preset
        // switch. The preset itself doesn't carry backup folders (they're
        // device-local, stored in the UI-level TemplateRule) so without
        // this, picking a preset would wipe your configured backups.
        var existingBackupsByType: [FileType: FolderRef] = [:]
        for r in rules {
            if let bf = r.backupFolder, existingBackupsByType[r.fileType] == nil {
                existingBackupsByType[r.fileType] = bf
            }
        }

        var loaded: [TemplateRule] = p.rules.map { pr in
            TemplateRule(
                fileType: pr.fileType,
                template: pr.template,
                backupFolder: existingBackupsByType[pr.fileType]
            )
        }
        while loaded.count < 3 {
            loaded.append(TemplateRule(fileType: .all, template: ""))
        }
        rules = Array(loaded.prefix(3))
        // Destination + options are NOT part of a preset any more; leave
        // them as the user had them.
    }

    func onPresetPick(_ id: String) {
        guard let p = presetStore.presets.first(where: { $0.id == id }) else {
            return
        }
        applyPreset(p)
        activePresetID = id
    }

    func openPresetSaveNew() {
        let seed: String
        if let active = activePreset {
            seed = "\(active.name) copy"
        } else {
            seed = ""
        }
        presetSaveSheet = PresetSaveSheetState(name: seed, mode: .new)
    }

    func openPresetUpdate() {
        guard let active = activePreset else { return }
        presetSaveSheet = PresetSaveSheetState(name: active.name, mode: .overwrite)
    }

    var activePreset: Preset? {
        guard let id = activePresetID else { return nil }
        return presetStore.presets.first(where: { $0.id == id })
    }

    func commitPresetSave() {
        guard let sheet = presetSaveSheet else { return }
        let name = sheet.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        // Resolve the target id. In .overwrite (rename) mode we always
        // target the active preset. In .new mode we'd normally create a
        // fresh row, but if a preset already exists with the same name
        // (case-insensitive), overwrite it in place — otherwise the user
        // ends up with two separate entries that share a label.
        let id: String
        if sheet.mode == .overwrite {
            id = activePreset?.id ?? ""
        } else if let dup = presetStore.presets.first(where: {
            $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }) {
            id = dup.id
        } else {
            id = ""
        }
        // A preset is a snapshot of the three template rules only — just
        // fileType + template. Backup folders, destination, and options
        // are all stored elsewhere so switching presets doesn't disturb
        // them.
        let presetRules = rules.map { r in
            PresetRule(fileType: r.fileType, template: r.template)
        }
        let preset = Preset(id: id, name: name, rules: presetRules)
        let saved = presetStore.upsert(preset)
        activePresetID = saved.id
        presetSaveSheet = nil
    }

    func confirmPresetDelete(_ p: Preset) {
        presetDeleteConfirm = p
    }

    func commitPresetDelete() {
        guard let p = presetDeleteConfirm else { return }
        _ = presetStore.remove(id: p.id)
        presetDeleteConfirm = nil
        // Maintain the invariant that at least one preset always exists
        // and an active one is always selected (we removed the "no preset"
        // fallback option from the picker).
        if presetStore.presets.isEmpty {
            _ = presetStore.seedBuiltInPresetsIfEmpty(Self.builtInPresets)
        }
        if let nextSelected = presetStore.presets.first {
            activePresetID = nextSelected.id
            applyPreset(nextSelected)
        }
    }

    // MARK: - Template chip insertion

    /// Insert `token` at the cursor inside whichever rule row last had
    /// focus. If nothing has been focused yet, falls back to row 0.
    func insertToken(_ token: String) {
        let idx = (0..<rules.count).contains(focusedRuleIndex) ? focusedRuleIndex : 0
        guard idx < rules.count else { return }
        let current = rules[idx].template
        let nsText = current as NSString
        let sel = ruleSelections[idx] ?? NSRange(location: nsText.length, length: 0)
        let clampedStart = min(sel.location, nsText.length)
        let clampedLen = max(0, min(sel.length, nsText.length - clampedStart))
        let range = NSRange(location: clampedStart, length: clampedLen)
        let replaced = nsText.replacingCharacters(in: range, with: token)
        rules[idx].template = replaced
        ruleSelections[idx] = NSRange(
            location: clampedStart + (token as NSString).length,
            length: 0
        )
    }

    // MARK: - Eject

    func doEject(mountPoint: URL) {
        let key = mountPoint.path
        ejectingMounts.insert(key)
        ejectErrors.removeValue(forKey: key)
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try Eject.eject(mountPoint: mountPoint)
                await MainActor.run { self?.ejectingMounts.remove(key) }
            } catch {
                await MainActor.run {
                    self?.ejectErrors[key] = error.localizedDescription
                    self?.ejectingMounts.remove(key)
                }
            }
        }
    }

    func clearEjectErrors() {
        if !ejectErrors.isEmpty { ejectErrors = [:] }
    }

    // MARK: - Import

    var selectedPhotos: [PhotoFile] {
        photos.filter { selectedPaths.contains($0.id) }
    }

    var canImport: Bool {
        selectedVolume != nil &&
            destination != nil &&
            rulesValid &&
            !importing &&
            !selectedPhotos.isEmpty
    }

    func startImport() {
        guard let volume = selectedVolume, let destRef = destination else { return }
        let selected = selectedPhotos
        guard !selected.isEmpty else { return }

        // Resolve the destination bookmark upfront. If it can't resolve,
        // the user has a stale folder (moved / deleted / device-mismatch
        // from iCloud). Surface and bail.
        guard let destResolved = destRef.resolve() else {
            scanError = "Destination folder is no longer accessible — please re-select it."
            return
        }
        let dest = destResolved.url

        importResult = nil
        deleteResult = nil
        deleteConfirm = nil
        preflightError = nil
        phaseMessage = nil
        ejectErrors = [:]
        eligibleSources = []

        // Preflight
        let required: Int64 = selected.reduce(into: 0) { $0 &+= $1.sizeBytes }
        do {
            let pf = try PreflightService.check(destination: dest, requiredBytes: required)
            if !pf.ok {
                destResolved.stop()
                preflightError = pf
                return
            }
        } catch {
            destResolved.stop()
            scanError = error.localizedDescription
            return
        }

        importing = true
        progress = nil
        let (compiled, scopeTokens) = compiledRules(resolveBookmarks: true)
        guard !compiled.isEmpty else {
            destResolved.stop()
            importing = false
            return
        }

        runOptions = RunOptions(
            verify: verify,
            deleteAfter: deleteAfter,
            autoEject: autoEject,
            volumeMount: volume.mountPoint
        )

        let seqStart = sequenceStore.nextStart()
        let options = ImportOptions(collisionPolicy: collisionPolicy, verify: verify)
        let cardLabel = volume.label

        // Hold the card's security scope (if sandboxed) for the whole import
        // so reading source files off the card succeeds. nil in dev builds.
        let cardAccess = cardAccessStore.resolve(forMountPath: volume.mountPoint.path)

        // Capture the scope tokens in the closure so they stay alive for
        // the whole two-phase import; they auto-stop on deinit at the end.
        let heldTokens = [destResolved] + scopeTokens
        Task.detached(priority: .userInitiated) { [weak self, heldTokens, cardAccess] in
            defer { cardAccess?.stop() }
            defer {
                // Deinit the tokens on this thread once the task returns.
                // Wrapping in a block keeps the array alive until here.
                _ = heldTokens.count
            }
            let plan = ImportEngine.plan(
                photos: selected,
                rules: compiled,
                destination: dest,
                cardLabel: cardLabel,
                seqStart: seqStart
            )
            let hasBackup = plan.items.contains(where: { $0.backupDst != nil })

            if let last = plan.items.last {
                await MainActor.run {
                    self?.sequenceStore.commit(highestUsed: last.seq)
                    self?.totalItemsPlanned = plan.items.count
                    self?.totalBytesPlanned = plan.totalBytes
                    self?.currentPhase = .primary
                }
            }

            // Phase 1: primary.
            var localEligible: [URL] = []
            let primaryResult = ImportEngine.executePrimary(plan: plan, options: options) { progress in
                if progress.outcome.isEligibleForDelete {
                    localEligible.append(progress.currentSrc)
                }
                let snapshot = progress
                Task { @MainActor in
                    self?.progress = snapshot
                }
            }

            await MainActor.run {
                self?.importResult = TwoPhaseResult(primary: primaryResult, backup: nil)
                if hasBackup {
                    self?.phaseMessage = "Completed copying to primary folder. You can use them while backup is in progress."
                }
                playCompletionChime()
            }

            // Phase 2: backup (re-reads source, not primary).
            if hasBackup {
                await MainActor.run {
                    self?.currentPhase = .backup
                    // Reset totals for the backup phase so the progress bar
                    // tracks just this phase.
                    let backupItems = plan.items.filter { $0.backupDst != nil }
                    self?.totalItemsPlanned = backupItems.count
                    self?.totalBytesPlanned = backupItems.reduce(Int64(0)) { $0 &+ $1.sizeBytes }
                    self?.progress = nil
                }
                let backupResult = ImportEngine.executeBackup(plan: plan, options: options) { progress in
                    let snapshot = progress
                    Task { @MainActor in
                        self?.progress = snapshot
                    }
                }
                await MainActor.run {
                    self?.importResult = TwoPhaseResult(primary: primaryResult, backup: backupResult)
                    playCompletionChime()
                }
            }

            // Finalize: delete-confirm + auto-eject only AFTER all copying
            // (including backup) is done, so the SD card stays mounted
            // through both phases.
            await MainActor.run {
                guard let self = self else { return }
                self.importing = false
                self.currentPhase = nil
                self.phaseMessage = "All done."
                self.eligibleSources = localEligible
                if let opts = self.runOptions {
                    if opts.deleteAfter && !localEligible.isEmpty {
                        self.deleteConfirm = DeleteConfirmState(
                            paths: localEligible,
                            verified: opts.verify,
                            volumeMount: opts.volumeMount
                        )
                    } else if opts.autoEject {
                        self.doEject(mountPoint: opts.volumeMount)
                    }
                }
            }
        }
    }

    // MARK: - Post-import delete

    func confirmDelete() {
        guard let state = deleteConfirm else { return }
        let paths = state.paths
        let mount = state.volumeMount
        deleteConfirm = nil
        // Hold the card's security scope (if sandboxed) so deleting source
        // files off the card succeeds. nil in dev builds.
        let cardAccess = cardAccessStore.resolve(forMountPath: mount.path)
        Task.detached(priority: .userInitiated) { [weak self, cardAccess] in
            defer { cardAccess?.stop() }
            let r = Deletion.deleteSources(paths)
            await MainActor.run {
                self?.deleteResult = r
                if self?.runOptions?.autoEject == true {
                    self?.doEject(mountPoint: mount)
                }
            }
        }
    }

    func cancelDelete() {
        let mount = deleteConfirm?.volumeMount
        deleteConfirm = nil
        if let mount = mount, runOptions?.autoEject == true {
            doEject(mountPoint: mount)
        }
    }
}
