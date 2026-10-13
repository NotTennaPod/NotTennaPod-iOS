import Foundation
import SwiftSoup

enum FeedMIME {
    static func isMedia(_ type: String?) -> Bool {
        guard let type else { return false }
        return type.hasPrefix("audio/") || type.hasPrefix("video/")
            || type == "application/ogg" || type == "application/octet-stream"
    }

    static func isImage(_ type: String?) -> Bool { type?.hasPrefix("image/") == true }

    static func resolve(_ type: String?, url: String?) -> String? {
        if isMedia(type), type != "application/octet-stream" { return type }
        guard let url, let dot = url.lastIndex(of: "."),
              !url[url.index(after: dot)...].contains("/"),
              !url[url.index(after: dot)...].contains("\\") else { return type }
        let ext = String(url[url.index(after: dot)...])
        let audio: Set<String> = ["3gp", "aac", "amr", "flac", "imy", "m4a", "m4b", "mid", "mkv", "mp3", "mp4", "mxmf", "oga", "ogg", "ogx", "opus", "ota", "rtttl", "rtx", "wav", "xmf"]
        let video: Set<String> = ["3gp", "mkv", "mp4", "ogg", "ogv", "ogx", "webm"]
        // Android's MIME map lowercases extensions; its explicit fallback sets do not.
        let mapped = AndroidMIMEMap.extensions[ext.lowercased()]
            ?? (audio.contains(ext) ? "audio/*" : video.contains(ext) ? "video/*" : nil)
        return isMedia(mapped) ? mapped : type
    }
}
