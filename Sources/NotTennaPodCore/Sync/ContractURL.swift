import Foundation

/// URL rules of the wire contract: URL normalization v1 (PROTOCOL §3.3) and the removal of userinfo
/// from URLs, whole or embedded in text (the server's docs/CONTRACT.md, `strip_userinfo`).
public enum ContractURL {
    /// URL normalization v1, a string algorithm rather than a URL parser, so every language agrees.
    /// A string without a `scheme:` prefix is returned unchanged. The scheme and host are lowercased
    /// (ASCII only, percent triplets in the host kept), a default or empty port and the fragment are
    /// removed; everything else is kept exactly. Idempotent for every string.
    public static func normalize(_ url: String) -> String {
        let bytes = Array(url.utf8)
        guard let colon = schemeEnd(bytes) else { return url }
        // Structural characters are ASCII, so working on UTF-8 bytes cuts only between characters.
        let scheme = bytes[..<colon].map(asciiLowercase)
        let rest = bytes[(colon + 1)...]
        var output = scheme
        output.append(UInt8(ascii: ":"))
        guard rest.starts(with: [0x2F, 0x2F]) else {
            output.append(contentsOf: rest.prefix { $0 != UInt8(ascii: "#") })
            return String(decoding: output, as: UTF8.self)
        }
        let body = rest.dropFirst(2)
        let authorityEnd = body.firstIndex { [UInt8(ascii: "/"), UInt8(ascii: "?"), UInt8(ascii: "#")].contains($0) } ?? body.endIndex
        let authority = body[..<authorityEnd]
        let after = body[authorityEnd...]
        let hostStart = authority.lastIndex(of: UInt8(ascii: "@")).map { authority.index(after: $0) } ?? authority.startIndex
        let userinfo = authority[..<hostStart]
        let hostPort = authority[hostStart...]
        var host = hostPort
        var port: ArraySlice<UInt8>?
        if hostPort.first == UInt8(ascii: "[") {
            if let close = hostPort.firstIndex(of: UInt8(ascii: "]")) {
                let tail = hostPort[(close + 1)...]
                if tail.first == UInt8(ascii: ":") {
                    host = hostPort[...close]
                    port = tail.dropFirst()
                }
            }
        } else if hostPort.count(where: { $0 == UInt8(ascii: ":") }) == 1, let colon = hostPort.firstIndex(of: UInt8(ascii: ":")) {
            host = hostPort[..<colon]
            port = hostPort[(colon + 1)...]
        }
        let schemeText = String(decoding: scheme, as: UTF8.self)
        if let value = port {
            if value.isEmpty || (value.elementsEqual("80".utf8) && schemeText == "http")
                || (value.elementsEqual("443".utf8) && schemeText == "https") {
                port = nil
            }
        }
        output.append(contentsOf: [0x2F, 0x2F])
        output.append(contentsOf: userinfo)
        output.append(contentsOf: lowercaseHost(host))
        if let port {
            output.append(UInt8(ascii: ":"))
            output.append(contentsOf: port)
        }
        output.append(contentsOf: after.prefix { $0 != UInt8(ascii: "#") })
        return String(decoding: output, as: UTF8.self)
    }

    /// True if the URL has an authority with userinfo: an `@` between `scheme://` and the end of the
    /// authority (the first `/`, `?` or `#`), as normalization reads it.
    public static func hasUserinfo(_ url: String) -> Bool {
        let bytes = Array(url.utf8)
        guard let colon = schemeEnd(bytes) else { return false }
        let rest = bytes[(colon + 1)...]
        guard rest.starts(with: [0x2F, 0x2F]) else { return false }
        let body = rest.dropFirst(2)
        let end = body.firstIndex { [UInt8(ascii: "/"), UInt8(ascii: "?"), UInt8(ascii: "#")].contains($0) } ?? body.endIndex
        return body[..<end].contains(UInt8(ascii: "@"))
    }

    /// Removes the userinfo of every URL in a text, whole or embedded (the reference's `strip_userinfo`):
    /// `scheme://user:pass@host` becomes `scheme://host`.
    ///
    /// - The text is read with numeric character references (`&#64;`, `&#x40;`, with or without `;`) and
    ///   `&commat;`, `&colon;` and `&sol;` decoded, so `&#64;` is an `@`. A numeric reference that is zero or
    ///   not a Unicode scalar value stays as written.
    /// - A URL starts at `scheme://`, or at a scheme-relative `//` at the start of the text or after
    ///   U+0000–U+0020 (so a GUID's trim cannot uncover a URL), a quotation mark, an apostrophe, `=`, `(`, `<`
    ///   or `>`.
    /// - Its authority runs to the first U+0000–U+0020, `/`, `?`, `#`, `<`, `>` or quotation mark, and to the
    ///   first apostrophe only when the URL starts right after an apostrophe.
    /// - Its userinfo, everything up to the last `@`, is removed with the character references it spans.
    ///
    /// One forward pass over the UTF-8 bytes, decoding references where it reads them; output is built only from the
    /// first cut on, so a text costs about its own size.
    public static func stripUserinfo(_ text: String) -> String {
        guard text.utf8.contains(where: { $0 == UInt8(ascii: "@") || $0 == UInt8(ascii: "&") }) else { return text }
        var text = text
        text.makeContiguousUTF8()
        let stripped = text.utf8.withContiguousStorageIfAvailable { UserinfoScanner(bytes: $0).strip() }
            ?? Array(text.utf8).withUnsafeBufferPointer { UserinfoScanner(bytes: $0).strip() }
        return stripped.map { String(decoding: $0, as: UTF8.self) } ?? text
    }

    // MARK: Helpers

    /// The index of the colon ending a leading `[A-Za-z][A-Za-z0-9+.-]*:`, if any.
    private static func schemeEnd(_ bytes: [UInt8]) -> Int? {
        guard let first = bytes.first, isASCIILetter(first) else { return nil }
        var index = 1
        while index < bytes.count, isSchemeCharacter(bytes[index]) { index += 1 }
        return index < bytes.count && bytes[index] == UInt8(ascii: ":") ? index : nil
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
    }

    private static func isSchemeCharacter(_ byte: UInt8) -> Bool {
        isASCIILetter(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || byte == UInt8(ascii: "+") || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "-")
    }

    private static func asciiLowercase(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 32 : byte
    }

    /// ASCII letters lowercased, except inside a percent triplet, which is copied verbatim.
    private static func lowercaseHost(_ host: ArraySlice<UInt8>) -> [UInt8] {
        var output: [UInt8] = []
        var index = host.startIndex
        while index < host.endIndex {
            if host[index] == UInt8(ascii: "%"), index + 2 < host.endIndex,
               ContractHex.digit(host[index + 1], uppercase: true) != nil, ContractHex.digit(host[index + 2], uppercase: true) != nil {
                output.append(contentsOf: host[index...(index + 2)])
                index += 3
            } else {
                output.append(asciiLowercase(host[index]))
                index += 1
            }
        }
        return output
    }
}

/// `stripUserinfo`'s single pass over a text's UTF-8 bytes. The decoded view (character references read as the
/// characters they stand for) is produced as it goes: a reference is read the same wherever a read starts, so a
/// character can be looked at again by its byte offset. Every byte of a non-ASCII character stands for itself: like
/// the character, it is no delimiter, no scheme character and above U+0020, and cuts fall on ASCII boundaries.
private struct UserinfoScanner {
    let bytes: UnsafeBufferPointer<UInt8>

    private static let quote = UInt32(UInt8(ascii: "\"")), apostrophe = UInt32(UInt8(ascii: "'"))
    private static let slash = UInt32(UInt8(ascii: "/")), colon = UInt32(UInt8(ascii: ":")), at = UInt32(UInt8(ascii: "@"))

    /// The text without its URLs' userinfo, or nil when nothing is cut.
    func strip() -> [UInt8]? {
        var output: [UInt8]?
        var copied = 0
        var offset = 0
        // The view character before `offset` (nil at the start of the text).
        var previous: UInt32?
        // In a run of scheme characters: nil before its first ASCII letter, else whether a URL starting at that
        // letter follows an apostrophe (only a letter that starts the run can).
        var inRun = false
        var letterQuoted: Bool?
        while offset < bytes.count {
            let (character, next) = self.character(at: offset)
            if Self.isLetter(character) {
                if !inRun { inRun = true; letterQuoted = previous == Self.apostrophe } else if letterQuoted == nil { letterQuoted = false }
                previous = character; offset = next
                continue
            }
            if Self.isSchemeCharacter(character) {
                if !inRun { inRun = true; letterQuoted = nil }
                previous = character; offset = next
                continue
            }
            // A URL starts at `scheme://` (from the run's first letter) or at a scheme-relative `//`.
            var url: (authority: Int, quoted: Bool)?
            if character == Self.colon, inRun, let quoted = letterQuoted, let authority = afterSlashes(next) {
                url = (authority, quoted)
            } else if character == Self.slash, previous.map(Self.opensRelativeURL) ?? true,
                      next < bytes.count, self.character(at: next).value == Self.slash {
                url = (self.character(at: next).end, previous == Self.apostrophe)
            }
            inRun = false
            letterQuoted = nil
            guard let url else {
                previous = character; offset = next
                continue
            }
            // The authority runs to its first terminator; its userinfo is everything up to the last `@`.
            var end = url.authority
            var userinfoEnd: Int?
            var last = Self.slash
            while end < bytes.count {
                let (value, after) = self.character(at: end)
                if Self.endsAuthority(value) || (url.quoted && value == Self.apostrophe) { break }
                if value == Self.at { userinfoEnd = after }
                last = value; end = after
            }
            if let userinfoEnd {
                if output == nil { output = []; output!.reserveCapacity(bytes.count) }
                output!.append(contentsOf: bytes[copied..<url.authority])
                copied = userinfoEnd
            }
            previous = last
            offset = end
        }
        guard var output else { return nil }
        output.append(contentsOf: bytes[copied...])
        return output
    }

    /// The offset after `//` read at `offset`, if two slashes are there.
    private func afterSlashes(_ offset: Int) -> Int? {
        guard offset < bytes.count else { return nil }
        let first = character(at: offset)
        guard first.value == Self.slash, first.end < bytes.count else { return nil }
        let second = character(at: first.end)
        return second.value == Self.slash ? second.end : nil
    }

    /// The view character at `offset` and the offset after it: a reference's character, or the byte itself.
    private func character(at offset: Int) -> (value: UInt32, end: Int) {
        if bytes[offset] == UInt8(ascii: "&"), let reference = reference(at: offset) { return reference }
        return (UInt32(bytes[offset]), offset + 1)
    }

    /// A reference `&#x<hex>;?`, `&#<decimal>;?`, `&commat;`, `&colon;` or `&sol;` at `start` standing for a
    /// character, and its end. One that is zero or not a Unicode scalar value is read as written.
    private func reference(at start: Int) -> (UInt32, Int)? {
        var index = start + 1
        guard index < bytes.count else { return nil }
        if bytes[index] == UInt8(ascii: "#") {
            index += 1
            var radix: UInt32 = 10
            if index < bytes.count, bytes[index] == UInt8(ascii: "x") || bytes[index] == UInt8(ascii: "X") {
                // `&#x` without hex digits is no reference; `&#` and decimal digits never follow it.
                guard index + 1 < bytes.count, ContractHex.digit(bytes[index + 1], uppercase: true) != nil else { return nil }
                radix = 16
                index += 1
            }
            let digitsStart = index
            var value: UInt32 = 0
            var overflow = false
            while index < bytes.count {
                let byte = bytes[index]
                let digit: UInt8?
                if radix == 16 { digit = ContractHex.digit(byte, uppercase: true) } else {
                    digit = (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) ? byte - UInt8(ascii: "0") : nil
                }
                guard let digit else { break }
                if !overflow {
                    let next = UInt64(value) * UInt64(radix) + UInt64(digit)
                    if next > 0x10FFFF { overflow = true } else { value = UInt32(next) }
                }
                index += 1
            }
            guard index > digitsStart else { return nil }
            if index < bytes.count, bytes[index] == UInt8(ascii: ";") { index += 1 }
            guard !overflow, value != 0, let scalar = Unicode.Scalar(value) else { return nil }
            return (scalar.value, index)
        }
        for (name, value) in Self.namedReferences {
            if start + 1 + name.count <= bytes.count, bytes[(start + 1)..<(start + 1 + name.count)].elementsEqual(name) {
                return (value, start + 1 + name.count)
            }
        }
        return nil
    }

    private static let namedReferences: [([UInt8], UInt32)] = [
        (Array("commat;".utf8), UInt32(UInt8(ascii: "@"))), (Array("colon;".utf8), UInt32(UInt8(ascii: ":"))),
        (Array("sol;".utf8), UInt32(UInt8(ascii: "/")))
    ]

    private static func isLetter(_ value: UInt32) -> Bool {
        switch value { case 0x41...0x5A, 0x61...0x7A: true; default: false }
    }

    private static func isSchemeCharacter(_ value: UInt32) -> Bool {
        switch value { case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2B, 0x2D, 0x2E: true; default: false }
    }

    /// A scheme-relative `//` starts a URL after U+0000–U+0020, a quotation mark, an apostrophe, `=`, `(`, `<` or `>`.
    private static func opensRelativeURL(_ value: UInt32) -> Bool {
        switch value { case 0...0x20, 0x22, 0x27, 0x28, 0x3C, 0x3D, 0x3E: true; default: false }
    }

    /// U+0000–U+0020, `/`, `?`, `#`, `<`, `>` and the quotation mark end an authority.
    private static func endsAuthority(_ value: UInt32) -> Bool {
        switch value { case 0...0x20, 0x22, 0x23, 0x2F, 0x3C, 0x3E, 0x3F: true; default: false }
    }
}
