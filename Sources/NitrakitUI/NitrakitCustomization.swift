import Foundation

/// The editor's look. Colours are `#rrggbb` or `#rrggbbaa`; every field is optional, and unset
/// ones keep the default.
public struct EditorTheme: Codable, Equatable, Sendable {
    public var background: String?
    /// The tool bar.
    public var bar: String?
    /// Panels a tool opens.
    public var panel: String?
    public var text: String?
    public var mutedText: String?
    /// Active tools, sliders, the playhead's snap and progress.
    public var accent: String?
    public var divider: String?
    /// A font family for the editor's labels (system or registered with `registerFont`).
    public var font: String?
    public var barHeight: Float?
    public var transportHeight: Float?
    public var timelineBackground: String?
    /// Lane backgrounds in the timeline.
    public var lane: String?
    /// The selected clip's outline and handles.
    public var selection: String?
    public var playhead: String?
    public var clips: ClipColors?

    public struct ClipColors: Codable, Equatable, Sendable {
        public var video, image, sticker, text, solid, audio, effects: String?
        public init(video: String? = nil, image: String? = nil, sticker: String? = nil, text: String? = nil,
                    solid: String? = nil, audio: String? = nil, effects: String? = nil) {
            (self.video, self.image, self.sticker, self.text, self.solid, self.audio, self.effects) =
                (video, image, sticker, text, solid, audio, effects)
        }
    }

    public init(background: String? = nil, bar: String? = nil, panel: String? = nil, text: String? = nil,
                mutedText: String? = nil, accent: String? = nil, divider: String? = nil, font: String? = nil,
                barHeight: Float? = nil, transportHeight: Float? = nil, timelineBackground: String? = nil,
                lane: String? = nil, selection: String? = nil, playhead: String? = nil, clips: ClipColors? = nil) {
        self.background = background
        self.bar = bar
        self.panel = panel
        self.text = text
        self.mutedText = mutedText
        self.accent = accent
        self.divider = divider
        self.font = font
        self.barHeight = barHeight
        self.transportHeight = transportHeight
        self.timelineBackground = timelineBackground
        self.lane = lane
        self.selection = selection
        self.playhead = playhead
        self.clips = clips
    }
}

/// One of your own tools in the editor's bar. A tap calls `onCustomItem` with its id.
public struct EditorMenuItem: Codable, Equatable, Sendable {
    public enum Menu: String, Codable, Sendable {
        /// Nothing selected.
        case root
        case video, image, sticker, text, audio, effects, solid
    }

    public var id: String
    public var label: String
    /// A built-in icon name (`iconNames()`), or one you set with `setIcon`.
    public var icon: String?
    /// The bar it appears in.
    public var menu: Menu
    /// Placed after this item; at the end when nil.
    public var after: String?

    public init(id: String, label: String, icon: String? = nil, menu: Menu, after: String? = nil) {
        self.id = id
        self.label = label
        self.icon = icon
        self.menu = menu
        self.after = after
    }
}

/// A pack of stickers in the editor's sticker browser (a tab). Stickers are media ids, fetched
/// through `NitrakitMedia.resolve` like any media.
public struct StickerPack: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var stickers: [String]
    /// The pack's tab image (a media id); its first sticker when nil.
    public var icon: String?
    public init(id: String, name: String, stickers: [String], icon: String? = nil) {
        self.id = id
        self.name = name
        self.stickers = stickers
        self.icon = icon
    }
}

func json<T: Encodable>(_ value: T) -> String {
    String(decoding: (try? JSONEncoder().encode(value)) ?? Data("{}".utf8), as: UTF8.self)
}
