import UIKit
import WebKit
import Testing
import Synchronization
@testable import NotTennaPod
@testable import NotTennaPodCore

/// Show notes load pictures, styles and fonts by "Cover images" (as Android) and media and embedded frames by
/// "Streaming" (an intentional difference), before the first load and after every change of the options or the
/// network; loads already allowed end when their class becomes denied, also in hidden notes. Real requests reach a
/// loopback HTTPS fixture; the network is the app's monitor driven by the test.
@MainActor @Suite(.serialized)
struct ShownotesSubresourceTests {
    enum Network {
        case wifi, cellular, lowDataWiFi, unknown
        var state: DownloadNetworkState? {
            switch self {
            case .wifi: return .init(connected: true, metered: false, cellular: false, transport: .wifi)
            case .cellular: return .init(connected: true, metered: true, cellular: true)
            case .lowDataWiFi: return .init(connected: true, metered: false, cellular: false, transport: .wifi, constrained: true)
            case .unknown: return nil
            }
        }
    }

    /// The app's policy over its own monitor and Mobile updates options.
    @MainActor final class Environment {
        let monitor = DownloadNetworkMonitor(startMonitoring: false)
        let preferences: MobileNetworkPreferenceStore
        let policy: ShownotesNetworkPolicy
        private let folder: URL

        init(_ network: Network, images: Bool = true, streaming: Bool = false, rules: ShownotesContentRules = .shared) throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShownotesSubresource-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            preferences = try MobileNetworkPreferenceStore(file: folder.appendingPathComponent("mobile.json"))
            try preferences.updateAllowed(Set((images ? ["images"] : []) + (streaming ? ["streaming"] : [])))
            if let state = network.state { monitor.update(state) }
            policy = ShownotesNetworkPolicy(network: monitor, preferences: preferences, rules: rules)
            preferences.onChange = { [weak policy] in policy?.preferencesChanged() }
        }
        isolated deinit { try? FileManager.default.removeItem(at: folder) }

        func options(images: Bool, streaming: Bool) throws {
            try preferences.updateAllowed(Set((images ? ["images"] : []) + (streaming ? ["streaming"] : [])))
        }
        /// Moves to `network` and waits until the policy has applied it (one main-queue hop, as in the app).
        func move(to network: Network, expecting allowed: ShownotesNetworkPolicy.Classes) async throws {
            monitor.update(network.state!)
            try await ShownotesSubresourceTests.wait("policy applies the network") { self.policy.allowed == allowed }
        }
    }

    // MARK: Fixture

    nonisolated static func png(side: Int, noise: Bool) -> Data {
        var bytes = [UInt8](repeating: 200, count: side * side * 4)
        if noise {
            var generator = SystemRandomNumberGenerator()
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255, using: &generator) }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return UIImage(cgImage: image).pngData()!
    }
    nonisolated static let smallPNG = png(side: 4, noise: false)
    /// A valid picture far larger than the held prefix: noise does not compress.
    nonisolated static let largePNG = png(side: 900, noise: true)
    nonisolated static func wav(seconds: Int) -> Data {
        let rate = 8_000, samples = rate * seconds
        var data = Data("RIFF".utf8)
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append(UInt32(36 + samples)); data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate)); append(UInt16(1)); append(UInt16(8))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(samples))
        data.append(Data(repeating: 128, count: samples))
        return data
    }
    nonisolated static let smallWAV = wav(seconds: 1)
    nonisolated static let largeWAV = wav(seconds: 4_000)
    nonisolated static let largeCSS = Data(("p { margin: 0 }\n" + String(repeating: "/* padding */\n", count: 300_000)).utf8)
    nonisolated static let prefix = 256 * 1024

    /// Replies by file name: the documents below name what they need.
    nonisolated static func reply(_ path: String) -> ShownotesFixtureServer.Reply {
        let name = path.split(separator: "/").last.map(String.init) ?? ""
        switch name {
        case "held.png": return .held(largePNG, type: "image/png", prefix: prefix)
        case "held.css": return .held(largeCSS, type: "text/css", prefix: prefix)
        case "held.wav": return .held(largeWAV, type: "audio/wav", prefix: prefix)
        case "cached.png": return .body(smallPNG, type: "image/png", headers: ["Cache-Control": "max-age=3600"])
        case "frame.html": return .body(Data("<p>frame</p><img src='frameimage.png'>".utf8), type: "text/html")
        case "heldframe.html": return .body(Data("<p>frame</p><img src='held.png'>".utf8), type: "text/html")
        case "slowframe.html": return .held(Data(("<p>frame</p>" + String(repeating: "<!-- padding -->", count: 4_096)).utf8), type: "text/html", prefix: 64)
        default: break
        }
        switch (name as NSString).pathExtension {
        case "png": return .body(smallPNG, type: "image/png")
        case "css": return .body(Data("p { margin: 1px }".utf8), type: "text/css")
        case "svg": return .body(Data("<svg xmlns='http://www.w3.org/2000/svg'><rect id='shape' width='10' height='10'/></svg>".utf8), type: "image/svg+xml")
        case "woff": return .body(Data(repeating: 7, count: 512), type: "font/woff")
        case "wav": return .body(smallWAV, type: "audio/wav")
        case "vtt": return .body(Data("WEBVTT\n\n00:00.000 --> 00:01.000\nText\n".utf8), type: "text/vtt")
        case "html": return .body(Data("<p>embedded</p>".utf8), type: "text/html")
        case "js": return .body(Data("document.title = 'x';".utf8), type: "text/javascript")
        default: return .body(Data("x".utf8), type: "text/plain")
        }
    }

    static func wait(_ message: @autoclosure () -> String = "", timeout: Duration = .seconds(15),
                     sourceLocation: SourceLocation = #_sourceLocation, _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while try await !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(try await condition(), "\(message())", sourceLocation: sourceLocation)
    }

    private static var episodeID: Int64 = 1_000
    nonisolated private static let paragraphs = (0..<100).map { "<p>Paragraph \($0) of the notes, long enough to scroll.</p>" }.joined()

    /// Notes in `host`, trusting only the fixture's certificate.
    private func notes(_ environment: Environment, _ html: String, in host: UIView, trusting identity: ShownotesFixtureServer.Identity,
                       frame: CGRect? = nil) -> ShownotesWebView {
        let web = ShownotesWebView(network: environment.policy)
        web.trustedCertificateSHA256ForTesting = identity.fingerprint
        host.addSubview(web); web.frame = frame ?? host.bounds
        Self.episodeID += 1
        web.show(LibraryEpisode(id: Self.episodeID, details: .init(title: "Notes", description: html,
            media: .init(url: "https://example.invalid/media", size: 0, durationMilliseconds: 60_000))))
        return web
    }
    private func ready(_ web: ShownotesWebView, _ message: String = "notes ready", sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await Self.wait(message, sourceLocation: sourceLocation) { web.isDocumentReady && !web.isLoading }
    }
    struct ScriptTimedOut: Error {}
    /// Runs `body` in the notes' client world. WebKit never answers a script waiting for a frame that a pending
    /// stylesheet keeps from rendering, so each call has a bound and the test goes on (the script is left behind).
    private func script(_ web: ShownotesWebView, _ body: String, within limit: Duration = .seconds(15)) async throws -> Any? {
        struct Value: @unchecked Sendable { let value: Any? }
        @MainActor final class Outcome {
            var continuation: CheckedContinuation<Value, Error>?
            func finish(_ result: Result<Value, Error>) { continuation?.resume(with: result); continuation = nil }
        }
        let outcome = Outcome()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
            outcome.continuation = continuation
            Task { @MainActor in
                do { outcome.finish(.success(Value(value: try await web.callAsyncJavaScript(body, in: nil, contentWorld: .defaultClient)))) }
                catch { outcome.finish(.failure(error)) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                outcome.finish(.failure(ScriptTimedOut()))
            }
        }.value
    }

    private func documentID(_ web: ShownotesWebView) async throws -> String {
        try await script(web, "return globalThis.apShownotesDocument || '';") as? String ?? ""
    }
    private func withFixture(identity name: String = "trusted",
                             _ body: (ShownotesFixtureServer, ShownotesFixtureServer.Identity, UIView) async throws -> Void) async throws {
        let trusted = try ShownotesFixtureServer.Identity.load("trusted")
        let server = try await ShownotesFixtureServer.start(identity: name == "trusted" ? trusted : .load(name), handler: Self.reply)
        defer { server.stop() }
        try await withViewTestWindow { host, _ in try await body(server, trusted, host.view) }
    }

    // MARK: Each class, each network

    /// `embedded`: an `object`/`embed` document, which this WebKit loads only when both lists allow it (the
    /// classification probe); `embeddedPicture`: an `object`/`embed` picture, which follows Cover images.
    /// `slowEmbedded`: a visible `embed` HTML document. Its request is the completion: WebKit's rendered completion of
    /// it is unreliable (the page may never finish loading), so the row waits a bounded time for its request; it must
    /// be requested when both lists allow it (the positive control) and never otherwise.
    /// A tapped link's `ping` is sent by WebKit before the app
    /// cancels the navigation, so it is a Small load (`ping` resource type), governed by Cover images.
    enum Kind { case small, heavy, frame, embedded, embeddedPicture, slowEmbedded, never, ping }
    struct Form: Sendable, CustomTestStringConvertible {
        let name: String
        let kind: Kind
        /// The notes, given the form's base URL.
        let html: @Sendable (String) -> String
        /// Run after rendered readiness: starts what loads only on demand (it never waits inside the page).
        let trigger: String?
        /// The file whose requests count.
        let file: String
        /// Polled after the trigger: true once the load finished or failed. A denied load may never report either; the
        /// poll then ends at its bound, while an allowed one ends at its first request.
        var done: String? = nil
        var testDescription: String { name }
    }
    nonisolated static let mediaTrigger = "document.querySelector('video, audio').load(); return true;"
    nonisolated static let mediaDone = "const media = document.querySelector('video, audio'); return !!media.error || media.readyState >= 1;"
    nonisolated static let forms: [Form] = [
        Form(name: "img", kind: .small, html: { "<img src='\($0)/a.png'>" }, trigger: nil, file: "a.png"),
        Form(name: "srcset", kind: .small, html: { "<img srcset='\($0)/a.png 1x'>" }, trigger: nil, file: "a.png"),
        Form(name: "picture", kind: .small, html: { "<picture><source media='(min-width: 0px)' srcset='\($0)/a.png'><img alt='p'></picture>" },
             trigger: nil, file: "a.png"),
        Form(name: "inline-style", kind: .small, html: { "<div style=\"width:100px;height:100px;background-image:url('\($0)/a.png')\">x</div>" },
             trigger: nil, file: "a.png"),
        Form(name: "import", kind: .small, html: { "<style>@import url('\($0)/a.css');</style><p>x</p>" }, trigger: nil, file: "a.css"),
        Form(name: "font", kind: .small, html: { "<style>@font-face { font-family: ApFixture; src: url('\($0)/a.woff'); } .f { font-family: ApFixture; }</style><p class='f'>Font</p>" },
             trigger: "document.fonts.load('16px ApFixture'); return true;", file: "a.woff",
             done: "return document.fonts.status === 'loaded';"),
        Form(name: "link-stylesheet", kind: .small, html: { "<head><link rel='stylesheet' href='\($0)/a.css'></head><p>x</p>" }, trigger: nil, file: "a.css"),
        Form(name: "svg-image", kind: .small, html: { "<svg width='100' height='100'><image href='\($0)/a.png' width='100' height='100'/></svg>" },
             trigger: nil, file: "a.png"),
        Form(name: "video", kind: .heavy, html: { "<video src='\($0)/a.wav' preload='metadata'></video>" }, trigger: mediaTrigger, file: "a.wav", done: mediaDone),
        Form(name: "audio", kind: .heavy, html: { "<audio src='\($0)/a.wav' preload='metadata'></audio>" }, trigger: mediaTrigger, file: "a.wav", done: mediaDone),
        Form(name: "track", kind: .heavy, html: { "<video src='\($0)/a.wav' preload='metadata'><track default kind='subtitles' src='\($0)/a.vtt'></video>" },
             trigger: "const track = document.querySelector('track'); track.track.mode = 'hidden'; document.querySelector('video').load(); return true;",
             file: "a.vtt", done: "return document.querySelector('track').readyState >= 2;"),
        Form(name: "iframe", kind: .heavy, html: { "<iframe src='\($0)/frame.html'></iframe>" }, trigger: nil, file: "frame.html"),
        Form(name: "iframe-picture", kind: .frame, html: { "<iframe src='\($0)/frame.html'></iframe>" }, trigger: nil, file: "frameimage.png"),
        Form(name: "object-html", kind: .embedded, html: { "<object data='\($0)/a.html' type='text/html'></object>" }, trigger: nil, file: "a.html"),
        Form(name: "object-image", kind: .embeddedPicture, html: { "<object data='\($0)/a.png' type='image/png'></object>" }, trigger: nil, file: "a.png"),
        Form(name: "embed-html", kind: .slowEmbedded, html: { "<embed src='\($0)/a.html' type='text/html' width='300' height='150'>" }, trigger: nil, file: "a.html"),
        Form(name: "embed-image", kind: .embeddedPicture, html: { "<embed src='\($0)/a.png' type='image/png'>" }, trigger: nil, file: "a.png"),
        // Unreachable: WebKit loads an SVG `use` reference only from the document's own origin, and the notes' origin
        // (https://127.0.0.1) serves nothing, so a publisher's external `use` never loads, even on Wi-Fi.
        Form(name: "svg-use", kind: .never, html: { "<svg width='100' height='100'><use href='\($0)/a.svg#shape'/></svg>" }, trigger: nil, file: "a.svg"),
        Form(name: "script", kind: .never, html: { "<script src='\($0)/a.js'></script><p>x</p>" }, trigger: nil, file: "a.js"),
        Form(name: "hints", kind: .never, html: { "<head><link rel='prefetch' href='\($0)/a.html'><link rel='Preload' as='image' href='\($0)/b.png'><link rel='preconnect dns-prefetch' href='\($0)/c'><link rel='prerender' href='\($0)/d.html'><link rel='modulepreload' href='\($0)/e.js'></head><p>x</p>" },
             trigger: nil, file: ""),
        Form(name: "meta-refresh", kind: .never, html: { "<head><meta http-equiv='Refresh' content='0; url=\($0)/refresh.html'></head><p>x</p>" },
             trigger: nil, file: "refresh.html"),
        Form(name: "ping", kind: .ping, html: { "<p><a href='https://example.invalid/target' ping='\($0)/ping'>Link</a></p>" },
             trigger: "document.querySelector('a').click(); return true;", file: "ping", done: "return false;")
    ]

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let network: Network
        let images, streaming: Bool
        let small, heavy: Bool
        var testDescription: String { name }
    }
    nonisolated static let cases: [Case] = [
        Case(name: "a Wi-Fi", network: .wifi, images: false, streaming: false, small: true, heavy: true),
        Case(name: "b cellular, default options", network: .cellular, images: true, streaming: false, small: true, heavy: false),
        Case(name: "c cellular, both off", network: .cellular, images: false, streaming: false, small: false, heavy: false),
        Case(name: "d cellular, Cover images off, Streaming on", network: .cellular, images: false, streaming: true, small: false, heavy: true),
        Case(name: "e Low Data Wi-Fi, default options", network: .lowDataWiFi, images: true, streaming: false, small: true, heavy: false),
        Case(name: "e Low Data Wi-Fi, both off", network: .lowDataWiFi, images: false, streaming: false, small: false, heavy: false),
        Case(name: "f unknown network at first render", network: .unknown, images: true, streaming: false, small: false, heavy: false)
    ]

    /// One minimal document per class form, each with its own counter, under every network case. Wi-Fi proves each
    /// reachable form loads with its trigger, so the zero rows are not vacuous. `object`/`embed` were a classification
    /// probe; their rows record what this WebKit does, and none may load when both options deny.
    @Test(arguments: ShownotesSubresourceTests.cases)
    func everyClassFollowsItsOptionOnEveryNetwork(_ testCase: Case) async throws {
        try await withFixture { server, identity, host in
            let environment = try Environment(testCase.network, images: testCase.images, streaming: testCase.streaming)
            var opened: [String] = []
            var probes: [String] = []
            for form in Self.forms {
                let base = server.url("/\(UUID().uuidString)/\(form.name)")
                let web = notes(environment, form.html(base), in: host, trusting: identity)
                web.openLink = { opened.append($0) }
                defer { web.removeFromSuperview() }
                let path = String(base.dropFirst("https://127.0.0.1:\(server.port)".count))
                let counter = form.file.isEmpty ? path : "\(path)/\(form.file)"
                if form.kind == .slowEmbedded || form.kind == .embedded {
                    // Readiness follows the notes' own layout, so an embedded document's request is its completion.
                    // WebKit can start it late under load: the allowed (positive) row waits longer than the denied ones.
                    let deadline = ContinuousClock.now + .seconds(testCase.small && testCase.heavy ? 30 : 10)
                    while server.count(counter) == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
                } else {
                    try await ready(web, "\(form.name) ready")
                }
                if let trigger = form.trigger { _ = try await script(web, trigger) }
                if let done = form.done {
                    let deadline = ContinuousClock.now + .seconds(5)
                    while server.count(counter) == 0, ContinuousClock.now < deadline,
                          try await script(web, done) as? Bool != true { try await Task.sleep(for: .milliseconds(50)) }
                }
                if web.isDocumentReady {
                    _ = try await script(web, "await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))); return true;")
                }
                let count = server.count(counter)
                let label = "\(testCase.name): \(form.name) requests \(count)"
                switch form.kind {
                case .small: #expect(testCase.small ? count >= 1 : count == 0, "\(label)")
                case .heavy: #expect(testCase.heavy ? count >= 1 : count == 0, "\(label)")
                case .frame: #expect(testCase.small && testCase.heavy ? count >= 1 : count == 0, "\(label)")
                case .never: #expect(count == 0, "\(label)")
                case .slowEmbedded:
                    #expect(testCase.small && testCase.heavy ? count >= 1 : count == 0, "\(label)")
                    probes.append("\(form.name)=\(count)")
                case .ping:
                    #expect(testCase.small ? count >= 1 : count == 0, "\(label)")
                    try await Self.wait("the tapped link opens outside the notes") { opened.contains("https://example.invalid/target") }
                case .embedded:
                    #expect(testCase.small && testCase.heavy ? count >= 1 : count == 0, "\(label)")
                    probes.append("\(form.name)=\(count)")
                case .embeddedPicture:
                    #expect(testCase.small ? count >= 1 : count == 0, "\(label)")
                    probes.append("\(form.name)=\(count)")
                }
                if form.name == "meta-refresh" { #expect(try await documentID(web) != "", "the notes stay in place") }
                print("SHOWNOTES_FORM_DONE case=\(testCase.name) form=\(form.name) count=\(count)")
            }
            print("SHOWNOTES_CLASSIFICATION_PROBE case=\(testCase.name) \(probes.joined(separator: " "))")
        }
    }

    // MARK: Retiring loads already allowed

    enum Held: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case picture, linkedSheet, svgImage, media, framePictureSmall, framePictureHeavy
        var testDescription: String { rawValue }
        func html(_ base: String) -> String {
            switch self {
            case .picture: return "<img src='\(base)/held.png'>" + ShownotesSubresourceTests.paragraphs
            case .linkedSheet: return "<head><link rel='stylesheet' href='\(base)/held.css'></head>" + ShownotesSubresourceTests.paragraphs
            case .svgImage: return "<svg width='100' height='100'><image href='\(base)/held.png' width='100' height='100'/></svg>" + ShownotesSubresourceTests.paragraphs
            case .media: return "<video src='\(base)/held.wav' preload='auto'></video>" + ShownotesSubresourceTests.paragraphs
            case .framePictureSmall, .framePictureHeavy: return "<iframe src='\(base)/heldframe.html'></iframe>" + ShownotesSubresourceTests.paragraphs
            }
        }
        /// Heavy loads end with the document; Small loads by `stopLoading()`.
        var heavy: Bool { self == .media || self == .framePictureHeavy }
    }

    /// Starts the held load and returns its open exchanges.
    private func startHeld(_ held: Held, _ web: ShownotesWebView, server: ShownotesFixtureServer, path: String) async throws -> [ShownotesFixtureServer.Exchange] {
        if held == .media {
            try await Self.wait("media document") { (try? await documentID(web))?.isEmpty == false }
            _ = try await script(web, "document.querySelector('video').load(); return true;")
        }
        try await Self.wait("the held response is open") {
            server.exchanges(path).contains { !$0.disconnected && $0.accepted >= Self.prefix }
        }
        return server.exchanges(path).filter { !$0.disconnected }
    }

    /// Scrolls to `offset` where the notes allow it (a pending stylesheet can keep them from being laid out).
    private func scroll(_ web: ShownotesWebView, to offset: CGFloat) async throws -> CGFloat? {
        let deadline = ContinuousClock.now + .seconds(5)
        while web.scrollView.contentSize.height <= web.scrollView.bounds.height + offset, !web.isDocumentReady,
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard web.scrollView.contentSize.height > web.scrollView.bounds.height + offset else { return nil }
        web.scrollView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        try await Self.wait("scrolled") { web.scrollView.contentOffset.y == offset }
        return offset
    }

    /// A response the notes already receive ends when its class becomes denied, by rebuilding the notes: a new document,
    /// ready, at the same position. The class becomes denied through the network (Heavy: Wi-Fi to cellular with
    /// Streaming off) and through an option (Small: Cover images off).
    @Test(arguments: ShownotesSubresourceTests.Held.allCases)
    func tighteningEndsLoadsAlreadyAllowed(_ held: Held) async throws {
        try await withFixture { server, identity, host in
            let environment = try Environment(.wifi, images: true, streaming: !held.heavy)
            let path = "/\(UUID().uuidString)/\(held.rawValue)"
            let web = notes(environment, held.html(server.url(path)), in: host, trusting: identity)
            defer { web.removeFromSuperview() }
            let exchanges = try await startHeld(held, web, server: server, path: path)
            let target = try await scroll(web, to: 300)
            let document = try await documentID(web)
            #expect(!document.isEmpty)
            if held.heavy {
                try await environment.move(to: .cellular, expecting: .small)
            } else {
                try await environment.move(to: .cellular, expecting: .all)
                #expect(exchanges.allSatisfy { !$0.disconnected }, "nothing was denied yet")
                try environment.options(images: false, streaming: true)
                #expect(environment.policy.allowed == .heavy)
            }
            try await Self.wait("the client ends the held response") { server.exchanges(path).allSatisfy(\.disconnected) }
            for exchange in exchanges { #expect(await exchange.writeFails(), "later writes fail") }
            #expect(web.policyRetirements == 1)
            try await ready(web, "rebuilt notes")
            #expect(try await documentID(web) != document, "a new document")
            if let target { #expect(abs(web.scrollView.contentOffset.y - target) <= web.defaultLineHeight, "position kept") }
            #expect(server.exchanges(path).allSatisfy { $0.disconnected }, "no newly allowed retry")
        }
    }

    /// The allowed control: a change that keeps the class allowed leaves the held picture loading, and it completes.
    @Test func aChangeThatKeepsTheClassAllowedLeavesTheLoad() async throws {
        try await withFixture { server, identity, host in
            let environment = try Environment(.wifi, images: true, streaming: false)
            let path = "/\(UUID().uuidString)/control"
            let web = notes(environment, Held.picture.html(server.url(path)), in: host, trusting: identity)
            defer { web.removeFromSuperview() }
            let exchanges = try await startHeld(.picture, web, server: server, path: path)
            let document = try await documentID(web)
            try await environment.move(to: .cellular, expecting: .small)
            #expect(web.policyRetirements == 0)
            #expect(exchanges.count == 1 && exchanges.allSatisfy { !$0.disconnected })
            #expect(await exchanges[0].release())
            try await ready(web, "the picture completes")
            #expect(try await script(web, "return document.querySelector('img').naturalWidth;") as? Int == 900)
            #expect(try await documentID(web) == document)
        }
    }

    /// Hidden notes (covered by the player, or a pager neighbour) are not shown, but their loads still end at once
    /// when denied, before the notes are shown again. They are rebuilt when next shown, at their position.
    @Test func hiddenNotesEndTheirLoadsBeforeTheyAreShownAgain() async throws {
        try await withFixture { server, identity, host in
            // Covered notes with a held media file.
            let environment = try Environment(.wifi, images: true, streaming: false)
            let mediaPath = "/\(UUID().uuidString)/covered"
            let covered = notes(environment, Held.media.html(server.url(mediaPath)), in: host, trusting: identity)
            defer { covered.removeFromSuperview() }
            let media = try await startHeld(.media, covered, server: server, path: mediaPath)
            let mediaRequests = server.exchanges(mediaPath).count
            let target = try await scroll(covered, to: 300)
            let coveredDocument = try await documentID(covered)
            covered.isCovered = true
            #expect(!covered.isShownInActiveScene)

            // A pager neighbour (clipped away) with a held picture.
            let pager = UIView(frame: host.bounds); pager.clipsToBounds = true; host.addSubview(pager)
            defer { pager.removeFromSuperview() }
            let picturePath = "/\(UUID().uuidString)/neighbour"
            let neighbour = notes(environment, Held.picture.html(server.url(picturePath)), in: pager, trusting: identity,
                                  frame: host.bounds.offsetBy(dx: host.bounds.width, dy: 0))
            let pictures = try await startHeld(.picture, neighbour, server: server, path: picturePath)
            let neighbourDocument = try await documentID(neighbour)
            #expect(!neighbour.isShownInActiveScene)

            try environment.options(images: false, streaming: false)
            try await environment.move(to: .cellular, expecting: [])
            try await Self.wait("hidden notes end their loads") {
                (media + pictures).allSatisfy(\.disconnected) && !covered.isShownInActiveScene && !neighbour.isShownInActiveScene
            }
            for exchange in media + pictures { #expect(await exchange.writeFails()) }
            #expect(covered.isAwaitingLoad, "covered Heavy notes wait to be rebuilt until shown")
            #expect(try await documentID(covered) != coveredDocument, "the covered document is gone")
            let neighbourNow = try await documentID(neighbour)
            #expect(neighbour.isAwaitingLoad && neighbourNow != neighbourDocument, "the neighbour's document is gone")
            let pictureRequests = server.exchanges(picturePath).count

            covered.isCovered = false
            try await ready(covered, "rebuilt when shown")
            #expect(!covered.isAwaitingLoad)
            if let target { #expect(abs(covered.scrollView.contentOffset.y - target) <= covered.defaultLineHeight) }
            #expect(server.exchanges(mediaPath).count == mediaRequests, "the rebuilt notes do not load the denied media")

            neighbour.frame = host.bounds; neighbour.visibilityMayHaveChanged()
            try await ready(neighbour, "the neighbour is rebuilt when shown")
            #expect(server.exchanges(picturePath).count == pictureRequests, "nor the denied picture")
        }
    }

    /// Notes whose picture is still loading when Cover images stop applying (here: Wi-Fi to cellular with Cover images
    /// off) end that load and still become ready at the saved reading position, and record where they are read after.
    @Test func notesRetiredBeforeTheirLoadEventBecomeReadyAtTheSavedPosition() async throws {
        try await withFixture { server, identity, host in
            let environment = try Environment(.wifi, images: false, streaming: false)
            let path = "/\(UUID().uuidString)/saved"
            let web = notes(environment, Held.picture.html(server.url(path)), in: host, trusting: identity)
            web.restoreScrollOffset = { 300 }
            defer { web.removeFromSuperview() }
            let exchanges = try await startHeld(.picture, web, server: server, path: path)
            #expect(!web.isDocumentReady, "the held picture keeps the load event back")
            try await environment.move(to: .cellular, expecting: [])
            try await Self.wait("the client ends the held response") { exchanges.allSatisfy(\.disconnected) }
            try await ready(web, "the notes become ready")
            #expect(abs(web.scrollView.contentOffset.y - 300) <= web.defaultLineHeight, "at the saved position")
            web.scrollView.setContentOffset(CGPoint(x: 0, y: 450), animated: false)
            try await Self.wait("the reading position follows") { web.readingOffset == 450 }
            #expect(server.exchanges(path).count == exchanges.count, "the denied picture is not requested again")
        }
    }

    /// A policy rebuild restores the reading point once the notes themselves are laid out, without waiting for an allowed
    /// embedded frame that is still loading, and records reading from then on; the frame finishing later moves nothing.
    @Test func aRebuildRestoresThePositionWithoutWaitingForASlowFrame() async throws {
        try await withFixture { server, identity, host in
            let environment = try Environment(.wifi, images: false, streaming: true)
            let path = "/\(UUID().uuidString)/slow"
            let base = server.url(path)
            let web = notes(environment, "<img src='\(base)/a.png'>" + Self.paragraphs + "<iframe src='\(base)/slowframe.html'></iframe>",
                            in: host, trusting: identity)
            defer { web.removeFromSuperview() }
            try await Self.wait("the frame is loading") { server.exchanges("\(path)/slowframe.html").contains { !$0.disconnected } }
            let target = try #require(try await scroll(web, to: 450))
            try await environment.move(to: .cellular, expecting: .heavy)
            try await Self.wait("the rebuilt frame is loading again") {
                server.exchanges("\(path)/slowframe.html").filter { !$0.disconnected }.count == 1 && server.exchanges("\(path)/slowframe.html").count == 2
            }
            try await Self.wait("the rebuilt notes are ready", timeout: .seconds(5)) { web.isDocumentReady }
            #expect(abs(web.scrollView.contentOffset.y - target) <= web.defaultLineHeight, "at the position read")
            web.scrollView.setContentOffset(CGPoint(x: 0, y: 600), animated: false)
            try await Self.wait("the reading position follows") { web.readingOffset == 600 }
            for exchange in server.exchanges("\(path)/slowframe.html") where !exchange.disconnected { #expect(await exchange.release()) }
            try await Self.wait("the frame finishes") { !web.isLoading }
            _ = try await script(web, "await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))); return true;")
            #expect(web.scrollView.contentOffset.y == 600, "no jump when the frame finishes")
            #expect(web.readingOffset == 600)
        }
    }

    /// Without content rules, the document's Content-Security-Policy governs. It cannot see into a remote frame, and
    /// `object-src` admits pictures whatever `img-src` says, so with one class allowed and the other denied, frames,
    /// objects and embeds are refused, as are the denied class's own loads; the allowed class still loads.
    @Test(arguments: [(images: true, streaming: false), (images: false, streaming: true)])
    func contentSecurityPolicyFallbackRefusesWhatItCannotEnforce(_ options: (images: Bool, streaming: Bool)) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShownotesRules-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let broken = ShownotesContentRules(store: try #require(WKContentRuleListStore(url: folder)),
                                           definitions: [("AntennaPodShownotesBroken", "not json")])
        try await withFixture { server, identity, host in
            let environment = try Environment(.cellular, images: options.images, streaming: options.streaming, rules: broken)
            let path = "/\(UUID().uuidString)/mixed"
            let base = server.url(path)
            let web = notes(environment, "<img src='\(base)/a.png'><iframe src='\(base)/frame.html'></iframe>"
                + "<object data='\(base)/b.png' type='image/png'></object><embed src='\(base)/c.png' type='image/png'>"
                + "<video src='\(base)/a.wav' preload='metadata'></video>", in: host, trusting: identity)
            defer { web.removeFromSuperview() }
            try await ready(web)
            #expect(broken.isResolved && broken.lists == nil)
            _ = try await script(web, Self.mediaTrigger)
            let deadline = ContinuousClock.now + .seconds(5)
            while server.count("\(path)/a.wav") == 0, ContinuousClock.now < deadline,
                  try await script(web, Self.mediaDone) as? Bool != true { try await Task.sleep(for: .milliseconds(50)) }
            _ = try await script(web, "await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))); return true;")
            let counts = ["a.png", "frame.html", "frameimage.png", "b.png", "c.png", "a.wav"].map { server.count("\(path)/\($0)") }
            print("SHOWNOTES_CSP_MIXED images=\(options.images) streaming=\(options.streaming) counts=\(counts)")
            #expect(options.images ? counts[0] >= 1 : counts[0] == 0, "picture \(counts)")
            #expect(counts[1] == 0 && counts[2] == 0, "a remote frame and its picture \(counts)")
            #expect(counts[3] == 0 && counts[4] == 0, "object and embed pictures \(counts)")
            #expect(options.streaming ? counts[5] >= 1 : counts[5] == 0, "media \(counts)")
        }
    }

    /// Bytes a paced response still delivers after the class is denied, until the client disconnects: a measured
    /// fixture result for this Simulator, not a guarantee (allowed WebKit loads have no strict cellular-byte ceiling).
    @Test(arguments: [ShownotesSubresourceTests.Held.picture, .media])
    func overshootAfterTighteningIsMeasured(_ held: Held) async throws {
        try await withFixture { server, identity, host in
            let environment = try Environment(.wifi, images: held.heavy, streaming: false)
            let path = "/\(UUID().uuidString)/paced-\(held.rawValue)"
            let web = notes(environment, held.html(server.url(path)), in: host, trusting: identity)
            defer { web.removeFromSuperview() }
            let exchanges = try await startHeld(held, web, server: server, path: path)
            let writers = exchanges.map { exchange in Task.detached { await exchange.pace() } }
            defer { writers.forEach { $0.cancel() } }
            try await Self.wait("paced writes flow") { exchanges.allSatisfy { $0.accepted > Self.prefix + 64 * 1024 } }
            let started = ContinuousClock.now
            exchanges.forEach { $0.mark() }
            try await environment.move(to: .cellular, expecting: held.heavy ? .small : [])
            try await Self.wait("the client disconnects", timeout: .seconds(10)) { exchanges.allSatisfy { $0.disconnected || $0.writeFailed } }
            let elapsed = ContinuousClock.now - started
            let overshoot = exchanges.map(\.acceptedSinceMark).reduce(0, +)
            print("SHOWNOTES_OVERSHOOT target=\(held.rawValue) bytes=\(overshoot) elapsed=\(elapsed)")
            #expect(overshoot <= 4 * 1024 * 1024, "lab budget at 16 KiB per 5 ms: \(overshoot) bytes")
            #expect(exchanges.allSatisfy { !$0.complete })
        }
    }

    /// A lazily loaded picture far down the notes does not load after a move to cellular with Cover images off; the
    /// same notes left on Wi-Fi load it when scrolled to (the control).
    @Test func movingToCellularBlocksLaterLoads() async throws {
        try await withFixture { server, identity, host in
            for moves in [false, true] {
                let environment = try Environment(.wifi, images: false, streaming: false)
                let path = "/\(UUID().uuidString)/lazy"
                let web = notes(environment, Self.paragraphs + Self.paragraphs + "<img id='lazy' loading='lazy' src='\(server.url(path))/a.png' width='10' height='10'>",
                                in: host, trusting: identity)
                defer { web.removeFromSuperview() }
                try await ready(web)
                #expect(server.count(path) == 0, "not yet in view")
                if moves { try await environment.move(to: .cellular, expecting: []) }
                _ = try await script(web, "document.getElementById('lazy').scrollIntoView(); return true;")
                try await Self.wait("the picture is decided") {
                    try await script(web, "return document.getElementById('lazy').complete;") as? Bool == true
                }
                #expect(server.count(path) == (moves ? 0 : 1), "moved to cellular: \(moves)")
                #expect(try await script(web, "return document.getElementById('lazy').naturalWidth;") as? Int == (moves ? 0 : 4))
            }
        }
    }

    // MARK: Looser changes

    /// When the network or an option allows a class the notes use, they are rebuilt (when shown) and it loads once,
    /// at the position read, without using a recovery.
    @Test func aLooserChangeLoadsTheBlockedClassOnceWhenShown() async throws {
        try await withFixture { server, identity, host in
            let environment = try Environment(.cellular, images: false, streaming: false)
            let path = "/\(UUID().uuidString)/looser"
            let web = notes(environment, "<img src='\(server.url(path))/a.png'>" + Self.paragraphs, in: host, trusting: identity)
            defer { web.removeFromSuperview() }
            try await ready(web)
            #expect(server.count(path) == 0)
            let target = try #require(try await scroll(web, to: 300))
            let document = try await documentID(web)

            web.isCovered = true
            try await environment.move(to: .wifi, expecting: .all)
            #expect(web.isAwaitingLoad && server.count(path) == 0, "hidden notes wait")
            web.isCovered = false
            try await ready(web, "rebuilt with the picture")
            #expect(try await documentID(web) != document)
            #expect(server.count(path) == 1)
            #expect(try await script(web, "return document.querySelector('img').naturalWidth;") as? Int == 4)
            #expect(abs(web.scrollView.contentOffset.y - target) <= web.defaultLineHeight)
            #expect(web.recoveriesUsed == 0)

            // An option alone, on cellular: Streaming on loads nothing the notes do not use.
            let rebuilt = try await documentID(web)
            try await environment.move(to: .cellular, expecting: [])
            try environment.options(images: false, streaming: true)
            #expect(try await documentID(web) == rebuilt, "no media or frames in these notes: no rebuild")
        }
    }

    // MARK: Cache

    /// Allowed classes use WebKit's cache: a new view of the same notes on a restricted network shows a fresh cached
    /// picture without a request. A denied class is not shown even when cached (the scoped exception).
    @Test func warmCacheNewView() async throws {
        try await withFixture { server, identity, host in
            let path = "/\(UUID().uuidString)/cache"
            let html = "<img src='\(server.url(path))/cached.png'>"
            let wifi = try Environment(.wifi)
            let warm = notes(wifi, html, in: host, trusting: identity)
            try await ready(warm)
            #expect(server.count(path) == 1)
            warm.removeFromSuperview()

            let allowed = try Environment(.cellular, images: true)
            let shown = notes(allowed, html, in: host, trusting: identity)
            try await ready(shown)
            #expect(server.count(path) == 1, "served from WebKit's cache")
            #expect(try await script(shown, "return document.querySelector('img').naturalWidth;") as? Int == 4)
            shown.removeFromSuperview()

            let denied = try Environment(.cellular, images: false)
            let hidden = notes(denied, html, in: host, trusting: identity)
            defer { hidden.removeFromSuperview() }
            try await ready(hidden)
            #expect(server.count(path) == 1)
            #expect(try await script(hidden, "return document.querySelector('img').naturalWidth;") as? Int == 0, "denied, even cached")
        }
    }

    // MARK: Links, rules, policy fallback, TLS

    /// Links a person taps still open outside the notes (also `target=_blank`), and timecodes still seek; the notes
    /// themselves request nothing.
    @Test func tappedLinksAndTimecodesStillWork() async throws {
        try await withFixture { server, identity, host in
            let environment = try Environment(.cellular, images: false, streaming: false)
            let path = "/\(UUID().uuidString)/links"
            var opened: [String] = [], times: [Int32] = []
            let web = notes(environment, "<p><a id='a' href='\(server.url(path))/page'>Page</a> <a id='b' target='_blank' href='\(server.url(path))/blank'>Blank</a> 0:30</p>",
                            in: host, trusting: identity)
            web.openLink = { opened.append($0) }
            web.selectTimecode = { times.append($0) }
            defer { web.removeFromSuperview() }
            try await ready(web)
            _ = try await script(web, "document.getElementById('a').click(); document.getElementById('b').click(); document.querySelector('a.timecode').click(); return true;")
            try await Self.wait("links handled") { opened.count == 2 && times.count == 1 }
            #expect(opened == [server.url(path) + "/page", server.url(path) + "/blank"])
            #expect(times == [30_000])
            #expect(server.count(path) == 0)
        }
    }

    /// The rules for the current policy are installed before the first load, even when they are first compiled then.
    @Test func rulesInstalledBeforeFirstLoad() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShownotesRules-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cold = ShownotesContentRules(store: try #require(WKContentRuleListStore(url: folder)))
        try await withFixture { server, identity, host in
            let environment = try Environment(.cellular, images: false, streaming: false, rules: cold)
            #expect(!cold.isResolved, "a cold store")
            let path = "/\(UUID().uuidString)/cold"
            let web = notes(environment, "<img src='\(server.url(path))/a.png'>", in: host, trusting: identity)
            defer { web.removeFromSuperview() }
            #expect(web.isAwaitingRules && !web.isLoading && web.url == nil, "nothing loads before the rules")
            try await ready(web)
            #expect(cold.isResolved && !web.isAwaitingRules)
            #expect(server.count(path) == 0)
        }
    }

    /// When WebKit cannot compile the rules, a strict Content-Security-Policy in the document governs the same classes.
    @Test func contentSecurityPolicyFallbackWhenRulesFail() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShownotesRules-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let broken = ShownotesContentRules(store: try #require(WKContentRuleListStore(url: folder)),
                                           definitions: [("AntennaPodShownotesBroken", "not json")])
        try await withFixture { server, identity, host in
            let environment = try Environment(.cellular, images: false, streaming: false, rules: broken)
            let path = "/\(UUID().uuidString)/policy"
            let web = notes(environment, "<img src='\(server.url(path))/a.png'><video src='\(server.url(path))/held.wav' preload='auto'></video>" + Self.paragraphs,
                            in: host, trusting: identity)
            defer { web.removeFromSuperview() }
            try await ready(web)
            #expect(broken.isResolved && broken.lists == nil)
            #expect(server.count(path) == 0)
            try await environment.move(to: .wifi, expecting: .all)
            try await Self.wait("rebuilt with the picture") { server.count("\(path)/a.png") == 1 }
            _ = try await startHeld(.media, web, server: server, path: "\(path)/held.wav")
            try await environment.move(to: .cellular, expecting: [])
            try await Self.wait("the media load ends with its document") { server.exchanges("\(path)/held.wav").allSatisfy(\.disconnected) }
        }
    }

    /// The TLS fixture's own controls: the pinned certificate loads on an unrestricted network, so a zero elsewhere is
    /// the policy and not a trust failure; a different certificate is refused (the hook trusts only the pinned one).
    @Test func tlsFixtureControls() async throws {
        try await withFixture { server, identity, host in
            let environment = try Environment(.wifi)
            let path = "/\(UUID().uuidString)/tls"
            let web = notes(environment, "<img src='\(server.url(path))/a.png'>", in: host, trusting: identity)
            defer { web.removeFromSuperview() }
            try await ready(web)
            #expect(server.count(path) == 1)
            #expect(try await script(web, "return document.querySelector('img').naturalWidth;") as? Int == 4)
        }
        try await withFixture(identity: "other") { server, identity, host in
            let environment = try Environment(.wifi)
            let path = "/\(UUID().uuidString)/untrusted"
            let web = notes(environment, "<img src='\(server.url(path))/a.png'>", in: host, trusting: identity)
            defer { web.removeFromSuperview() }
            try await ready(web)
            #expect(server.connections >= 1, "the picture was attempted")
            #expect(server.count(path) == 0, "no request over an untrusted certificate")
            #expect(try await script(web, "return document.querySelector('img').naturalWidth;") as? Int == 0)
        }
    }
}
