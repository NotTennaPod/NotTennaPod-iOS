/// Every User-Agent the app sends. Source `ClientConfig.USER_AGENT` is `AntennaPod/<version>`; NotTennaPod sends its
/// own name. Online search and the proxy test send their own fixed strings.
public enum HTTPUserAgent {
    /// The app's own User-Agent for its version.
    public static func application(version: String) -> String { "NotTennaPod/\(version)" }
    /// Default for components built without the app's version (tests).
    public static let unversioned = "NotTennaPod/0.0.0"
    /// Online podcast search, its lookup and the iTunes top list.
    public static let search = "NotTennaPod (iOS)"
    /// The proxy settings connection test.
    public static let proxyTest = "NotTennaPod (iOS)"
}
