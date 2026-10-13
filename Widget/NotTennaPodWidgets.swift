import AppIntents
import SwiftUI
import WidgetKit

// The AntennaPod player widget and the Control Center
// control. The app writes what they show into the App Group (`PlayerWidgetStore`); their buttons are App Intents
// that run in the app.

@main
struct NotTennaPodWidgets: WidgetBundle {
    var body: some Widget {
        PlayerHomeWidget()
        PlayerControl()
    }
}

/// "Widget settings" (`WidgetConfigActivity`), in Android's order and with its defaults.
struct PlayerWidgetConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "widget_settings"
    @Parameter(title: "widget_opacity", default: 100, controlStyle: .slider, inclusiveRange: (0, 100))
    var opacity: Double
    @Parameter(title: "playback_speed", default: false) var playbackSpeed: Bool
    @Parameter(title: "rewind_label", default: false) var rewind: Bool
    @Parameter(title: "fast_forward_label", default: false) var fastForward: Bool
    @Parameter(title: "skip_episode_label", default: false) var skip: Bool
    @Parameter(title: "cover_as_background", default: false) var coverAsBackground: Bool

    init() {}

    /// Android's order. iOS cannot grey out a row (`WidgetConfigActivity.java:131-137`); with a conditional summary
    /// the Simulator's settings sheet dropped the last row, so Opacity stays visible and, as on Android, the
    /// background is opaque while Cover as background is on (`PlayerWidgetConfiguration.backgroundAlpha`).
    static var parameterSummary: some ParameterSummary {
        Summary {
            \.$opacity
            \.$playbackSpeed
            \.$rewind
            \.$fastForward
            \.$skip
            \.$coverAsBackground
        }
    }

    var settings: PlayerWidgetConfiguration {
        .init(opacity: opacity, playbackSpeed: playbackSpeed, rewind: rewind, fastForward: fastForward, skip: skip,
              coverAsBackground: coverAsBackground)
    }
}

struct PlayerWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: PlayerWidgetSnapshot?
    let cover: UIImage?
    let settings: PlayerWidgetConfiguration
    let isPreview: Bool
}

struct PlayerWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PlayerWidgetEntry {
        .init(date: Date(), snapshot: nil, cover: nil, settings: .init(), isPreview: true)
    }

    func snapshot(for configuration: PlayerWidgetConfigurationIntent, in context: Context) async -> PlayerWidgetEntry {
        if context.isPreview {
            return .init(date: Date(), snapshot: nil, cover: nil, settings: configuration.settings, isPreview: true)
        }
        let (snapshot, cover) = Self.current()
        let now = Date()
        return .init(date: now, snapshot: snapshot?.shown(at: now), cover: cover, settings: configuration.settings, isPreview: false)
    }

    /// While the snapshot's playing lease holds, the time runs each second and the last entry, at the lease's end,
    /// shows the episode paused; WidgetKit then asks again (`PlayerWidgetLease`, also for its limits).
    func timeline(for configuration: PlayerWidgetConfigurationIntent, in context: Context) async -> Timeline<PlayerWidgetEntry> {
        let (snapshot, cover) = Self.current()
        let schedule = PlayerWidgetTimeline.schedule(for: snapshot, now: Date())
        let entries = schedule.entries.map {
            PlayerWidgetEntry(date: $0.date, snapshot: $0.snapshot, cover: cover, settings: configuration.settings, isPreview: false)
        }
        return Timeline(entries: entries, policy: schedule.refresh.map { .after($0) } ?? .never)
    }

    private static func current() -> (PlayerWidgetSnapshot?, UIImage?) {
        guard let store = PlayerWidgetStore.appGroup(), let snapshot = store.read() else { return (nil, nil) }
        return (snapshot, snapshot.cover.flatMap(store.cover(named:)).flatMap(UIImage.init(data:)))
    }
}

struct PlayerWidgetEntryView: View {
    let entry: PlayerWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let narrow = family == .systemSmall
        if entry.isPreview {
            PlayerWidgetView(presentation: .preview(configuration: entry.settings, narrow: narrow), cover: nil, interactive: false)
        } else {
            PlayerWidgetView(presentation: .init(snapshot: entry.snapshot, configuration: entry.settings, date: entry.date,
                                                 narrow: narrow, hasCover: entry.cover != nil),
                             cover: entry.cover)
        }
    }
}

/// The player widget: wide (`systemMedium`) and narrow (`systemSmall`) layouts, settings on add.
struct PlayerHomeWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: PlayerWidget.kind, intent: PlayerWidgetConfigurationIntent.self,
                               provider: PlayerWidgetProvider()) { entry in
            PlayerWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("NotTennaPod")
        .supportedFamilies([.systemMedium, .systemSmall])
        .contentMarginsDisabled()
        .promptsForUserConfiguration()
    }
}

/// The Control Center control: on while playing; a tap plays or pauses.
struct PlayerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: PlayerWidget.controlKind, provider: PlayerControlProvider()) { isPlaying in
            ControlWidgetToggle(isOn: isPlaying, action: PlayerControlToggleIntent()) {
                Label("NotTennaPod", systemImage: "antenna.radiowaves.left.and.right")
            }
        }
        .displayName("NotTennaPod")
    }
}

struct PlayerControlProvider: ControlValueProvider {
    var previewValue: Bool { false }
    /// Read again each time the system asks: on only while the snapshot's playing lease holds.
    func currentValue() async throws -> Bool { PlayerWidgetStore.appGroup()?.controlValue(at: Date()) ?? false }
}
