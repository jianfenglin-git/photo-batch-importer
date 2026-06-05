import SwiftUI

struct DeleteConfirmSheet: View {
    @EnvironmentObject private var vm: AppViewModel
    let state: AppViewModel.DeleteConfirmState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permanently delete from card?")
                .font(.headline)
            Text("Permanently delete ")
                + Text("\(state.paths.count)").bold()
                + Text(" file\(state.paths.count == 1 ? "" : "s") from the card?")
            Text("Files are not moved to Trash — this action cannot be undone.")
                .font(.system(size: 12))
                .foregroundStyle(.red)
            Text(state.verified
                ? "All files were copied and verified (hash match with destination)."
                : "Files were copied but NOT verified. Enable 'Verify' next time for a stronger guarantee before deleting."
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { vm.cancelDelete() }
                Button("Permanently delete \(state.paths.count)") { vm.confirmDelete() }
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

struct PreflightErrorSheet: View {
    @EnvironmentObject private var vm: AppViewModel
    let preflight: Preflight

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Not enough space")
                .font(.headline)
                .foregroundStyle(.red)
            (Text("This import needs ")
                + Text(formatBytes(preflight.requiredBytes)).bold()
                + Text(" but the destination only has ")
                + Text(formatBytes(preflight.availableBytes)).bold()
                + Text(" free."))
            Text("Free up space on the destination or pick a different folder, then try again.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("OK") { vm.preflightError = nil }
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

struct PresetSaveSheet: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(vm.presetSaveSheet?.mode == .overwrite ? "Rename preset" : "Save preset")
                .font(.headline)
            Text("Current template, destination, and options will be stored.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("Preset name", text: Binding(
                get: { vm.presetSaveSheet?.name ?? "" },
                set: { new in
                    if var s = vm.presetSaveSheet { s.name = new; vm.presetSaveSheet = s }
                }
            ))
            .textFieldStyle(.roundedBorder)
            .onSubmit { vm.commitPresetSave() }
            HStack {
                Spacer()
                Button("Cancel") { vm.presetSaveSheet = nil }
                Button(vm.presetSaveSheet?.mode == .overwrite ? "Rename" : "Save") {
                    vm.commitPresetSave()
                }
                .disabled((vm.presetSaveSheet?.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

struct PresetDeleteSheet: View {
    @EnvironmentObject private var vm: AppViewModel
    let preset: Preset

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete preset?").font(.headline)
            (Text("Delete the preset ") + Text(preset.name).bold() + Text("?"))
            Text("The current form values will stay; only the saved preset is removed.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { vm.presetDeleteConfirm = nil }
                Button("Delete") { vm.commitPresetDelete() }
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

struct AllTokensSheet: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Template Properties").font(.headline)
            Text("Click a property to insert it at the cursor in the template.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(TokenCatalog.all, id: \.heading) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.heading.uppercased())
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .tracking(0.5)
                            FlowLayout(spacing: 4) {
                                ForEach(group.tokens, id: \.self) { t in
                                    ChipButton(label: t.label, tooltip: t.description) {
                                        vm.insertToken(t.token)
                                        vm.showAllTokens = false
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 260, maxHeight: 420)

            HStack {
                Spacer()
                Button("Close") { vm.showAllTokens = false }
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}

// Make Preset Identifiable for `.sheet(item:)` binding — it already has
// `id: String`, satisfied via the Identifiable conformance on the struct.
// No extra work needed; the extension above (Preflight) covers the only
// non-Identifiable type used with .sheet(item:).
