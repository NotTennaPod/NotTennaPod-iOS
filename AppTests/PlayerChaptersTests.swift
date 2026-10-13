import UIKit
import Testing
@testable import NotTennaPod
@testable import NotTennaPodCore

@MainActor private final class ChapterTestEngine: PlaybackEngine {
    var reading: PlaybackEngineReading?
    var onEvent: (@MainActor (PlaybackEngineEvent) -> Void)?
    var commands: [String] = []
    private var generation: UUID?, command: UUID?
    private var position: Int32 = 0, playing = false
    func load(episode: LibraryEpisode, generation: UUID, positionMilliseconds: Int64) {
        self.generation = generation; command = generation; position = Int32(positionMilliseconds); playing = false
    }
    func play(commandID: UUID) { command = commandID; playing = true; reading?.commandID = commandID; reading?.sample.status = .playing; commands.append("play") }
    func pause(commandID: UUID) { command = commandID; playing = false; reading?.commandID = commandID; reading?.sample.status = .paused; commands.append("pause") }
    func seek(to positionMilliseconds: Int64, commandID: UUID) {
        command = commandID; position = Int32(positionMilliseconds)
        reading?.commandID = commandID; reading?.sample.positionMilliseconds = position; commands.append("seek:\(position)")
    }
    func unload() { reading = nil }
    func setSpeed(_ speed: Float, commandID: UUID) throws { command = commandID; reading?.commandID = commandID }
    func ready() {
        guard let generation, let command else { return }
        let value = PlaybackEngineReading(generation:generation,commandID:command,
            sample:.init(positionMilliseconds:position,durationMilliseconds:60_000,status:playing ? .playing : .paused))
        reading = value; onEvent?(.ready(value))
    }
    func buffer(_ value: Bool) {
        reading?.buffering = value
        if let reading { onEvent?(.stateChanged(reading)) }
    }
    func tick(_ position: Int32) {
        reading?.sample.positionMilliseconds = position
        if let reading { onEvent?(.position(reading)) }
    }
}

private actor ChapterTestHTTP: FeedHTTPTransport {
    var starts = [0,20,40]
    var titles: [String]?
    var images: [String?]?
    var links: [String]?
    var holdNext = false
    var held: CheckedContinuation<Void,Never>?
    var cancelled = false
    func arm() { holdNext = true; cancelled = false }
    func isHeld() -> Bool { held != nil }
    func release() { held?.resume(); held = nil }
    func replaceLinks(_ value: [String]) { links = value }
    func replaceImages(_ value: [String?]) { images = value }
    func replaceTitles(_ value: [String]) { titles = value }
    func replace(_ value: [Int]) { starts = value }
    func send(_ request: URLRequest) async throws -> FeedHTTPResponse {
        let chapters = starts.enumerated().map { index, start in
            var value: [String:Any] = ["startTime":start,"title":titles?[index] ?? "Chapter \(start)","url":links?[index] ?? "https://example.invalid/chapter/\(start)"]
            if let image = images?[index] { value["img"] = image }
            return value
        }
        if holdNext {
            holdNext = false
            await withCheckedContinuation { held = $0 }
            cancelled = Task.isCancelled
        }
        return .init(url:request.url!,status:200,headers:["Cache-Control":"no-store"],
                     body:try JSONSerialization.data(withJSONObject:["chapters":chapters]))
    }
}

@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct PlayerChaptersTests {
    private func find<T: UIView>(_ id: String, in view: UIView) -> T? {
        if view.accessibilityIdentifier == id, let value = view as? T { return value }
        return view.subviews.lazy.compactMap { find(id,in:$0) as T? }.first
    }
    private func player(in view: UIView) -> PlayerView? { (view as? PlayerView) ?? view.subviews.lazy.compactMap { player(in:$0) }.first }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(10)) }
        try #require(condition())
    }
    private func fixture(stored: Bool = true, feedImage: String? = nil, _ body: @MainActor (FeedLibraryStore,PlaybackCoordinator,ChapterTestEngine,ChapterTestHTTP,EpisodeChapterAccess,TimeDisplayPreferenceStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChapterViews-\(UUID())")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store = try FeedLibraryStore(url:directory.appendingPathComponent("library.sqlite"))
        do {
            var episode = ParsedEpisode(identifier:"episode",title:"Chapter episode",description:"Notes",
                media:.init(url:"file:///unregistered-test-media.mp3",size:0,durationMilliseconds:60_000))
            if stored { episode.chapters = [0,20,40].map { .init(startMilliseconds:Int64($0*1000),title:"Chapter \($0)") } }
            episode.chapterURL = "https://example.invalid/chapters.json"
            let source = URL(string:"https://example.invalid/feed")!
            var metadata = ParsedFeed(format:.rss,title:"Chapters",episodes:[episode]); metadata.imageURL = feedImage
            let feed = try await store.insert(.init(feed:metadata,source:source.absoluteString,responseURL:source,validator:nil,permanentRedirectURL:nil))
            let engine = ChapterTestEngine(), playback = PlaybackCoordinator(store:store,engine:engine)
            try await playback.select(episodeID:feed.episodes[0].id,play:false); engine.ready()
            try await wait { playback.phase == .paused }
            let http = ChapterTestHTTP()
            let access = EpisodeChapterAccess(store:store,loader:.init(transport:http,cache:URLCache(memoryCapacity:0,diskCapacity:0),userAgent:"chapter-test"),proxy:{ .init() })
            try await body(store,playback,engine,http,access,TimeDisplayPreferenceStore(file:directory.appendingPathComponent("time.json")))
            try await playback.stop(); try await store.close()
        } catch { try? await store.close(); throw error }
    }
    private func withController(store: FeedLibraryStore, playback: PlaybackCoordinator, access: EpisodeChapterAccess,
        time: TimeDisplayPreferenceStore, body: @MainActor (LibraryViewController,PlayerView) async throws -> Void) async throws {
        let controller = LibraryViewController(library:store,startupError:nil,downloads:nil,playback:playback,
            timeDisplayPreferences:time,navigationPreferences:nil,speedPreferences:nil,mobileNetworkPreferences:nil,usage:nil,chapterAccess:access)
        try await withViewTestWindow { host,_ in
            host.addChild(controller); host.view.addSubview(controller.view); controller.didMove(toParent:host)
            defer { controller.dismiss(animated:false); controller.willMove(toParent:nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
            controller.view.frame = host.view.bounds; await controller.reloadLibrary()?.value
            let view = try #require(player(in:controller.view))
            view.setExpanded(true,animated:false); controller.view.layoutIfNeeded()
            let chapters: UIButton = try #require(find("playerChapters",in:view))
            try await wait { chapters.superview?.isHidden == false }
            try await body(controller,view)
        }
    }
    @Test func bufferingFeedbackRetainsChaptersWithoutPercentageFill() async throws {
        try await fixture { store,playback,engine,_,access,time in
            try await withController(store:store,playback:playback,access:access,time:time) { _,view in
                let seek: PlayerSeekBar = try #require(find("playerSeek",in:view))
                let loading: PlayerLoadingIndicator = try #require(find("playerLoading",in:view))
                try await wait { seek.chapterFractions.count == 3 }
                for held in [true,false,true,false] {
                    engine.buffer(held)
                    try await wait { loading.isAnimating == held }
                    #expect(seek.secondaryValue == 0)
                    #expect(seek.chapterFractions == [0,1.0/3,2.0/3])
                    #expect(!playback.wantsPlayback)
                }
                #expect(engine.commands.isEmpty)
            }
        }
    }
    @Test func failedLinkNoticeKeepsLocalGeometryAndCleansUpWithOwner() async throws {
        try await fixture { store,playback,_,_,access,time in
            var retainedWindow: UIWindow?
            var retainedNotice: UILabel?
            try await withController(store:store,playback:playback,access:access,time:time) { controller,view in
                let window = try #require(controller.view.window)
                retainedWindow = window
                try #require(URL(string:"http://[") == nil, "precondition: an address no browser can open")
                view.openLink?("http://[")
                let first: UILabel = try #require(find("applicationNotice",in:window))
                #expect(first.text == Appearance.text("pref_no_browser_found"))
                #expect(!first.isUserInteractionEnabled)
                for (width,height,left,right) in [(320.0,600.0,7.0,43.0),(800,900,43,7),(466,678,0,84)] {
                    controller.additionalSafeAreaInsets = .init(top:0,left:left,bottom:0,right:right)
                    controller.view.frame = CGRect(x:11,y:9,width:width,height:height)
                    controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                    let safe = controller.view.convert(controller.view.safeAreaLayoutGuide.layoutFrame,to:window)
                    #expect(first.frame.minX >= safe.minX)
                    #expect(first.frame.maxX <= safe.maxX)
                    #expect(first.frame.height > 0)
                    #expect(abs(first.frame.maxY - (view.convert(view.bounds,to:window).maxY - 24)) <= 1)
                }
                view.openLink?("http://[")
                #expect(first.superview == nil)
                let replacement: UILabel = try #require(find("applicationNotice",in:window))
                #expect(replacement !== first)
                // Collapsed to the mini player, the notice sits above it (MainActivity anchors its Snackbar there).
                view.setExpanded(false,animated:false); controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
                #expect(abs(replacement.frame.maxY - (view.convert(view.bounds,to:window).minY - 24)) <= 1)
                retainedNotice = replacement
                #expect(!playback.wantsPlayback)
            }
            try await wait { retainedNotice?.superview == nil }
            #expect(retainedWindow.flatMap { find("applicationNotice",in:$0) as UILabel? } == nil)
        }
    }
    @Test func coverSeeksKeepPauseAndDialogRowPlaysWithoutDismissing() async throws {
        try await fixture { store,playback,engine,_,access,time in
            try await withController(store:store,playback:playback,access:access,time:time) { controller,view in
                let next: UIButton = try #require(find("playerNextChapter",in:view))
                let previous: UIButton = try #require(find("playerPreviousChapter",in:view))
                let chapters: UIButton = try #require(find("playerChapters",in:view))
                let notes: UIButton = try #require(find("playerShownotes",in:view))
                try await wait { (find("playerSeek",in:view) as PlayerSeekBar?)?.chapterFractions.count == 3 }
                view.layoutIfNeeded()
                #expect(abs(chapters.convert(chapters.bounds,to:view).midY - notes.convert(notes.bounds,to:view).midY) < 1)
                next.sendActions(for:.touchUpInside); try await wait { playback.sample?.positionMilliseconds == 20_000 }
                #expect(!playback.wantsPlayback)
                next.sendActions(for:.touchUpInside); try await wait { playback.sample?.positionMilliseconds == 40_000 && next.alpha == 0 }
                #expect(next.bounds.width == previous.bounds.width)
                previous.sendActions(for:.touchUpInside); try await wait { playback.sample?.positionMilliseconds == 20_000 }
                chapters.sendActions(for:.touchUpInside)
                try await wait { controller.presentedViewController is ChaptersController && controller.presentedViewController?.isBeingPresented == false }
                let dialog = try #require(controller.presentedViewController as? ChaptersController)
                try await wait { (find("chaptersList",in:dialog.view) as UITableView?)?.numberOfRows(inSection:0) == 3 }
                dialog.view.layoutIfNeeded()
                let button: UIButton = try #require(find("chapterPlay-0",in:dialog.view))
                button.sendActions(for:.touchUpInside)
                try await wait { playback.wantsPlayback && playback.sample?.positionMilliseconds == 0 }
                #expect(controller.presentedViewController === dialog)
                #expect(Set(engine.commands.suffix(2)) == ["play","seek:0"])
                let close: UIButton = try #require(find("chaptersClose",in:dialog.view)); close.sendActions(for:.touchUpInside)
                try await wait { controller.presentedViewController == nil }
                #expect(playback.wantsPlayback)
            }
        }
    }
    @Test func dialogRefreshLeavesCoverAndSeekbarListsIndependent() async throws {
        try await fixture { store,playback,_,http,access,time in
            try await withController(store:store,playback:playback,access:access,time:time) { controller,view in
                let chapters: UIButton = try #require(find("playerChapters",in:view))
                let seek: PlayerSeekBar = try #require(find("playerSeek",in:view))
                try await wait { seek.chapterFractions.count == 3 }
                chapters.sendActions(for:.touchUpInside)
                try await wait { controller.presentedViewController is ChaptersController && controller.presentedViewController?.isBeingPresented == false }
                let dialog = try #require(controller.presentedViewController as? ChaptersController)
                let table: UITableView = try #require(find("chaptersList",in:dialog.view))
                try await wait { table.numberOfRows(inSection:0) == 3 }
                await http.replace([0,10,20,30])
                let refresh: UIButton = try #require(find("chaptersRefresh",in:dialog.view))
                #expect(refresh.alpha == 1); refresh.sendActions(for:.touchUpInside)
                try await wait { table.numberOfRows(inSection:0) == 4 }
                #expect(seek.chapterFractions == [0,1.0/3,2.0/3])
                #expect(!playback.wantsPlayback)
            }
        }
    }
    @Test func accessibilityAdjustmentSnapsToChapterAndDoesNotSendASecondSeek() async throws {
        try await fixture { store,playback,engine,_,access,time in
            try await withController(store:store,playback:playback,access:access,time:time) { _,view in
                let seek: PlayerSeekBar = try #require(find("playerSeek",in:view))
                try await wait { seek.chapterFractions.count == 3 }
                try await playback.seek(to:19_000)
                try await wait { playback.sample?.positionMilliseconds == 19_000 }
                view.update(feed:try await store.feeds().first)
                let before = engine.commands.count
                seek.accessibilityIncrement()
                try await wait { engine.commands.count > before }
                #expect(Array(engine.commands.dropFirst(before)) == ["seek:20000"])
                #expect(!playback.wantsPlayback)
            }
        }
    }
    @Test func successfulEmptyRefreshDismissesAndLeavesOtherSurfacesLoaded() async throws {
        try await fixture(stored:false) { store,playback,_,http,access,time in
            try await withController(store:store,playback:playback,access:access,time:time) { controller,view in
                let chapters: UIButton = try #require(find("playerChapters",in:view))
                let seek: PlayerSeekBar = try #require(find("playerSeek",in:view))
                try await wait { seek.chapterFractions.count == 3 }
                chapters.sendActions(for:.touchUpInside)
                try await wait { controller.presentedViewController is ChaptersController && controller.presentedViewController?.isBeingPresented == false }
                let dialog = try #require(controller.presentedViewController as? ChaptersController)
                let table: UITableView = try #require(find("chaptersList",in:dialog.view))
                try await wait { table.numberOfRows(inSection:0) == 3 }
                await http.replace([])
                let refresh: UIButton = try #require(find("chaptersRefresh",in:dialog.view)); refresh.sendActions(for:.touchUpInside)
                try await wait { controller.presentedViewController == nil }
                #expect(chapters.superview?.isHidden == false && seek.chapterFractions.count == 3 && !playback.wantsPlayback)
            }
        }
    }
    @Test func dismissingHeldRefreshRetiresOldDialogAndPreservesAccessibleActions() async throws {
        // Each way of closing once; playing and paused both covered (a full 2×3 grid repeated the same checks).
        for (dismissal, playing) in [("close",false),("accessibility",true),("keyboard",false),("close",true)] {
            do {
                try await fixture(stored:false) { store,playback,_,http,access,time in
                    defer { Task { await http.release() } }
                    if playing { try await playback.play() }
                    try await withController(store:store,playback:playback,access:access,time:time) { controller,view in
                        let chapters: UIButton = try #require(find("playerChapters",in:view))
                        chapters.sendActions(for:.touchUpInside)
                        try await wait { controller.presentedViewController is ChaptersController && controller.presentedViewController?.isBeingPresented == false }
                        let old = try #require(controller.presentedViewController as? ChaptersController)
                        let oldTable: UITableView = try #require(find("chaptersList",in:old.view))
                        try await wait { oldTable.numberOfRows(inSection:0) == 3 }
                        old.view.layoutIfNeeded()
                        let play: UIButton = try #require(find("chapterPlay-0",in:old.view))
                        let link: UIButton = try #require(find("chapterLink-0",in:old.view))
                        let close: UIButton = try #require(find("chaptersClose",in:old.view))
                        let refresh: UIButton = try #require(find("chaptersRefresh",in:old.view))
                        #expect(old.view.accessibilityViewIsModal && play.accessibilityLabel == "Play chapter")
                        // App-host UIKit reports false even for a standard UIButton. The actual
                        // XCUI journey asserts exposed Play/link labels and hittability instead.
                        #expect(link.title(for:.normal) == "https://example.invalid/chapter/0")
                        #expect(close.title(for:.normal) == "Close" && refresh.title(for:.normal) == "Refresh")
                        #expect(!refresh.accessibilityElementsHidden && refresh.isUserInteractionEnabled)
                        await http.replace([]); await http.arm(); refresh.sendActions(for:.touchUpInside)
                        let deadline = ContinuousClock.now + .seconds(8)
                        while !(await http.isHeld()), ContinuousClock.now < deadline { await Task.yield() }
                        #expect(await http.isHeld())
                        #expect((find("chaptersLoading",in:old.view) as UIActivityIndicatorView?)?.isAnimating == true)
                        if dismissal == "keyboard" {
                            let command = try #require(old.keyCommands?.first { $0.input == UIKeyCommand.inputEscape })
                            let action = try #require(command.action)
                            // UIKeyCommand.h requires one sender parameter; dispatch with that sender.
                            #expect(NSStringFromSelector(action).filter { $0 == ":" }.count == 1)
                            #expect(UIApplication.shared.sendAction(action,to:old,from:command,for:nil))
                        } else if dismissal == "accessibility" { #expect(old.accessibilityPerformEscape()) }
                        else { close.sendActions(for:.touchUpInside) }
                        try await wait { controller.presentedViewController == nil }
                        #expect(old.keyCommands?.isEmpty != false)
                        await http.replace([0,20,40])
                        chapters.sendActions(for:.touchUpInside)
                        try await wait { controller.presentedViewController is ChaptersController && controller.presentedViewController?.isBeingPresented == false }
                        let fresh = try #require(controller.presentedViewController as? ChaptersController)
                        let table: UITableView = try #require(find("chaptersList",in:fresh.view))
                        try await wait { table.numberOfRows(inSection:0) == 3 }
                        #expect(fresh !== old)
                        await http.release()
                        let cancelledDeadline = ContinuousClock.now + .seconds(8)
                        while !(await http.cancelled), ContinuousClock.now < cancelledDeadline { await Task.yield() }
                        #expect(await http.cancelled)
                        #expect(controller.presentedViewController === fresh && table.numberOfRows(inSection:0) == 3)
                        #expect(playback.wantsPlayback == playing)
                        #expect(playback.sample?.positionMilliseconds == 0)
                    }
                }
            }
        }
    }
    @Test func dialogKeepsOpeningMarginsWhileBoundsAndAsymmetricSafeAreasChange() async throws {
        try await fixture(stored:false) { store,playback,engine,http,access,_ in
            await http.replace(Array(0..<20))
            for (opening, margin): (CGSize, CGFloat) in [(.init(width:402,height:874),80), (.init(width:874,height:402),24)] {
                try await withViewTestWindow { host,_ in
                    let dialog = ChaptersController(playback:playback,library:store,access:access,
                        notice:{ _ in },failure:{ Issue.record($0) },openLink:{ _ in })
                    host.addChild(dialog)
                    dialog.view.frame = CGRect(origin:.zero,size:opening)
                    host.view.addSubview(dialog.view); dialog.didMove(toParent:host)
                    defer {
                        dialog.willMove(toParent:nil); dialog.view.removeFromSuperview(); dialog.removeFromParent()
                    }
                    let table: UITableView = try #require(find("chaptersList",in:dialog.view))
                    try await wait { table.numberOfRows(inSection:0) == 20 }
                    dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded(); table.layoutIfNeeded()
                    table.scrollToRow(at:IndexPath(row:5,section:0),at:.top,animated:false); table.layoutIfNeeded()
                    try #require(table.contentOffset.y > 0, "Scroll precondition: rows \(table.numberOfRows(inSection:0)), content \(table.contentSize), bounds \(table.bounds)")
                    let panel: UIScrollView = try #require(find("chaptersPanel",in:dialog.view))
                    // Source style-1.0 probe: opening portrait retains80dp after rotation;
                    // opening landscape retains24dp, even when current resources resolve80dp.
                    for size in [CGSize(width:874,height:402),CGSize(width:402,height:874)] {
                        for edges in [UIEdgeInsets(top:7,left:11,bottom:13,right:43),
                                      UIEdgeInsets(top:13,left:43,bottom:7,right:11)] {
                            dialog.additionalSafeAreaInsets = edges
                            dialog.view.frame = CGRect(origin:.zero,size:size)
                            dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
                            let safe = dialog.view.bounds.inset(by:dialog.view.safeAreaInsets)
                            // Dialog keeps its opening vertical margins (within a point) and stays centred.
                            #expect(abs(panel.frame.minY - (safe.minY + margin)) <= 1)
                            #expect(abs(panel.frame.maxY - (safe.maxY - margin)) <= 1)
                            #expect(abs(panel.frame.midX - safe.midX) <= 1)
                            #expect(panel.frame.minX >= safe.minX && panel.frame.maxX <= safe.maxX)
                            let visible = (table.indexPathsForVisibleRows ?? []).first {
                                table.rectForRow(at:$0).intersection(table.bounds).height > 1
                            }?.row
                            #expect(visible == 5, "Visible row \(String(describing:visible)); offset \(table.contentOffset.y)")
                            #expect(table.numberOfRows(inSection:0) == 20)
                            let close: UIButton = try #require(find("chaptersClose",in:dialog.view))
                            #expect(panel.bounds.contains(close.convert(close.bounds,to:panel)))
                            #expect(panel.contentSize.height <= panel.bounds.height + 0.5)
                            #expect(!playback.wantsPlayback && playback.sample?.positionMilliseconds == 0)
                            #expect(engine.commands.isEmpty)
                        }
                    }
                }
            }
        }
    }
    @Test func dialogRowsReflowOnWideConfigurationAndLinkTextSizeChanges() async throws {
        try await fixture(stored:false) { store,playback,_,_,access,time in
            try await withController(store:store,playback:playback,access:access,time:time) { controller,view in
                let chapters: UIButton = try #require(find("playerChapters",in:view))
                chapters.sendActions(for:.touchUpInside)
                try await wait { controller.presentedViewController is ChaptersController && controller.presentedViewController?.isBeingPresented == false }
                let dialog = try #require(controller.presentedViewController as? ChaptersController)
                let table: UITableView = try #require(find("chaptersList",in:dialog.view))
                try await wait { table.numberOfRows(inSection:0) == 3 }
                let openingMargin = SourceDialogLayout.verticalBackgroundInset(configurationSize:dialog.view.bounds.size)
                for width: CGFloat in [1100, 800, 1100] {
                    dialog.view.frame = CGRect(x:0,y:0,width:width,height:1000)
                    dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
                    let panel: UIScrollView = try #require(find("chaptersPanel",in:dialog.view))
                    let safe = dialog.view.bounds.inset(by:dialog.view.safeAreaInsets)
                    #expect(abs(panel.bounds.height - (safe.height - 2 * openingMargin)) < 1)
                    #expect(table.bounds.height > table.contentSize.height)
                    let cell = try #require(table.cellForRow(at:IndexPath(row:0,section:0)))
                    cell.traitOverrides.preferredContentSizeCategory = .large
                    cell.updateTraitsIfNeeded()
                    cell.layoutIfNeeded()
                    #expect(abs(cell.contentView.frame.minX - (width >= 1000 ? 56 : 0)) <= 1)
                    #expect(abs(cell.contentView.frame.maxX - (cell.bounds.maxX - (width >= 1000 ? 56 : 0))) <= 1)
                    let link: UIButton = try #require(find("chapterLink-0",in:cell))
                    #expect(!link.isHidden)
                    let initial = try #require(link.titleLabel?.font.pointSize)
                    cell.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
                    cell.updateTraitsIfNeeded(); cell.setNeedsLayout(); cell.layoutIfNeeded()
                    #expect(link.titleLabel?.font.pointSize == Appearance.font(14,compatibleWith:cell.traitCollection).pointSize)
                    #expect((link.titleLabel?.font.pointSize ?? 0) > initial)
                }
                let panel: UIScrollView = try #require(find("chaptersPanel",in:dialog.view))
                dialog.view.frame = CGRect(x:0,y:0,width:320,height:190)
                dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
                #expect(panel.isScrollEnabled)
                panel.contentOffset.y = max(0,panel.contentSize.height-panel.bounds.height)
                dialog.view.frame = CGRect(x:0,y:0,width:800,height:1000)
                dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded()
                #expect(!panel.isScrollEnabled && panel.contentOffset.y == 0)
                #expect(!playback.wantsPlayback && playback.sample?.positionMilliseconds == 0)
            }
        }
    }
    @Test func chapterTypographyPreservesEmptyLineAndWrappedRhythmDuringReflow() async throws {
        try await fixture(stored:false) { store,playback,_,http,access,time in
            await http.replace([0,15,30,45])
            await http.replaceTitles(["Opening", "Opening\nSecond line", "", "This deliberately long chapter title wraps over several lines and must stop at the second line with an ellipsis"])
            try await withController(store:store,playback:playback,access:access,time:time) { controller,view in
                let chapters: UIButton = try #require(find("playerChapters",in:view))
                chapters.sendActions(for:.touchUpInside)
                try await wait { controller.presentedViewController is ChaptersController && controller.presentedViewController?.isBeingPresented == false }
                let dialog = try #require(controller.presentedViewController as? ChaptersController)
                let table: UITableView = try #require(find("chaptersList",in:dialog.view))
                try await wait { table.numberOfRows(inSection:0) == 4 }
                var normalHeight: CGFloat = 0
                var oneLine: [UIContentSizeCategory: CGFloat] = [:]
                for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge, .large] {
                    dialog.view.traitOverrides.preferredContentSizeCategory = category
                    dialog.view.updateTraitsIfNeeded()
                    for (width, scale): (CGFloat, CGFloat) in [(800,3), (360,3), (800,2), (800,3)] {
                        dialog.view.traitOverrides.displayScale = scale
                        dialog.view.updateTraitsIfNeeded()
                        dialog.view.frame = CGRect(x:0,y:0,width:width,height:1400)
                        dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded(); table.layoutIfNeeded()
                        let first = table.rectForRow(at:IndexPath(row:0,section:0)).height
                        let second = table.rectForRow(at:IndexPath(row:1,section:0)).height
                        let empty = table.rectForRow(at:IndexPath(row:2,section:0)).height
                        // Visible rhythm: an empty title keeps a one-line row, a two-line title adds
                        // one line, and a long title stops at two lines (tolerances imperceptible).
                        // An empty title keeps a one-line row. At narrow widths "Opening" itself may wrap at the
                        // largest sizes, so compare with the one-line height measured at 800 pt for this size.
                        if width == 800 { oneLine[category] = first }
                        #expect(abs((oneLine[category] ?? first) - empty) <= 2, "one line \(oneLine[category] ?? first) empty \(empty) width \(width) scale \(scale) \(category.rawValue)")
                        if width == 800 {
                            let rhythm = 20 * Appearance.font(16,compatibleWith:dialog.view.traitCollection).pointSize / 16
                            #expect(abs(second-first-rhythm) <= 2)
                        }
                        let wrapped = table.rectForRow(at:IndexPath(row:3,section:0)).height
                        #expect(abs(wrapped-second) <= 2)
                        if category == .large { normalHeight = first }
                        else { #expect(first > normalHeight) }
                        for row in 0..<4 {
                            table.scrollToRow(at:IndexPath(row:row,section:0),at:.middle,animated:false); table.layoutIfNeeded()
                            let cell = try #require(table.cellForRow(at:IndexPath(row:row,section:0)))
                            let duration: UILabel = try #require(cell.contentView.subviews.compactMap { $0 as? UILabel }.first { $0.text?.hasPrefix("Duration:") == true })
                            let link: UIButton = try #require(find("chapterLink-\(row)",in:cell))
                            #expect(duration.frame.minY >= link.frame.maxY)
                            #expect(abs(cell.bounds.height-duration.frame.maxY-12) <= 2)
                            #expect(cell.contentView.bounds.contains(duration.frame))
                        }
                    }
                }
                #expect(!playback.wantsPlayback && playback.sample?.positionMilliseconds == 0)
            }
        }
    }
    @Test func wrappedChapterRenderingAndLastRowSurviveTextAndViewportChanges() async throws {
        try await fixture(stored:false) { store,playback,_,http,access,time in
            let titles = (0..<20).map { index in
                index == 0 ? "This deliberately long chapter title wraps over several lines and must stop at the second line with an ellipsis" :
                index == 1 ? "Opening\nSecond line" : index == 2 ? "" : "Chapter \(index) with a long title that wraps onto another line"
            }
            await http.replace(Array(0..<20)); await http.replaceTitles(titles)
            await http.replaceLinks((0..<20).map { "https://example.invalid/chapter/\($0)?long=link" })
            try await withController(store:store,playback:playback,access:access,time:time) { controller,view in
                let chapters: UIButton = try #require(find("playerChapters",in:view)); chapters.sendActions(for:.touchUpInside)
                try await wait { controller.presentedViewController is ChaptersController && controller.presentedViewController?.isBeingPresented == false }
                let dialog = try #require(controller.presentedViewController as? ChaptersController)
                let table: UITableView = try #require(find("chaptersList",in:dialog.view))
                try await wait { table.numberOfRows(inSection:0) == 20 }
                var measurements: [[String:Any]] = []
                for category in [UIContentSizeCategory.large,.accessibilityMedium] {
                    dialog.view.traitOverrides.preferredContentSizeCategory = category; dialog.view.updateTraitsIfNeeded()
                    for (width,height) in [(360.0,800.0),(800.0,500.0),(360.0,800.0)] {
                        dialog.view.frame = CGRect(x:0,y:0,width:width,height:height)
                        dialog.view.setNeedsLayout(); dialog.view.layoutIfNeeded(); table.layoutIfNeeded()
                        for row in [0,1,2,19] {
                            table.scrollToRow(at:IndexPath(row:row,section:0),at:row == 19 ? .bottom : .top,animated:false); table.layoutIfNeeded()
                            let cell = try #require(table.cellForRow(at:IndexPath(row:row,section:0)))
                            let labels = cell.contentView.subviews.compactMap { $0 as? UILabel }
                            let title = try #require(labels.first { $0.text == titles[row] })
                            let duration = try #require(labels.first { $0.text?.hasPrefix("Duration:") == true })
                            let link: UIButton = try #require(find("chapterLink-\(row)",in:cell))
                            #expect(cell.contentView.bounds.contains(title.frame))
                            #expect(cell.contentView.bounds.contains(duration.frame))
                            #expect(title.frame.maxY <= link.frame.minY && link.frame.maxY <= duration.frame.minY)
                            // UIKit rounds scroll offsets separately from fractional row heights.
                            // Compare visible row edges in pixels; keep content containment exact.
                            let scale = max(1,table.traitCollection.displayScale)
                            func pixels(_ rect: CGRect) -> CGRect {
                                let x = (rect.minX*scale).rounded(), y = (rect.minY*scale).rounded()
                                return CGRect(x:x,y:y,width:(rect.maxX*scale).rounded()-x,height:(rect.maxY*scale).rounded()-y)
                            }
                            if cell.bounds.height <= table.bounds.height {
                                #expect(pixels(table.bounds).contains(pixels(cell.frame)))
                                #expect(table.bounds.contains(cell.contentView.convert(duration.frame,to:table)))
                                #expect(table.bounds.contains(cell.contentView.convert(link.frame,to:table)))
                            } else {
                                // Original rotated dialog clips tall rows inside its list while
                                // retaining the full footer. Each control must remain reachable.
                                let panel: UIScrollView = try #require(find("chaptersPanel",in:dialog.view))
                                let close: UIButton = try #require(find("chaptersClose",in:dialog.view))
                                #expect(panel.bounds.contains(close.convert(close.bounds,to:panel)))
                                let play: UIButton = try #require(find("chapterPlay-\(row)",in:cell))
                                for element: UIView in [title,link,duration,play] {
                                    let target = element.convert(element.bounds,to:table)
                                    table.scrollRectToVisible(target.insetBy(dx:0,dy:-1/scale),animated:false)
                                    table.layoutIfNeeded()
                                    let visible = table.bounds.intersection(panel.convert(panel.bounds,to:table))
                                    #expect(visible.contains(element.convert(element.bounds,to:table)))
                                }
                            }
                            #expect(title.numberOfLines == 2)
                            measurements.append(["category":category.rawValue,"viewport":[width,height],"row":row,
                                "rowSize":[cell.bounds.width,cell.bounds.height],"titleFont":title.font.pointSize,
                                "tableBounds":[table.bounds.minX,table.bounds.minY,table.bounds.width,table.bounds.height],
                                "cellFrame":[cell.frame.minX,cell.frame.minY,cell.frame.width,cell.frame.height],"scale":table.traitCollection.displayScale,
                                "titleFrame":[title.frame.minX,title.frame.minY,title.frame.width,title.frame.height],
                                "linkFrame":[link.frame.minX,link.frame.minY,link.frame.width,link.frame.height],
                                "durationFrame":[duration.frame.minX,duration.frame.minY,duration.frame.width,duration.frame.height]])
                            if row < 3 {
                                let renderer = UIGraphicsImageRenderer(bounds:cell.bounds)
                                let image = renderer.image { cell.layer.render(in:$0.cgContext) }
                                Attachment.record(try #require(image.pngData()),named:"chapter-\(category.rawValue)-\(Int(width))-row\(row).png")
                            }
                        }
                        #expect(!playback.wantsPlayback && playback.sample?.positionMilliseconds == 0)
                    }
                }
                Attachment.record(try JSONSerialization.data(withJSONObject:measurements,options:[.prettyPrinted,.sortedKeys]),named:"chapter-text-measurements.json")
            }
        }
    }
    @Test func chapterArtworkFitsRoundsAndClearsLetterboxAfterLoading() async throws {
        try await fixture { store,playback,_,_,access,_ in
            let oldLoader = EpisodeArtworkView.remoteLoader
            defer { EpisodeArtworkView.remoteLoader = oldLoader }
            let episode = try #require(playback.episode)
            for (size, cover) in [(CGSize(width:120,height:60),false), (CGSize(width:60,height:120),false), (CGSize(width:120,height:60),true)] {
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                let bytes = UIGraphicsImageRenderer(size:size,format:format).image { context in
                    UIColor.red.setFill(); context.fill(CGRect(origin:.zero,size:size))
                }.pngData()!
                EpisodeArtworkView.remoteLoader = { url in (bytes,HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:nil)!) }
                // Each picture has its own address; images are cached by address.
                let artwork = ChapterArtworkView(reference:"https://example.invalid/art-\(UUID()).png",episode:episode,feed:nil,library:store,access:access,coverFallback:cover)
                defer { artwork.cancelLoading() }
                try await wait { artwork.subviews.compactMap { $0 as? UIImageView }.contains { $0.image != nil } }
                for extent: CGFloat in [56,100,56] {
                    artwork.frame = CGRect(x:0,y:0,width:extent,height:extent)
                    artwork.setNeedsLayout(); artwork.layoutIfNeeded()
                    let image = try #require(artwork.subviews.compactMap { $0 as? UIImageView }.first { $0.image != nil })
                    let expected = size.width > size.height ? CGSize(width:extent,height:extent/2) : CGSize(width:extent/2,height:extent)
                    // Aspect-fit and centred (sub-point differences are invisible).
                    #expect(abs(image.frame.width - expected.width) <= 0.5 && abs(image.frame.height - expected.height) <= 0.5)
                    #expect(abs(image.frame.midX - artwork.bounds.midX) <= 0.5 && abs(image.frame.midY - artwork.bounds.midY) <= 0.5)
                    #expect(image.layer.cornerRadius == (cover ? 16 : 4))
                    #expect(artwork.backgroundColor == .clear)
                }
            }
        }
    }

    @Test func dialogMissingChapterArtworkDoesNotUseFeedErrorFallback() async throws {
        try await fixture { store,playback,_,_,access,_ in
            let oldLoader = EpisodeArtworkView.remoteLoader
            defer { EpisodeArtworkView.remoteLoader = oldLoader }
            var episode = try #require(playback.episode)
            let missing = "https://example.invalid/missing-\(UUID()).png"
            episode.details.imageURL = missing
            let url = URL(string:"https://example.invalid/art-feed")!
            var metadata = ParsedFeed(format:.rss,title:"No title placeholder",episodes:[])
            metadata.imageURL = "https://example.invalid/feed.png"
            let feed = try await store.insert(.init(feed:metadata,source:url.absoluteString,responseURL:url,validator:nil,permanentRedirectURL:nil))
            var requested: [String] = []
            EpisodeArtworkView.remoteLoader = { url in
                requested.append(url.absoluteString)
                return (Data(),HTTPURLResponse(url:url,statusCode:404,httpVersion:nil,headerFields:nil)!)
            }
            let artwork = ChapterArtworkView(reference:nil,episode:episode,feed:feed,library:store,access:access,coverFallback:false)
            defer { artwork.cancelLoading() }
            try await wait { !requested.isEmpty }
            // A main-actor barrier lets the non-suspending completed loader publish its result.
            await Task.yield()
            #expect(requested == [missing])
            let fallback = try #require(artwork.subviews.first { $0 is EpisodeArtworkView })
            #expect(fallback.subviews.compactMap { $0 as? UILabel }.allSatisfy { $0.isHidden })
        }
    }
    @Test func coverChapterImageToOrdinaryImageAndBackRetainsFitAndPause() async throws {
        try await fixture(stored:false,feedImage:"https://example.invalid/feed.png") { store,playback,_,http,access,time in
            let oldLoader = EpisodeArtworkView.remoteLoader
            defer { EpisodeArtworkView.remoteLoader = oldLoader }
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let bytes = UIGraphicsImageRenderer(size:CGSize(width:120,height:60),format:format).image { context in
                UIColor.red.setFill(); context.fill(CGRect(x:0,y:0,width:120,height:60))
            }.pngData()!
            EpisodeArtworkView.remoteLoader = { url in (bytes,HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:nil)!) }
            await http.replaceImages(["https://example.invalid/wide.png",nil,"https://example.invalid/wide.png"])
            try await withController(store:store,playback:playback,access:access,time:time) { _,view in
                try await wait { (find("playerChapterArtwork",in:view) as ChapterArtworkView?) != nil }
                let next: UIButton = try #require(find("playerNextChapter",in:view))
                next.sendActions(for:.touchUpInside)
                try await wait { playback.sample?.positionMilliseconds == 20_000 && (find("playerChapterArtwork",in:view) as ChapterArtworkView?) == nil }
                let cover: EpisodeArtworkView = try #require(find("playerCoverArtwork",in:view))
                try await wait { cover.artwork(size:CGSize(width:100,height:100),scale:1) != nil }
                view.layoutIfNeeded(); cover.layoutIfNeeded()
                let image = try #require(cover.subviews.compactMap { $0 as? UIImageView }.first { $0.image != nil })
                #expect(!cover.isHidden && cover.backgroundColor == .clear)
                #expect(abs(image.frame.width/image.frame.height-2) < 0.001)
                #expect(image.layer.cornerRadius == 16)
                let previous: UIButton = try #require(find("playerPreviousChapter",in:view))
                previous.sendActions(for:.touchUpInside)
                try await wait { playback.sample?.positionMilliseconds == 0 && (find("playerChapterArtwork",in:view) as ChapterArtworkView?) != nil }
                #expect(!playback.wantsPlayback)
            }
        }
    }
    /// CoverFragment.imgvCover: tapping the player cover plays when paused and pauses when playing.
    @Test func tappingPlayerCoverTogglesPlayback() async throws {
        try await fixture { store,playback,_,_,access,time in
            try await withController(store:store,playback:playback,access:access,time:time) { _,view in
                let cover: EpisodeArtworkView = try #require(find("playerCoverArtwork",in:view))
                #expect(cover.isUserInteractionEnabled && (cover.gestureRecognizers ?? []).contains { $0 is UITapGestureRecognizer })
                var ancestor = cover.superview
                while ancestor != nil, !(ancestor is PlayerView) { ancestor = ancestor?.superview }
                let player = try #require(ancestor as? PlayerView)
                let start = playback.wantsPlayback
                player.coverTapped(); try await wait { playback.wantsPlayback != start }
                player.coverTapped(); try await wait { playback.wantsPlayback == start }
            }
        }
    }
    @Test func pausedSeekDialogUsesStoredHighlightThenFollowsResumedPosition() async throws {
        try await fixture { store,playback,engine,_,access,time in
            try await withController(store:store,playback:playback,access:access,time:time) { controller,view in
                try await playback.seek(to:20_000)
                let id = try #require(playback.episode?.id)
                #expect(try await store.episode(id:id)?.userState.positionMilliseconds == 0)
                let chapters: UIButton = try #require(find("playerChapters",in:view))
                chapters.sendActions(for:.touchUpInside)
                try await wait { controller.presentedViewController is ChaptersController && controller.presentedViewController?.isBeingPresented == false }
                let dialog = try #require(controller.presentedViewController as? ChaptersController)
                let table: UITableView = try #require(find("chaptersList",in:dialog.view))
                try await wait { table.numberOfRows(inSection:0) == 3 }
                dialog.view.layoutIfNeeded()
                let selected = Appearance.color(0xcde4f4,0x253850)
                func highlighted(_ row: Int) -> Bool {
                    table.cellForRow(at:IndexPath(row:row,section:0))?.contentView.backgroundColor?.resolvedColor(with:dialog.view.traitCollection).cgColor == selected.resolvedColor(with:dialog.view.traitCollection).cgColor
                }
                try await wait { highlighted(0) }
                #expect(!highlighted(1) && !playback.wantsPlayback)
                try await playback.play()
                try await wait { playback.wantsPlayback }
                engine.tick(20_250); try await playback.awaitPendingOperations()
                try await wait { highlighted(1) }
                #expect(!highlighted(0) && controller.presentedViewController === dialog)
            }
        }
    }
}
