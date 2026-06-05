import Foundation

/// Chips shown inline under the template textarea.
struct TokenDescriptor: Hashable {
    let label: String
    let token: String
    let description: String
}

enum TokenCatalog {
    /// Chips shown in the main token row, left of "Show all…".
    /// The `Seq` chip lives separately (to the right of "Show all…") because
    /// it's paired with an editable sequence counter text field.
    static let common: [TokenDescriptor] = [
        .init(label: "Date", token: "{date:YYYY-MM-DD}", description: "Photo taken date (2026-05-03)"),
        .init(label: "Time", token: "{time:HH-mm-ss}", description: "Photo taken time (14-22-01)"),
        .init(label: "Camera model", token: "{camera.model}", description: "e.g. Canon EOS R5"),
        .init(label: "Lens", token: "{lens}", description: "Lens model"),
        .init(label: "ISO", token: "{iso}", description: "ISO value"),
        .init(label: "File name", token: "{file.name}", description: "Original file name"),
        .init(label: "File ext", token: "{file.ext}", description: "Original extension"),
    ]

    static let seqDescriptor = TokenDescriptor(
        label: "Seq",
        token: "{seq:000000}",
        description: "Import sequence number (6-digit padded)"
    )

    struct Group: Hashable {
        let heading: String
        let tokens: [TokenDescriptor]
    }

    static let all: [Group] = [
        .init(heading: "Date", tokens: [
            .init(label: "{date:YYYY-MM-DD}", token: "{date:YYYY-MM-DD}", description: "2026-05-03"),
            .init(label: "{date:YYYY}", token: "{date:YYYY}", description: "2026"),
            .init(label: "{date:YYYY-MM}", token: "{date:YYYY-MM}", description: "2026-05"),
            .init(label: "{date:MM}", token: "{date:MM}", description: "05 — month number"),
            .init(label: "{date:DD}", token: "{date:DD}", description: "03 — day of month"),
            .init(label: "{date:YYYYMMDD}", token: "{date:YYYYMMDD}", description: "20260503"),
            .init(label: "{date:YY-MM-DD}", token: "{date:YY-MM-DD}", description: "26-05-03"),
        ]),
        .init(heading: "Time", tokens: [
            .init(label: "{time:HH-mm-ss}", token: "{time:HH-mm-ss}", description: "14-22-01"),
            .init(label: "{time:HHmmss}", token: "{time:HHmmss}", description: "142201"),
            .init(label: "{time:HH-mm}", token: "{time:HH-mm}", description: "14-22"),
            .init(label: "{sub-second}", token: "{sub-second}", description: "Sub-second timestamp, e.g. 123 ms — useful for bursts"),
        ]),
        .init(heading: "Camera", tokens: [
            .init(label: "{camera.make}", token: "{camera.make}", description: "Canon, FUJIFILM, …"),
            .init(label: "{camera.model}", token: "{camera.model}", description: "EOS R5, X-T5, …"),
            .init(label: "{camera.serial}", token: "{camera.serial}", description: "Camera body serial number"),
            .init(label: "{camera.owner}", token: "{camera.owner}", description: "Camera owner name, as set in the body's settings"),
        ]),
        .init(heading: "Lens & exposure", tokens: [
            .init(label: "{lens}", token: "{lens}", description: "Lens model"),
            .init(label: "{iso}", token: "{iso}", description: "ISO value"),
            .init(label: "{shutter}", token: "{shutter}", description: "Exposure time, e.g. 1/200"),
            .init(label: "{aperture}", token: "{aperture}", description: "F-number, e.g. 5.6"),
            .init(label: "{focal-length}", token: "{focal-length}", description: "Focal length, e.g. 50 mm"),
        ]),
        .init(heading: "File", tokens: [
            .init(label: "{file.name}", token: "{file.name}", description: "IMG_0001.CR3"),
            .init(label: "{file.stem}", token: "{file.stem}", description: "IMG_0001"),
            .init(label: "{file.ext}", token: "{file.ext}", description: "CR3"),
        ]),
        .init(heading: "Sequence", tokens: [
            .init(label: "{seq:0}", token: "{seq:0}", description: "1, 2, 3, …"),
            .init(label: "{seq:000}", token: "{seq:000}", description: "001, 002, …"),
            .init(label: "{seq:000000}", token: "{seq:000000}", description: "000001, 000002, …"),
        ]),
        .init(heading: "Card", tokens: [
            .init(label: "{card.label}", token: "{card.label}", description: "Removable volume name"),
        ]),
    ]
}
