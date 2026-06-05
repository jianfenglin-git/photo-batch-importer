import SwiftUI

/// A decorated photo row that exposes sort-comparable key paths for the
/// destination column and date field.
struct PhotoRow: Identifiable, Hashable {
    var photo: PhotoFile
    var destination: String
    var id: String { photo.id }
    var sortDate: Date { photo.meta.date ?? .distantPast }
    var fileName: String { photo.path.lastPathComponent }
    var fileExt: String { photo.path.pathExtension.uppercased() }
}

struct PhotoTableSection: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var sortOrder: [KeyPathComparator<PhotoRow>] = [
        KeyPathComparator(\PhotoRow.sortDate, order: .forward),
    ]

    /// Message for the empty Photos pane. Distinguishes the states that
    /// previously all collapsed to "Scanning…": no card, awaiting a sandbox
    /// access grant, an error, an in-flight scan, and a genuinely empty card.
    private var emptyStateMessage: String {
        if vm.selectedVolume == nil {
            return "Select a card to list its photos."
        }
        if vm.needsCardAccess {
            return "Waiting for permission to read this card…"
        }
        if let err = vm.scanError {
            return err
        }
        if vm.scanning {
            return "Scanning…"
        }
        return "No photos found on this card."
    }

    var body: some View {
        SectionHeader {
            HStack(alignment: .center, spacing: 10) {
                Text("Photos").sectionStyle()
                Text(photos.isEmpty ? "—" : "\(vm.selectedPaths.count) of \(photos.count) selected")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if !photos.isEmpty {
                    Button("Select all") { vm.selectedPaths = Set(photos.map { $0.id }) }
                        .controlSize(.small)
                    Button("Deselect all") { vm.selectedPaths = [] }
                        .controlSize(.small)
                }
            }
        }

        if photos.isEmpty {
            Text(emptyStateMessage)
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
        } else {
            Table(sortedRows, selection: $vm.selectedPaths, sortOrder: $sortOrder) {
                TableColumn("") { row in
                    Toggle("", isOn: Binding(
                        get: { vm.selectedPaths.contains(row.id) },
                        set: { on in
                            if on { vm.selectedPaths.insert(row.id) }
                            else { vm.selectedPaths.remove(row.id) }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                }
                .width(28)

                // Column widths: `min == ideal` pins the starting width so
                // the columns don't stretch, while `max > ideal` still
                // enables the drag handle. Destination gets an explicit
                // very-wide ideal so SwiftUI routes any leftover horizontal
                // space to it rather than stretching the first three.
                // Date ideal 150 fits the 19-char "2026-05-03 14:22:01"
                // timestamp + cell padding at 11pt monospaced.
                TableColumn("Date taken", value: \.sortDate) { row in
                    Text(formatDateTime(row.photo.meta.date))
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                }
                .width(min: 150, ideal: 150, max: 240)

                TableColumn("File name", value: \.fileName) { row in
                    Text(row.fileName)
                        .font(.system(size: 11, design: .monospaced))
                        .truncationMode(.middle)
                        .lineLimit(1)
                        .help(row.photo.path.path)
                }
                .width(min: 100, ideal: 100, max: 400)

                TableColumn("Type", value: \.fileExt) { row in
                    Text(row.fileExt)
                        .font(.system(size: 11, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .width(min: 46, ideal: 46, max: 80)

                TableColumn("Destination file name", value: \.destination) { row in
                    Text(row.destination.isEmpty ? "—" : row.destination)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(row.destination.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.destination)
                }
                .width(min: 150, ideal: 400, max: .infinity)
            }
            .frame(minHeight: 180, idealHeight: 260, maxHeight: .infinity)
        }
    }

    private var photos: [PhotoFile] { vm.photos }

    private var sortedRows: [PhotoRow] {
        let rows = photos.map { p in
            PhotoRow(photo: p, destination: vm.destinations[p.id] ?? "")
        }
        return rows.sorted(using: sortOrder)
    }
}

func formatDateTime(_ date: Date?) -> String {
    guard let date = date else { return "—" }
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return fmt.string(from: date)
}
