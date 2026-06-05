import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    CardSection()
                    DestinationSection()
                    TemplateSection()
                    PhotoTableSection()
                    OptionsSection()
                    ActionsSection()
                    ProgressAndResultSection()
                    // Sentinel — used by scrollTo(.bottom) after the import
                    // finishes so the result grid is visible without the
                    // user having to scroll.
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(12)
            }
            // Scroll to the bottom every time the copy state transitions —
            // primary starts, backup starts, or everything finishes — so
            // the user always sees the latest progress / results without
            // having to scroll manually.
            .onChange(of: vm.currentPhase) { _, phase in
                // nil → some  : a phase started (primary or backup)
                // some → nil  : copying finished entirely (handled below)
                if phase != nil {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .onChange(of: vm.importing) { _, importing in
                if !importing && vm.importResult != nil {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
        // Busy overlay while scanning: dims the UI, absorbs clicks, and
        // shows a spinner so the user gets immediate feedback on card
        // selection (scanning can take several seconds on a big card).
        .overlay {
            if vm.scanning {
                ZStack {
                    Color.black.opacity(0.15)
                    ProgressView()
                        .controlSize(.large)
                        .padding(20)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(nsColor: .windowBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                }
                .contentShape(Rectangle())
                .ignoresSafeArea()
            }
        }
        // Dismiss per-volume eject errors on any click anywhere.
        .background(
            ClickCatcher { vm.clearEjectErrors() }
                .allowsHitTesting(!vm.ejectErrors.isEmpty)
        )
        // Sheets
        .sheet(item: $vm.preflightError) { pf in PreflightErrorSheet(preflight: pf) }
        .sheet(item: $vm.presetDeleteConfirm) { p in PresetDeleteSheet(preset: p) }
        .sheet(isPresented: Binding(
            get: { vm.deleteConfirm != nil },
            set: { if !$0 { vm.deleteConfirm = nil } }
        )) {
            if let state = vm.deleteConfirm { DeleteConfirmSheet(state: state) }
        }
        .sheet(isPresented: Binding(
            get: { vm.presetSaveSheet != nil },
            set: { if !$0 { vm.presetSaveSheet = nil } }
        )) {
            if vm.presetSaveSheet != nil { PresetSaveSheet() }
        }
        .sheet(isPresented: $vm.showAllTokens) { AllTokensSheet() }
    }
}

// Make sheet items Identifiable where needed.
extension Preflight: Identifiable {
    var id: String { "\(requiredBytes)/\(availableBytes)" }
}

/// A transparent click-through layer that calls `onClick` on any mouse-down.
/// Used to dismiss eject error messages on any background click.
private struct ClickCatcher: NSViewRepresentable {
    var onClick: () -> Void
    func makeNSView(context: Context) -> NSView { ClickView(onClick: onClick) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ClickView)?.onClick = onClick
    }
    private final class ClickView: NSView {
        var onClick: () -> Void
        init(onClick: @escaping () -> Void) {
            self.onClick = onClick
            super.init(frame: .zero)
            wantsLayer = false
        }
        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil } // pass clicks through
        override func mouseDown(with event: NSEvent) { onClick() }
    }
}

// MARK: - Card section

private struct CardSection: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        SectionHeader {
            HStack {
                Text("Card").sectionStyle()
                Text("\(vm.volumes.count) detected")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { vm.volumeWatcher.refresh() }
                    .controlSize(.small)
            }
        }
        if vm.volumes.isEmpty {
            Text("No removable volumes. Insert a card and click Refresh.")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        } else {
            ForEach(vm.volumes) { volume in
                CardRow(volume: volume)
            }
        }
    }
}

private struct CardRow: View {
    let volume: Volume
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        let isSelected = vm.selectedVolume?.id == volume.id
        let ejecting = vm.ejectingMounts.contains(volume.mountPoint.path)
        let error = vm.ejectErrors[volume.mountPoint.path]

        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(volume.label)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                if let error {
                    Text("Eject failed: \(error)")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                Text(volume.mountPoint.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text("\(formatBytes(volume.totalBytes - volume.availableBytes)) / \(formatBytes(volume.totalBytes))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Button(ejecting ? "Ejecting…" : "Eject") {
                vm.doEject(mountPoint: volume.mountPoint)
            }
            .controlSize(.small)
            .disabled(ejecting)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { vm.selectVolume(volume) }
    }
}

// MARK: - Destination section

private struct DestinationSection: View {
    @EnvironmentObject private var vm: AppViewModel
    var body: some View {
        SectionHeader { Text("Destination").sectionStyle() }
        HStack(spacing: 8) {
            Button("Choose folder…") { vm.pickDestination() }
                .controlSize(.small)
            Text(vm.destination?.displayPath ?? "(not set)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(vm.destination?.displayPath ?? "")
        }
    }
}

// MARK: - Template section (3 rules)

private struct TemplateSection: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        SectionHeader {
            HStack {
                Text("Naming template").sectionStyle()
                Text("rules match top-down; first match wins")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        // Preset controls live inline above the 3 rule rows: the picker
        // is always non-empty (invariant enforced by the view model), so
        // no "None" option is offered.
        HStack(spacing: 6) {
            Picker("", selection: Binding(
                get: { vm.activePresetID ?? (vm.presetStore.presets.first?.id ?? "") },
                set: { vm.onPresetPick($0) }
            )) {
                ForEach(vm.presetStore.presets) { p in
                    Text(p.name).tag(p.id)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 240, alignment: .leading)

            if vm.activePreset != nil {
                Button("Rename") { vm.openPresetUpdate() }
                    .controlSize(.small)
            }
            Button("Save as…") { vm.openPresetSaveNew() }
                .controlSize(.small)
            if let active = vm.activePreset {
                Button("Delete") { vm.confirmPresetDelete(active) }
                    .controlSize(.small)
            }
            Spacer()
        }

        VStack(spacing: 4) {
            ForEach(Array(vm.rules.enumerated()), id: \.element.id) { (idx, _) in
                TemplateRuleRow(index: idx)
            }
        }
        FlowLayout(spacing: 4) {
            ForEach(TokenCatalog.common, id: \.self) { t in
                ChipButton(label: t.label, tooltip: "\(t.token) — \(t.description)") {
                    vm.insertToken(t.token)
                }
            }
            ChipButton(
                label: TokenCatalog.seqDescriptor.label,
                tooltip: "\(TokenCatalog.seqDescriptor.token) — \(TokenCatalog.seqDescriptor.description)"
            ) {
                vm.insertToken(TokenCatalog.seqDescriptor.token)
            }
            SequenceCounterField(sequenceStore: vm.sequenceStore)
            ChipButton(label: "Show all…", style: .secondary, tooltip: "Open the full catalogue") {
                vm.showAllTokens = true
            }
        }
    }
}

/// Editable text field that shows the value `{seq}` will use on the next
/// import. Reads the store (for display); writes via the view model so
/// the preview column is guaranteed to refresh after a user edit.
private struct SequenceCounterField: View {
    @EnvironmentObject private var vm: AppViewModel
    @ObservedObject var sequenceStore: SequenceStore
    @State private var draft: String = ""
    /// The draft value at the moment the field gained focus. We only treat
    /// the field as "edited" (and commit to the store on blur) when the
    /// final draft differs from this snapshot. Without this guard, a
    /// background import that bumps `lastSeq` while the user has idle
    /// focus would get clobbered on blur — the blur would parse the stale
    /// visible number and push the counter backwards.
    @State private var focusSnapshot: String = ""
    @FocusState private var focused: Bool
    /// In-flight debounce task; reset on every keystroke so the commit
    /// fires ~3s after the user's LAST edit, not their first.
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))
            .frame(width: 72)
            .focused($focused)
            .help("Next sequence number. Edit to align with an existing photo library.")
            .onAppear { draft = String(sequenceStore.nextStart()) }
            .onChange(of: draft) { _, _ in
                // Only schedule the debounced commit while the user is
                // actively focused in this field — avoids firing when the
                // draft changes because WE (the sync path) overwrote it.
                guard focused else { return }
                debounceTask?.cancel()
                debounceTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if !Task.isCancelled {
                        commitIfEdited()
                    }
                }
            }
            .onChange(of: sequenceStore.lastSeq) { _, _ in
                // Always reflect an external change when unfocused. When
                // focused we can't override the user's in-progress input,
                // but we DO quietly update the focus snapshot so a
                // subsequent blur-with-no-typing doesn't treat the new
                // counter value as a user edit.
                let canonical = String(sequenceStore.nextStart())
                if !focused {
                    draft = canonical
                } else if draft == focusSnapshot {
                    // User hasn't typed since focusing — silently update
                    // both the visible field and the snapshot.
                    draft = canonical
                    focusSnapshot = canonical
                }
            }
            .onChange(of: focused) { wasFocused, isFocused in
                if isFocused && !wasFocused {
                    focusSnapshot = draft
                } else if wasFocused && !isFocused {
                    debounceTask?.cancel()
                    commitIfEdited()
                }
            }
            .onSubmit {
                debounceTask?.cancel()
                commitIfEdited()
                focused = false
            }
    }

    private func commitIfEdited() {
        let canonical = String(sequenceStore.nextStart())
        // No user edit → just resync to the canonical value, don't write.
        if draft == focusSnapshot {
            draft = canonical
            focusSnapshot = canonical
            return
        }
        // User typed something. Parse and commit.
        guard let parsed = UInt64(draft.trimmingCharacters(in: .whitespaces)), parsed >= 1 else {
            draft = canonical
            focusSnapshot = canonical
            return
        }
        vm.setSequenceStart(parsed)
        let committed = String(sequenceStore.nextStart())
        draft = committed
        focusSnapshot = committed
    }
}

private struct TemplateRuleRow: View {
    let index: Int
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        let isFocused = vm.focusedRuleIndex == index
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                Picker("", selection: Binding(
                    get: { vm.rules[index].fileType },
                    set: { vm.rules[index].fileType = $0 }
                )) {
                    ForEach(FileType.allCases) { t in
                        Text(t.label).tag(t)
                    }
                }
                .labelsHidden()
                .frame(width: 86, alignment: .leading)
                .controlSize(.small)
                .help(vm.rules[index].fileType.tooltip)

                CursorTextEditor(
                    text: Binding(
                        get: { vm.rules[index].template },
                        set: { vm.rules[index].template = $0 }
                    ),
                    selectedRange: Binding(
                        get: { vm.ruleSelections[index] ?? NSRange(location: 0, length: 0) },
                        set: { vm.ruleSelections[index] = $0 }
                    ),
                    onFocus: { vm.focusedRuleIndex = index }
                )
                .frame(minHeight: 24, maxHeight: 28)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(
                            isFocused ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: isFocused ? 1.5 : 1
                        )
                )

                BackupFolderButton(index: index)
            }
            if let err = vm.ruleErrors[index] {
                Text(err)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 92)
                    .padding(.top, 2)
            }
        }
    }
}

/// Per-rule "Backup folder…" button. Click opens a folder picker; once a
/// folder is set the button shows the path (truncated middle). Right-click
/// / long-press gives a context menu to clear the selection.
private struct BackupFolderButton: View {
    let index: Int
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        let folder = vm.rules[index].backupFolder
        Button(action: { vm.pickBackupFolder(forRuleAt: index) }) {
            Text(folder?.displayPath ?? "Backup folder…")
                .font(.system(size: 11, design: folder == nil ? .default : .monospaced))
                .foregroundStyle(folder == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 90, alignment: .leading)
        }
        .controlSize(.small)
        .help(folder?.displayPath ?? "Choose a folder to mirror every copied file into (same relative path under a different root)")
        .contextMenu {
            Button("Choose folder…") { vm.pickBackupFolder(forRuleAt: index) }
            if folder != nil {
                Divider()
                Button("Clear backup folder") { vm.clearBackupFolder(forRuleAt: index) }
            }
        }
    }
}

enum ChipStyle { case primary, secondary }

struct ChipButton: View {
    let label: String
    var style: ChipStyle = .primary
    var tooltip: String? = nil
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
        }
        .buttonStyle(ChipButtonStyle(style: style, hovering: hovering))
        .onHover { hovering = $0 }
        .help(tooltip ?? "")
    }
}

struct ChipButtonStyle: ButtonStyle {
    var style: ChipStyle
    var hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        let bg: Color = {
            switch style {
            case .primary:
                if configuration.isPressed { return Color(red: 0.117, green: 0.251, blue: 0.686) }   // #1e40af
                if hovering { return Color.accentColor }
                return Color.accentColor.opacity(0.18)
            case .secondary:
                if configuration.isPressed { return Color.gray.opacity(0.6) }
                if hovering { return Color.gray.opacity(0.5) }
                return Color.gray.opacity(0.18)
            }
        }()
        let fg: Color = {
            switch style {
            case .primary:
                return hovering || configuration.isPressed ? .white : Color.accentColor
            case .secondary:
                return hovering || configuration.isPressed ? .white : .primary
            }
        }()
        return configuration.label
            .foregroundStyle(fg)
            .background(bg)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(bg, lineWidth: 1))
            .animation(.easeOut(duration: 0.06), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.06), value: hovering)
    }
}

// MARK: - Options section

private struct OptionsSection: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        SectionHeader { Text("Options").sectionStyle() }
        HStack {
            Text("Collision:")
                .font(.system(size: 11))
            Picker("", selection: $vm.collisionPolicy) {
                ForEach(CollisionPolicy.allCases) { p in
                    Text(p.label).tag(p)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(maxWidth: 260)
            Spacer()
        }
        Toggle("Verify each file after copy", isOn: $vm.verify)
            .controlSize(.small)
        Toggle("Permanently delete from card after import (confirms before deleting)", isOn: $vm.deleteAfter)
            .controlSize(.small)
        Toggle("Eject card after import", isOn: $vm.autoEject)
            .controlSize(.small)
    }
}

// MARK: - Actions + progress

private struct ActionsSection: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                vm.startImport()
            } label: {
                Text(buttonLabel)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
            }
            // `.keyboardShortcut(.defaultAction)` marks this as the window's
            // default button — renders blue when the window is key and
            // falls back to the standard grey/black style when not, instead
            // of the prominent style which can vanish on inactive windows.
            .buttonStyle(.bordered)
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .disabled(!vm.canImport)

            if let msg = vm.phaseMessage {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    private var buttonLabel: String {
        guard vm.importing else { return "Start import (\(vm.selectedPhotos.count))" }
        switch vm.currentPhase {
        case .primary: return "Importing…"
        case .backup: return "Backing up…"
        case nil: return "Importing…"
        }
    }
}

private struct ProgressAndResultSection: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        if vm.importing || vm.progress != nil || vm.importResult != nil {
            VStack(alignment: .leading, spacing: 6) {
                let total = vm.totalBytesPlanned
                let done = vm.progress?.bytesDone ?? 0
                let pct: Double = total > 0 ? min(1.0, Double(done) / Double(total)) : 0
                // Fresh ProgressView instance per phase — .id() forces
                // SwiftUI to re-create the view rather than animate from
                // 100% back down to 0% between the primary and backup
                // phases (which share a single bar slot in the layout).
                ProgressView(value: pct)
                    .id(vm.currentPhase?.rawValue ?? "idle")
                HStack {
                    let itemsNow = vm.progress.map { $0.itemIndex + 1 } ?? 0
                    Text("\(itemsNow) / \(vm.totalItemsPlanned)")
                        .font(.system(size: 11, design: .monospaced))
                    Spacer()
                    Text("\(formatBytes(done)) / \(formatBytes(total))")
                        .font(.system(size: 11, design: .monospaced))
                }
                .foregroundStyle(.secondary)

                if let r = vm.importResult {
                    ResultGrid(twoPhase: r, deleteResult: vm.deleteResult)
                    FailuresList(twoPhase: r, deleteResult: vm.deleteResult)
                }
            }
        }
    }
}

/// Collapsible list of per-item error messages from both import phases
/// and the post-import delete. Shown whenever any failures occurred.
private struct FailuresList: View {
    let twoPhase: TwoPhaseResult
    let deleteResult: DeleteResult?

    var body: some View {
        let primaryFailures = twoPhase.primary.failures
        let backupFailures = twoPhase.backup?.failures ?? []
        let deleteFailures = deleteResult?.failures ?? []
        if primaryFailures.isEmpty && backupFailures.isEmpty && deleteFailures.isEmpty {
            EmptyView()
        } else {
            let total = primaryFailures.count + backupFailures.count + deleteFailures.count
            DisclosureGroup("Errors (\(total))") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(primaryFailures.enumerated()), id: \.offset) { _, pair in
                        failureRow(label: "Primary", path: pair.0, message: pair.1)
                    }
                    ForEach(Array(backupFailures.enumerated()), id: \.offset) { _, pair in
                        failureRow(label: "Backup", path: pair.0, message: pair.1)
                    }
                    ForEach(Array(deleteFailures.enumerated()), id: \.offset) { _, pair in
                        failureRow(label: "Delete", path: pair.0, message: pair.1)
                    }
                }
                .padding(.top, 4)
            }
            .font(.system(size: 12).weight(.semibold))
            .foregroundStyle(.red)
            .padding(.top, 6)
        }
    }

    private func failureRow(label: String, path: URL, message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.red)
                .frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(path.lastPathComponent.isEmpty ? path.path : path.lastPathComponent)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path.path)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Two-row result grid when a backup phase ran. Single-row otherwise.
/// The extra "Deleted from card" stat slots into its own row below.
private struct ResultGrid: View {
    let twoPhase: TwoPhaseResult
    let deleteResult: DeleteResult?

    var body: some View {
        VStack(spacing: 6) {
            row(label: twoPhase.backup == nil ? nil : "Primary:", result: twoPhase.primary)
            if let b = twoPhase.backup {
                row(label: "Backup:", result: b)
            }
            if let d = deleteResult, d.deleted > 0 {
                HStack {
                    Text("Deleted from card")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    Text("\(d.deleted)")
                        .font(.system(size: 15, design: .monospaced).weight(.semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
    }

    @ViewBuilder
    private func row(label: String?, result: ImportResult) -> some View {
        HStack(spacing: 6) {
            if let label {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 64, alignment: .leading)
            }
            stat("Copied", value: "\(result.copied)")
            stat("Skipped", value: "\(result.skipped)")
            stat("Overwritten", value: "\(result.overwritten)")
            if result.verified > 0 || result.verifyFailed > 0 {
                stat(
                    "Verified",
                    value: "\(result.verified)",
                    badge: result.verifyFailed > 0 ? " (\(result.verifyFailed) failed)" : nil
                )
            }
            stat("Failed", value: "\(result.failed)")
        }
    }

    private func stat(_ label: String, value: String, badge: String? = nil) -> some View {
        VStack(spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                Text(value)
                    .font(.system(size: 15, design: .monospaced).weight(.semibold))
                if let badge {
                    Text(badge)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - Helpers

struct SectionHeader<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(.top, 4)
            .padding(.bottom, 2)
    }
}

extension View {
    func sectionStyle() -> some View {
        // `.primary` adapts: pure label-color on macOS — black in light
        // mode, white in dark — matching the System Settings pattern
        // (previously this was `.secondary` grey).
        self.font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary)
            .textCase(.uppercase)
            .tracking(0.5)
    }
}

func formatBytes(_ n: Int64) -> String {
    let d = Double(n)
    if d >= 1e12 { return String(format: "%.1f TB", d / 1e12) }
    if d >= 1e9 { return String(format: "%.1f GB", d / 1e9) }
    if d >= 1e6 { return String(format: "%.1f MB", d / 1e6) }
    if d >= 1e3 { return String(format: "%.0f KB", d / 1e3) }
    return "\(n) B"
}

