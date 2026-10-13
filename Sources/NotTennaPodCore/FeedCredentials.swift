import Foundation

public struct FeedCredentials: Codable, Sendable, Equatable {
    public var username: String?
    public var password: String?

    public init(username: String?, password: String?) {
        self.username = username
        self.password = password
    }

    func authorization(utf8: Bool) -> String {
        let value = (username ?? "null") + ":" + (password ?? "null")
        let bytes = utf8 ? Data(value.utf8) : Data(value.unicodeScalars.map { $0.value <= 255 ? UInt8($0.value) : 63 })
        return "Basic " + bytes.base64EncodedString()
    }
}
