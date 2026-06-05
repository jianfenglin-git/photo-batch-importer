import Foundation
import ImageIO
import CoreServices

/// Walks a volume and extracts metadata for every photo. Uses macOS's
/// `ImageIO` framework, which reads EXIF from every mainstream camera
/// format — including CR3 and HEIC — natively on macOS 13+.
enum PhotoScanner {
    /// Scan `root` recursively. Designed to run on a background queue;
    /// callers typically wrap in `Task.detached(priority: .userInitiated)`.
    /// Uses `FileType.allKnownExtensions` so videos are picked up alongside
    /// stills — the template-rule Video filter needs them in the scan list.
    static func scan(at root: URL) -> [PhotoFile] {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )
        guard let enumerator else { return [] }

        var results: [PhotoFile] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard FileType.allKnownExtensions.contains(ext) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile ?? false else { continue }
            let size = Int64(values?.fileSize ?? 0)
            let meta = extractMeta(from: url)
            results.append(PhotoFile(path: url, sizeBytes: size, meta: meta))
        }
        return results
    }

    static func extractMeta(from url: URL) -> PhotoMeta {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return mtimeFallback(url: url)
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let make = tiff?[kCGImagePropertyTIFFMake] as? String
        let model = tiff?[kCGImagePropertyTIFFModel] as? String
        let lens = (exif?[kCGImagePropertyExifLensModel] as? String)
            ?? (exif?["LensModel" as CFString] as? String)
        let serial = (exif?[kCGImagePropertyExifBodySerialNumber] as? String)
            ?? (exif?["BodySerialNumber" as CFString] as? String)
        let owner = (exif?[kCGImagePropertyExifCameraOwnerName] as? String)
            ?? (exif?["CameraOwnerName" as CFString] as? String)
        let subsec = (exif?[kCGImagePropertyExifSubsecTimeOriginal] as? String)
            ?? (exif?["SubsecTimeOriginal" as CFString] as? String)
        let iso: Int? = {
            if let arr = exif?[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber], let first = arr.first {
                return first.intValue
            }
            if let n = exif?[kCGImagePropertyExifISOSpeedRatings] as? NSNumber {
                return n.intValue
            }
            return nil
        }()
        let shutter: String? = (exif?[kCGImagePropertyExifExposureTime] as? NSNumber).map(rationalString(seconds:))
        let aperture: String? = (exif?[kCGImagePropertyExifFNumber] as? NSNumber).map { String(format: "%.1f", $0.doubleValue) }
        let fl: String? = (exif?[kCGImagePropertyExifFocalLength] as? NSNumber).map { String(format: "%.1f mm", $0.doubleValue) }

        var date: Date? = nil
        if let ds = exif?[kCGImagePropertyExifDateTimeOriginal] as? String {
            date = parseExifDateTime(ds)
        }
        if date == nil, let ds = exif?[kCGImagePropertyExifDateTimeDigitized] as? String {
            date = parseExifDateTime(ds)
        }
        if date == nil, let ds = tiff?[kCGImagePropertyTIFFDateTime] as? String {
            date = parseExifDateTime(ds)
        }

        let anyTag = date != nil || make != nil || model != nil || lens != nil
            || iso != nil || shutter != nil || aperture != nil || fl != nil
            || serial != nil || owner != nil || subsec != nil

        if !anyTag {
            return mtimeFallback(url: url)
        }
        // If ImageIO resolved some fields but not a date, still fall back to
        // mtime for the date so folder templates involving {date:...} work.
        let resolvedDate = date ?? fileMtime(url: url)
        return PhotoMeta(
            date: resolvedDate,
            cameraMake: make.nilIfEmpty,
            cameraModel: model.nilIfEmpty,
            cameraSerial: serial.nilIfEmpty,
            cameraOwner: owner.nilIfEmpty,
            lens: lens.nilIfEmpty,
            iso: iso,
            shutter: shutter.nilIfEmpty,
            aperture: aperture.nilIfEmpty,
            focalLength: fl.nilIfEmpty,
            subSecond: subsec.nilIfEmpty,
            fromExif: true
        )
    }

    private static func mtimeFallback(url: URL) -> PhotoMeta {
        PhotoMeta(
            date: fileMtime(url: url),
            cameraMake: nil, cameraModel: nil, cameraSerial: nil, cameraOwner: nil,
            lens: nil,
            iso: nil, shutter: nil, aperture: nil, focalLength: nil,
            subSecond: nil,
            fromExif: false
        )
    }

    private static func fileMtime(url: URL) -> Date? {
        let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return vals?.contentModificationDate
    }

    /// EXIF DateTime format: `YYYY:MM:DD HH:MM:SS` in local time.
    private static func parseExifDateTime(_ s: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: s.trimmingCharacters(in: .whitespaces))
    }

    /// Convert a shutter speed (e.g. 0.005) to its usual `1/200` rendering.
    private static func rationalString(seconds: NSNumber) -> String {
        let v = seconds.doubleValue
        if v <= 0 { return "0" }
        if v >= 1 {
            // "2.5" or "30"
            if v.rounded() == v { return "\(Int(v))" }
            return String(format: "%.1f", v)
        }
        let denom = Int((1.0 / v).rounded())
        return "1/\(denom)"
    }
}

private extension Optional where Wrapped == String {
    /// Trim surrounding whitespace and newlines, then nil out empties. EXIF
    /// values from some cameras arrive padded (e.g. `"AF 27-1.2 XF     "`
    /// from a Fuji lens tag); trailing whitespace in a path component is
    /// both ugly and surprising, so it gets stripped at the source.
    var nilIfEmpty: String? {
        switch self {
        case .some(let s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        case .none: return nil
        }
    }
}
