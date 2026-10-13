import Foundation

/// Draft text is separate from committed configuration; disabled DIRECT fields
/// retain their text. Source: ProxyDialog and the captured API36 DOMAIN_NAME.
public struct ProxySettingsDraft: Equatable, Sendable {
    public var kind: PodcastProxy.Kind
    public var host: String
    public var port: String
    public var username: String
    public var password: String

    public init(_ value: PodcastProxy = .init()) {
        kind = value.kind; host = value.host ?? ""
        port = value.port > 0 ? String(value.port) : ""
        username = value.username ?? ""; password = value.password ?? ""
    }
    public enum Field: String, Sendable { case host, port }
    public var errors: [Field: String] {
        var result: [Field: String] = [:]
        if kind != .direct {
            if host.isEmpty { result[.host] = "proxy_host_empty_error" }
            else if !Self.validHost(host) { result[.host] = "proxy_host_invalid_error" }
        }
        if !port.isEmpty, parsedPort == nil { result[.port] = "proxy_port_invalid_error" }
        return result
    }
    private var parsedPort: Int? {
        if port.isEmpty { return 0 }
        guard let value = Int32(port), (0...65535).contains(value) else { return nil }
        return Int(value)
    }
    public var configuration: PodcastProxy {
        .init(kind: kind, host: host.isEmpty ? nil : host, port: parsedPort ?? 0,
              username: username.isEmpty ? nil : username, password: password.isEmpty ? nil : password)
    }
    public mutating func clearFields() { host = ""; port = ""; username = ""; password = "" }
    public static func validHost(_ value: String) -> Bool {
        value == "localhost" || domain.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
    // Android Patterns.DOMAIN_NAME, captured from the running original API36.
    // Unicode scalars use ICU escapes for readable, stable source text.
    private static let domain = try! NSRegularExpression(pattern: #"\A(?:(([a-zA-Z0-9[\x{a0}-\x{d7ff}\x{f900}-\x{fdcf}\x{fdf0}-\x{ffef}\x{10000}-\x{1fffd}\x{20000}-\x{2fffd}\x{30000}-\x{3fffd}\x{40000}-\x{4fffd}\x{50000}-\x{5fffd}\x{60000}-\x{6fffd}\x{70000}-\x{7fffd}\x{80000}-\x{8fffd}\x{90000}-\x{9fffd}\x{a0000}-\x{afffd}\x{b0000}-\x{bfffd}\x{c0000}-\x{cfffd}\x{d0000}-\x{dfffd}\x{e1000}-\x{efffd}&&[^\x{a0}[\x{2000}-\x{200a}]\x{2028}\x{2029}\x{202f}\x{3000}]]](?:[a-zA-Z0-9[\x{a0}-\x{d7ff}\x{f900}-\x{fdcf}\x{fdf0}-\x{ffef}\x{10000}-\x{1fffd}\x{20000}-\x{2fffd}\x{30000}-\x{3fffd}\x{40000}-\x{4fffd}\x{50000}-\x{5fffd}\x{60000}-\x{6fffd}\x{70000}-\x{7fffd}\x{80000}-\x{8fffd}\x{90000}-\x{9fffd}\x{a0000}-\x{afffd}\x{b0000}-\x{bfffd}\x{c0000}-\x{cfffd}\x{d0000}-\x{dfffd}\x{e1000}-\x{efffd}&&[^\x{a0}[\x{2000}-\x{200a}]\x{2028}\x{2029}\x{202f}\x{3000}]]_\-]{0,61}[a-zA-Z0-9[\x{a0}-\x{d7ff}\x{f900}-\x{fdcf}\x{fdf0}-\x{ffef}\x{10000}-\x{1fffd}\x{20000}-\x{2fffd}\x{30000}-\x{3fffd}\x{40000}-\x{4fffd}\x{50000}-\x{5fffd}\x{60000}-\x{6fffd}\x{70000}-\x{7fffd}\x{80000}-\x{8fffd}\x{90000}-\x{9fffd}\x{a0000}-\x{afffd}\x{b0000}-\x{bfffd}\x{c0000}-\x{cfffd}\x{d0000}-\x{dfffd}\x{e1000}-\x{efffd}&&[^\x{a0}[\x{2000}-\x{200a}]\x{2028}\x{2029}\x{202f}\x{3000}]]]){0,1}\.)+(xn\-\-[\w\-]{0,58}\w|[a-zA-Z[\x{a0}-\x{d7ff}\x{f900}-\x{fdcf}\x{fdf0}-\x{ffef}\x{10000}-\x{1fffd}\x{20000}-\x{2fffd}\x{30000}-\x{3fffd}\x{40000}-\x{4fffd}\x{50000}-\x{5fffd}\x{60000}-\x{6fffd}\x{70000}-\x{7fffd}\x{80000}-\x{8fffd}\x{90000}-\x{9fffd}\x{a0000}-\x{afffd}\x{b0000}-\x{bfffd}\x{c0000}-\x{cfffd}\x{d0000}-\x{dfffd}\x{e1000}-\x{efffd}&&[^\x{a0}[\x{2000}-\x{200a}]\x{2028}\x{2029}\x{202f}\x{3000}]]]{2,63})|((25[0-5]|2[0-4][0-9]|[0-1][0-9]{2}|[1-9][0-9]|[1-9])\.(25[0-5]|2[0-4][0-9]|[0-1][0-9]{2}|[1-9][0-9]|[1-9]|0)\.(25[0-5]|2[0-4][0-9]|[0-1][0-9]{2}|[1-9][0-9]|[1-9]|0)\.(25[0-5]|2[0-4][0-9]|[0-1][0-9]{2}|[1-9][0-9]|[0-9]))))\z"#)
}
