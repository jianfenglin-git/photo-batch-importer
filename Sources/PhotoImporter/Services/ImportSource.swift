import Foundation

/// Where an import reads its source bytes from. The engine only ever reads a
/// source front to back, so this is all it needs: a card hands out
/// `FileHandle`s, a connected iPhone or camera streams over ImageCaptureCore
/// (`DeviceImportSource`). Destinations are always local files.
protocol ImportSource {
    func exists(_ url: URL) -> Bool
    /// Byte length, or nil when it can't be determined. Only used as a cheap
    /// "can't be identical" gate before hashing; `open` gives the
    /// authoritative length.
    func size(of url: URL) -> UInt64?
    /// Creation and modification dates to carry over to the copy, so Finder
    /// shows when the photo was taken rather than when it was imported.
    func dates(of url: URL) -> SourceDates
    func open(_ url: URL) throws -> SourceReader
}

struct SourceDates: Equatable {
    var created: Date?
    var modified: Date?
}

/// Sequential reader over one source file.
protocol SourceReader: AnyObject {
    /// Exact length of what is about to be read. The copy loop asserts it
    /// streamed exactly this many bytes (see `streamingCopyAndHash`).
    var length: UInt64 { get }
    /// The next chunk, or empty at end of file.
    func read() throws -> Data
    func close()
}

/// Files on a mounted card (or any local path).
struct FileImportSource: ImportSource {
    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func size(of url: URL) -> UInt64? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return nil
        }
        return UInt64(size)
    }

    func dates(of url: URL) -> SourceDates {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return SourceDates(created: values?.creationDate, modified: values?.contentModificationDate)
    }

    func open(_ url: URL) throws -> SourceReader {
        try FileSourceReader(url: url)
    }
}

final class FileSourceReader: SourceReader {
    /// Read granularity for local files.
    static let chunkSize = 64 * 1024

    private let handle: FileHandle
    let length: UInt64

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        // Length of exactly the file we're about to read, from the same
        // descriptor rather than a separate stat, so nothing can swap the
        // file out in between. Not `item.sizeBytes` — that was measured at
        // scan time and may be stale.
        length = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
    }

    /// `read(upToCount:)` bridges -[NSFileHandle readDataOfLength:], whose
    /// NSData is autoreleased — callers drain a pool per chunk (GitHub #2).
    func read() throws -> Data {
        try handle.read(upToCount: Self.chunkSize) ?? Data()
    }

    func close() {
        try? handle.close()
    }
}
