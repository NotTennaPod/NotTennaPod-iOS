import SwiftUI
import WidgetKit
#if !WIDGET_EXTENSION
import NotTennaPodCore
#endif

/// Semantic input for controlled component renders. Nil on the shipped face reads WidgetKit's actual public
/// environment; supplying this value does not simulate the OS's tint, glass, or background-removal pipeline.
struct PlayerWidgetRenderingContext {
    let mode: WidgetRenderingMode
    let showsContainerBackground: Bool
    let colorScheme: ColorScheme
}

/// The player widget's face, `player_widget.xml`: cover, title, progress and the buttons on
/// AntennaPod's dark background. Compiled into the widget extension and the app (whose view tests render it).
struct PlayerWidgetView: View {
    let presentation: PlayerWidgetPresentation
    /// The episode's cover; nil shows the launcher icon (`R.mipmap.ic_launcher`).
    let cover: UIImage?
    /// The bundle holding the widget's icons, fonts and strings (the widget extension).
    var resources: Bundle = .main
    /// Whether controls can be App Intent buttons; false for the image-only previews.
    var interactive = true
    /// A component-test input only; the app and extension leave this nil to observe the public environment.
    var renderingContext: PlayerWidgetRenderingContext? = nil

    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.showsWidgetContainerBackground) private var showsContainerBackground
    @Environment(\.colorScheme) private var colorScheme

    private static let background = Color(red: Double((PlayerWidget.backgroundRGB >> 16) & 0xff) / 255,
                                          green: Double((PlayerWidget.backgroundRGB >> 8) & 0xff) / 255,
                                          blue: Double(PlayerWidget.backgroundRGB & 0xff) / 255)

    var body: some View {
        HStack(spacing: 0) {
            // `layout_left`: cover and centre; a tap anywhere outside the buttons opens the player (widgetURL).
            HStack(spacing: 12) {
                if presentation.showsCover {
                    coverView.frame(width: 48, height: 48).accessibilityHidden(true).playerWidgetElement("playerWidgetCover")
                }
                if presentation.showsText { center }
            }
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            if presentation.showsStandalonePlay {
                // `butPlay`: 48 wide, 12 margin, 8 padding, full height.
                control(.playPause, iconSize: 32)
                    .frame(width: 48)
                    .frame(maxHeight: .infinity)
                    .padding(12)
            }
        }
        .coordinateSpace(.named(PlayerWidgetLayout.space))
        .containerBackground(for: .widget) { backgroundView }
        .widgetURL(PlayerWidgetLink.player)
    }

    /// `layout_center`: title or "No media playing", progress, the extended row.
    private var center: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = presentation.title {
                Text(title)
                    .font(.custom("Roboto-Bold", size: 16, relativeTo: .body))
                    .lineLimit(1).truncationMode(.tail)
                    .playerWidgetElement("playerWidgetTitle")
            } else {
                Text(text("no_media_playing_label"))
                    .font(.custom("Roboto-Bold", size: 16, relativeTo: .body))
                    .lineLimit(3)
                    .playerWidgetElement("playerWidgetNoMedia")
            }
            if let progress = presentation.progress {
                Text(progress)
                    .font(.custom("Roboto-Regular", size: 14, relativeTo: .subheadline))
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.top, 4)
                    .playerWidgetElement("playerWidgetProgress")
            }
            if !presentation.extendedControls.isEmpty {
                HStack(spacing: 2) {
                    ForEach(presentation.extendedControls, id: \.self) { item in
                        control(item, iconSize: 36).frame(maxWidth: .infinity).frame(height: 36)
                    }
                }
                .padding(.trailing, 2)
            }
        }
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var coverView: some View {
        if let cover {
            Image(uiImage: cover).resizable()
                // Media artwork must remain identifiable when WidgetKit tints the foreground.
                .widgetAccentedRenderingMode(.fullColor)
                .scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            launcherIcon
        }
    }

    /// The adaptive launcher icon: both layers 1.5 × the visible circle, like the app's `AdaptiveLogoView`.
    private var launcherIcon: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Image(Self.logo + "-background", bundle: resources).resizable()
                Image(Self.logo + "-foreground", bundle: resources).resizable()
            }
            .frame(width: side * 1.5, height: side * 1.5)
            .frame(width: side, height: side)
            .clipShape(Circle())
        }
    }

    private static var logo: String {
#if DEBUG
        "Logo-debug"
#else
        "Logo-main"
#endif
    }

    /// The actual card/60%-cover layers, also mounted over an explicit backing by component tests.
    /// Keeping the same view avoids substituting a policy swatch for the production cover composition.
    @ViewBuilder var backgroundView: some View {
        ZStack {
            Self.background.opacity(presentation.backgroundAlpha)
            if presentation.showsCoverBackground, let cover {
                // `imgvBackground`: the cover blurred, at 60 %, centre-cropped.
                Image(uiImage: cover).resizable().scaledToFill()
                    .blur(radius: 12)
                    .opacity(PlayerWidget.coverBackgroundAlpha)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private func control(_ item: PlayerWidgetPresentation.Control, iconSize: CGFloat) -> some View {
        let label = text(presentation.labelKey(for: item))
        let icon = Image(presentation.iconName(for: item), bundle: resources)
            .renderingMode(.template).resizable().scaledToFit()
            .frame(width: iconSize, height: iconSize)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        let identifier = "playerWidget-" + item.rawValue
        switch interactive ? presentation.action(for: item) : nil {
        case .open(let url)? where presentation.showsText:
            // A small widget has no links; there the widget's own tap opens the app.
            Link(destination: url) { icon }
                .accessibilityLabel(label).playerWidgetElement(identifier)
        case .command(let command)?:
            intentButton(command) { icon }
                .accessibilityLabel(label).playerWidgetElement(identifier)
        default:
            icon.accessibilityLabel(label).playerWidgetElement(identifier)
        }
    }

    @ViewBuilder private func intentButton(_ command: PlayerWidgetCommand, @ViewBuilder label: () -> some View) -> some View {
        switch command {
        case .play: Button(intent: PlayerWidgetPlayPauseIntent(play: true), label: label).buttonStyle(.plain)
        case .pause: Button(intent: PlayerWidgetPlayPauseIntent(play: false), label: label).buttonStyle(.plain)
        case .playPause: Button(intent: PlayerWidgetPlayPauseIntent(), label: label).buttonStyle(.plain)
        case .rewind: Button(intent: PlayerWidgetRewindIntent(), label: label).buttonStyle(.plain)
        case .fastForward: Button(intent: PlayerWidgetFastForwardIntent(), label: label).buttonStyle(.plain)
        case .skip: Button(intent: PlayerWidgetSkipIntent(), label: label).buttonStyle(.plain)
        }
    }

    private func text(_ key: String) -> String {
        resources.localizedString(forKey: key, value: nil, table: nil)
    }

    private var context: PlayerWidgetRenderingContext {
        renderingContext ?? .init(mode: renderingMode, showsContainerBackground: showsContainerBackground, colorScheme: colorScheme)
    }

    /// Android draws white glyphs and lets the wallpaper show through a see-through card. iOS shows its own
    /// backing instead (white in the light appearance), so white glyphs would vanish on a mostly clear card.
    /// #262C31 over white gives black and white glyphs equal contrast near 65 %; switch at 70 % to allow for the
    /// slightly lighter card iOS renders. Removed backgrounds and accented/vibrant modes use the system's
    /// foreground treatment.
    private var foreground: Color {
        let context = context
        guard context.mode == .fullColor, context.showsContainerBackground else { return .primary }
        return context.colorScheme == .light && presentation.backgroundAlpha < 0.7 ? .black : .white
    }
}

/// Where each part of the widget was laid out, by accessibility identifier, in the widget's coordinates; the view
/// tests read it to check placement at real widget sizes.
struct PlayerWidgetLayout: PreferenceKey {
    static let space = "playerWidget"
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func playerWidgetElement(_ identifier: String) -> some View {
        accessibilityIdentifier(identifier).background(GeometryReader { proxy in
            Color.clear.preference(key: PlayerWidgetLayout.self, value: [identifier: proxy.frame(in: .named(PlayerWidgetLayout.space))])
        })
    }
}
