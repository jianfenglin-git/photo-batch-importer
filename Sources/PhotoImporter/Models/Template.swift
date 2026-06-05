import Foundation

/// Naming-template DSL.
///
/// Syntax: `{token}` or `{token:format}`. Literal text and `/` pass through;
/// `/` creates subdirectories. Unknown tokens cause `parse` to throw.
enum TemplateToken: Hashable {
    case date(String)           // format: YYYY, YY, MM, DD, HH, mm, ss (greedy)
    case time(String)
    case cameraMake
    case cameraModel
    case cameraSerial
    case cameraOwner
    case lens
    case iso
    case shutter
    case aperture
    case focalLength
    case subSecond
    case seq(Int)               // padding width
    case fileStem
    case fileExt
    case fileName
    case cardLabel
}

enum TemplateSegment: Hashable {
    case literal(String)
    case token(TemplateToken)
}

enum TemplateError: Error, LocalizedError, Equatable {
    case unterminated
    case unknownToken(String)
    case seqRequiresPadding

    var errorDescription: String? {
        switch self {
        case .unterminated:
            return "Unterminated `{` in template."
        case .unknownToken(let t):
            return "Unknown token: \(t)"
        case .seqRequiresPadding:
            return "`{seq}` requires a padding width, e.g. {seq:000000}"
        }
    }
}

enum Template {
    /// The placeholder inserted when a token's value is missing.
    static let unknown = "unknown"

    static func parse(_ s: String) throws -> [TemplateSegment] {
        var segments: [TemplateSegment] = []
        var literal = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "{" {
                if !literal.isEmpty {
                    segments.append(.literal(literal))
                    literal.removeAll()
                }
                guard let end = s[i...].firstIndex(of: "}") else {
                    throw TemplateError.unterminated
                }
                let inner = String(s[s.index(after: i)..<end])
                segments.append(.token(try parseToken(inner)))
                i = s.index(after: end)
            } else {
                literal.append(c)
                i = s.index(after: i)
            }
        }
        if !literal.isEmpty {
            segments.append(.literal(literal))
        }
        return segments
    }

    private static func parseToken(_ inner: String) throws -> TemplateToken {
        let (name, fmt) = splitOnce(inner, on: ":")
        switch name {
        case "date":
            return .date(fmt ?? "YYYY-MM-DD")
        case "time":
            return .time(fmt ?? "HH-mm-ss")
        case "camera.make": return .cameraMake
        case "camera.model": return .cameraModel
        case "camera.serial": return .cameraSerial
        case "camera.owner": return .cameraOwner
        case "lens": return .lens
        case "iso": return .iso
        case "shutter": return .shutter
        case "aperture": return .aperture
        case "focal-length": return .focalLength
        case "fl": return .focalLength     // legacy alias, kept for existing presets
        case "sub-second": return .subSecond
        case "seq":
            guard let fmt = fmt, !fmt.isEmpty else {
                throw TemplateError.seqRequiresPadding
            }
            // Check the all-zeros padded form first — "000000" means "pad to
            // 6 digits", NOT "pad to zero digits" (which is what
            // `Int("000000")` would produce if we went numeric-first).
            if fmt.allSatisfy({ $0 == "0" }) { return .seq(fmt.count) }
            if let width = Int(fmt), width >= 1 { return .seq(width) }
            throw TemplateError.unknownToken("seq:\(fmt)")
        case "file.stem": return .fileStem
        case "file.ext": return .fileExt
        case "file.name": return .fileName
        case "card.label": return .cardLabel
        default:
            throw TemplateError.unknownToken(inner)
        }
    }

    private static func splitOnce(_ s: String, on ch: Character) -> (String, String?) {
        if let idx = s.firstIndex(of: ch) {
            return (String(s[..<idx]), String(s[s.index(after: idx)...]))
        }
        return (s, nil)
    }

    /// Evaluate a parsed template against a photo. Returns a relative path
    /// (URL components), OS-agnostic: `/` in the *template* splits into
    /// directories, `/` appearing inside a rendered *value* is converted to
    /// `-` so unintended subdirs aren't created.
    static func evaluate(
        _ segments: [TemplateSegment],
        photo: PhotoFile,
        seq: UInt64,
        cardLabel: String
    ) -> String {
        let raw = segments.map { renderSegment($0, photo: photo, seq: seq, cardLabel: cardLabel) }.joined()
        // Split on '/' and filesafe each component; drop empty runs (leading/
        // trailing / and repeated //). Forbidden characters within a
        // component become '_'; a literal '..' path traversal becomes '_'.
        let parts = raw.split(separator: "/", omittingEmptySubsequences: true).map { filesafe(String($0)) }
        return parts.joined(separator: "/")
    }

    private static func renderSegment(_ seg: TemplateSegment, photo: PhotoFile, seq: UInt64, cardLabel: String) -> String {
        switch seg {
        case .literal(let s): return s
        case .token(let t): return renderToken(t, photo: photo, seq: seq, cardLabel: cardLabel)
        }
    }

    private static func renderToken(_ token: TemplateToken, photo: PhotoFile, seq: UInt64, cardLabel: String) -> String {
        switch token {
        case .date(let fmt), .time(let fmt):
            return formatDate(photo.meta.date, fmt: fmt)
        case .cameraMake: return sanitizePathSep(photo.meta.cameraMake ?? unknown)
        case .cameraModel: return sanitizePathSep(photo.meta.cameraModel ?? unknown)
        case .cameraSerial: return sanitizePathSep(photo.meta.cameraSerial ?? unknown)
        case .cameraOwner: return sanitizePathSep(photo.meta.cameraOwner ?? unknown)
        case .lens: return sanitizePathSep(photo.meta.lens ?? unknown)
        case .iso: return photo.meta.iso.map(String.init) ?? unknown
        case .shutter: return sanitizePathSep(normalizeSingle(photo.meta.shutter))
        case .aperture: return sanitizePathSep(normalizeSingle(photo.meta.aperture))
        case .focalLength: return sanitizePathSep(normalizeSingle(photo.meta.focalLength))
        case .subSecond: return sanitizePathSep(photo.meta.subSecond ?? unknown)
        case .seq(let pad):
            let s = String(seq)
            return s.count >= pad ? s : String(repeating: "0", count: pad - s.count) + s
        case .fileStem:
            return sanitizePathSep(photo.path.deletingPathExtension().lastPathComponent)
        case .fileExt:
            return sanitizePathSep(photo.path.pathExtension)
        case .fileName:
            return sanitizePathSep(photo.path.lastPathComponent)
        case .cardLabel:
            return sanitizePathSep(cardLabel)
        }
    }

    private static func normalizeSingle(_ s: String?) -> String {
        guard let s = s, !s.isEmpty else { return unknown }
        return s.replacingOccurrences(of: " ", with: "_")
    }

    /// Replace path-separator chars inside a rendered value with `-`. A `/`
    /// typed in the template is intentional (creates a subdir); a `/` coming
    /// from a *value* (e.g. "AF 27/1.2" lens name) is not.
    private static func sanitizePathSep(_ s: String) -> String {
        guard s.contains("/") || s.contains("\\") else { return s }
        return String(s.map { $0 == "/" || $0 == "\\" ? Character("-") : $0 })
    }

    /// Strip characters that are problematic on Windows and/or macOS.
    private static func filesafe(_ component: String) -> String {
        var out = ""
        out.reserveCapacity(component.count)
        for ch in component {
            switch ch {
            case "<", ">", ":", "\"", "\\", "|", "?", "*", "\0":
                out.append("_")
            default:
                if let scalar = ch.unicodeScalars.first, scalar.value < 0x20 {
                    out.append("_")
                } else {
                    out.append(ch)
                }
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if trimmed.isEmpty || trimmed == "." || trimmed == ".." {
            return "_"
        }
        return trimmed
    }

    private static func formatDate(_ date: Date?, fmt: String) -> String {
        guard let date = date else { return unknown }
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = comps.year ?? 0
        let month = comps.month ?? 0
        let day = comps.day ?? 0
        let hour = comps.hour ?? 0
        let minute = comps.minute ?? 0
        let second = comps.second ?? 0

        // Greedy match: longer specifiers first. Matches the original Rust
        // format implementation exactly so templates are compatible.
        var out = ""
        var i = fmt.startIndex
        func starts(_ prefix: String) -> Bool {
            fmt[i...].hasPrefix(prefix)
        }
        while i < fmt.endIndex {
            if starts("YYYY") {
                out.append(String(format: "%04d", year))
                i = fmt.index(i, offsetBy: 4)
            } else if starts("YY") {
                out.append(String(format: "%02d", year % 100))
                i = fmt.index(i, offsetBy: 2)
            } else if starts("MM") {
                out.append(String(format: "%02d", month))
                i = fmt.index(i, offsetBy: 2)
            } else if starts("DD") {
                out.append(String(format: "%02d", day))
                i = fmt.index(i, offsetBy: 2)
            } else if starts("HH") {
                out.append(String(format: "%02d", hour))
                i = fmt.index(i, offsetBy: 2)
            } else if starts("mm") {
                out.append(String(format: "%02d", minute))
                i = fmt.index(i, offsetBy: 2)
            } else if starts("ss") {
                out.append(String(format: "%02d", second))
                i = fmt.index(i, offsetBy: 2)
            } else {
                out.append(fmt[i])
                i = fmt.index(after: i)
            }
        }
        return out
    }
}
