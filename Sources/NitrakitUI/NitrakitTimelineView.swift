#if canImport(Nitrakit)
import Nitrakit
#endif
import QuartzCore

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Something the editor needs from the app: media to add, a font, a colour, text…
public struct EditorRequest {
    public let kind: RequestType
    /// The selected clip, "" if none.
    public let clip: String
    /// The property the request is for (colours), "" if none.
    public let property: String
}

/// The editor dock: transport row, timeline, bottom bar and attribute panels, drawn by the
/// engine on its own thread. Callbacks arrive on the main thread.
public final class NitrakitTimelineView: PlatformView {
    public private(set) var timeline: Timeline?
    /// Selected clip id ("" = none).
    public var onSelected: ((String) -> Void)?
    /// Your pickers: return the answer, `.cancel` if the user cancelled, or `nil` for the
    /// built-in picker.
    public var onRequest: (@MainActor (EditorRequest) async -> RequestResponse?)?
    public var onCustomItem: ((String) -> Void)?
    public var onFullscreen: (() -> Void)?
    public var onError: ((Error) -> Void)?

    public var editor: Editor? {
        didSet {
            timeline = nil
            open()
        }
    }

    /// The editor's look. Unset fields keep the default.
    public var theme: EditorTheme? {
        didSet { setThemeJSON(theme.map(json)) }
    }

    /// The fonts the font panel offers, in order. Empty: the generic families, then the fonts
    /// you registered with `registerFont`.
    public var fonts: [String] = [] {
        didSet { timeline?.setFonts(families: fonts) }
    }

    /// Your sticker packs: adding a sticker opens a browser of them (packs as tabs). Without
    /// packs, adding a sticker is a request to your app.
    public var stickerPacks: [StickerPack] = [] {
        didSet { setStickerPacksJSON(json(stickerPacks)) }
    }

    private var stickerPacksJSON: String?

    /// JSON form of the matching property, for cross-platform wrappers (React Native).
    @_spi(Wrappers) public func setStickerPacksJSON(_ value: String) {
        stickerPacksJSON = value
        do { try timeline?.setStickerPacks(json: value) } catch { onError?(error) }
    }

    fileprivate func stickerThumbs(_ ids: [String]) {
        guard let t = timeline else { return }
        for id in ids {
            Task.detached {
                guard let file = try? await MediaFiles.fetch(id) else { return }
                try? t.setStickerFile(id: id, path: file.path)
            }
        }
    }

    fileprivate func stickerChosen(_ id: String) {
        guard let t = timeline, let editor else { return }
        Task { @MainActor in
            do {
                let file = try await MediaFiles.fetch(id)
                let packs = (try? JSONDecoder().decode([StickerPack].self, from: Data((self.stickerPacksJSON ?? "[]").utf8))) ?? []
                let name = packs.first { $0.stickers.contains(id) }?.name ?? "Sticker"
                let media = try editor.addMedia(id: id, file: file, name: name)
                try t.insertSticker(source: media.source)
            } catch {
                self.onError?(error)
            }
        }
    }

    private var themeJSON: String?
    private var hiddenItems: [String] = []
    /// Your tools as (id, JSON), in the order added.
    private var items: [(String, String)] = []
    private var icons: [String: String] = [:]

    /// JSON form of the matching property, for cross-platform wrappers (React Native).
    @_spi(Wrappers) public func setThemeJSON(_ value: String?) {
        themeJSON = value
        do { try timeline?.setTheme(json: value ?? "{}") } catch { onError?(error) }
    }

    /// Replaces all of your tools (id, JSON).
    /// JSON form of the matching property, for cross-platform wrappers (React Native).
    @_spi(Wrappers) public func setMenuItemsJSON(_ all: [(String, String)]) {
        for (id, _) in items { removeMenuItem(id: id) }
        for (id, j) in all { addMenuItemJSON(id, j) }
    }

    private func addMenuItemJSON(_ id: String, _ j: String) {
        items.removeAll { $0.0 == id }
        items.append((id, j))
        do { try timeline?.addMenuItem(json: j) } catch { onError?(error) }
    }

    /// Removes built-in tools by id (e.g. "sticker", "mask") from every menu.
    public func hideMenuItems(_ ids: [String]) {
        hiddenItems = ids
        timeline?.hideMenuItems(ids: ids)
    }

    /// Adds one of your own tools to a bar; replaces one with the same id.
    public func addMenuItem(_ item: EditorMenuItem) {
        addMenuItemJSON(item.id, json(item))
    }

    public func removeMenuItem(id: String) {
        items.removeAll { $0.0 == id }
        timeline?.removeMenuItem(id: id)
    }

    /// For your back gesture or button: closes an open panel or leaves the selection and returns
    /// true; false when there's nothing to step back from, so navigate back.
    public func handleBack() -> Bool {
        timeline?.handleBack() ?? false
    }

    /// Replaces a built-in icon (`iconNames()`), or adds one for your own tools, with an SVG.
    public func setIcon(_ name: String, svg: String) {
        icons[name] = svg
        timeline?.setIcon(name: name, svg: svg)
    }

    /// Everything set so far, on a newly opened timeline.
    private func applyCustomization(_ t: Timeline) {
        if let themeJSON { try? t.setTheme(json: themeJSON) }
        if let stickerPacksJSON { try? t.setStickerPacks(json: stickerPacksJSON) }
        if !fonts.isEmpty { t.setFonts(families: fonts) }
        for (name, svg) in icons { t.setIcon(name: name, svg: svg) }
        if !hiddenItems.isEmpty { t.hideMenuItems(ids: hiddenItems) }
        for (_, j) in items { try? t.addMenuItem(json: j) }
    }

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    #if os(macOS)
    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    public override func makeBackingLayer() -> CALayer { CAMetalLayer() }

    public override func layout() {
        super.layout()
        sizeChanged()
    }

    public override var isFlipped: Bool { true }
    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }
    #else
    public override class var layerClass: AnyClass { CAMetalLayer.self }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        sizeChanged()
    }

    private var scale: CGFloat { window?.screen.scale ?? UIScreen.main.scale }
    #endif

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var lastSize: CGSize = .zero

    private func sizeChanged() {
        metalLayer.contentsScale = scale
        guard bounds.width > 0, bounds.height > 0 else { return }
        if timeline == nil {
            open()
        } else if bounds.size != lastSize {
            lastSize = bounds.size
            timeline?.resize(width: Float(bounds.width), height: Float(bounds.height), scale: Float(scale))
        }
    }

    private func open() {
        guard let editor, timeline == nil, bounds.width > 0, bounds.height > 0 else { return }
        metalLayer.contentsScale = scale
        lastSize = bounds.size
        let ptr = UInt64(UInt(bitPattern: Unmanaged.passUnretained(metalLayer).toOpaque()))
        do {
            let t = try editor.createTimeline(view: ptr, width: Float(bounds.width), height: Float(bounds.height), scale: Float(scale))
            t.setListener(listener: TimelineRelay(self))
            applyCustomization(t)
            timeline = t
            NitrakitLicense.refresh()
        } catch {
            onError?(error)
        }
    }

    fileprivate func request(_ id: UInt64, _ kind: RequestType, _ clip: String, _ property: String) {
        guard let handler = onRequest, let asked = timeline else { return defaultPicker(id, kind) }
        Task { @MainActor [weak self] in
            let answer = await handler(EditorRequest(kind: kind, clip: clip, property: property))
            // A timeline replaced meanwhile (new editor) no longer waits for this answer.
            guard let self, let t = self.timeline, t === asked else { return }
            if let answer { t.respond(request: id, response: answer) } else { self.defaultPicker(id, kind) }
        }
    }

    /// Built-in pickers, for requests the app leaves to the SDK.
    private func defaultPicker(_ id: UInt64, _ kind: RequestType) {
        guard let t = timeline else { return }
        #if os(iOS)
        guard let host = window?.rootViewController.map(topmost) else {
            t.respond(request: id, response: .cancel)
            return
        }
        func choose(_ title: String, _ labels: [String], _ pick: @escaping (Int) -> RequestResponse) {
            let a = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
            for (i, l) in labels.enumerated() {
                a.addAction(UIAlertAction(title: l, style: .default) { _ in t.respond(request: id, response: pick(i)) })
            }
            a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in t.respond(request: id, response: .cancel) })
            a.popoverPresentationController?.sourceView = self
            host.present(a, animated: true)
        }
        switch kind {
        case .chooseFont:
            let fonts = ["sans-serif", "serif", "monospace"] + fontFamilies()
            choose("Font", fonts) { .text(value: fonts[$0]) }
        case .chooseColor:
            let named: [(String, (Float, Float, Float))] = [("White", (1, 1, 1)), ("Black", (0, 0, 0)), ("Yellow", (1, 0.76, 0)), ("Red", (1, 0.23, 0.19)),
                                                            ("Pink", (1, 0.18, 0.57)), ("Purple", (0.35, 0.34, 0.84)), ("Blue", (0.04, 0.52, 1)), ("Green", (0.2, 0.78, 0.35))]
            choose("Color", named.map(\.0)) { let c = named[$0].1; return .color(r: c.0, g: c.1, b: c.2, a: 1) }
        case .editText:
            let a = UIAlertController(title: "Text", message: nil, preferredStyle: .alert)
            a.addTextField()
            a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in t.respond(request: id, response: .cancel) })
            a.addAction(UIAlertAction(title: "OK", style: .default) { _ in t.respond(request: id, response: .text(value: a.textFields?.first?.text ?? "")) })
            host.present(a, animated: true)
        case .chooseTextStyle:
            let styles = editor?.textStylePresets() ?? []
            choose("Style", styles.map(\.name)) { .stylePreset(id: styles[$0].id) }
        case .chooseFilter:
            let effects = (editor?.effectCatalog() ?? []).filter { $0.kind == "effect" && $0.bundle }
            choose("Filter", effects.map(\.label)) { .effect(id: effects[$0].id) }
        default:
            t.respond(request: id, response: .cancel)
        }
        #else
        t.respond(request: id, response: .cancel)
        #endif
    }

    #if os(iOS)
    private func topmost(_ vc: UIViewController) -> UIViewController {
        vc.presentedViewController.map(topmost) ?? vc
    }

    private func send(_ phase: PointerPhase, _ touches: Set<UITouch>) {
        guard let t = timeline else { return }
        for touch in touches {
            let p = touch.location(in: self)
            t.pointer(phase: phase, id: UInt64(UInt(bitPattern: ObjectIdentifier(touch).hashValue)), x: Float(p.x), y: Float(p.y), timeMs: touch.timestamp * 1000)
        }
    }

    public override func touchesBegan(_ t: Set<UITouch>, with e: UIEvent?) {
        // Every finger on the view just landed: a new sequence.
        if (e?.touches(for: self) ?? t).allSatisfy({ $0.phase == .began }) { timeline?.touchStart() }
        send(.down, t)
    }
    public override func touchesMoved(_ t: Set<UITouch>, with e: UIEvent?) {
        // Coalesced samples keep fling velocity accurate.
        guard let tl = timeline else { return }
        for touch in t {
            let id = UInt64(UInt(bitPattern: ObjectIdentifier(touch).hashValue))
            for c in e?.coalescedTouches(for: touch) ?? [touch] {
                let p = c.location(in: self)
                tl.pointer(phase: .move, id: id, x: Float(p.x), y: Float(p.y), timeMs: c.timestamp * 1000)
            }
        }
    }
    public override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent?) { send(.up, t) }
    public override func touchesCancelled(_ t: Set<UITouch>, with e: UIEvent?) { send(.cancel, t) }

    fileprivate func haptic(_ kind: HapticKind) {
        switch kind {
        case .select, .snap: UISelectionFeedbackGenerator().selectionChanged()
        case .lift: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .drop: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .refused: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        @unknown default: break
        }
    }
    #else
    private func local(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }
    private func mouse(_ phase: PointerPhase, _ e: NSEvent) {
        let p = local(e)
        timeline?.pointer(phase: phase, id: 0, x: Float(p.x), y: Float(p.y), timeMs: e.timestamp * 1000)
    }
    public override func mouseDown(with e: NSEvent) { mouse(.down, e) }
    public override func mouseDragged(with e: NSEvent) { mouse(.move, e) }
    public override func mouseUp(with e: NSEvent) { mouse(.up, e) }
    public override func scrollWheel(with e: NSEvent) {
        timeline?.scroll(dx: Float(-e.scrollingDeltaX), dy: Float(-e.scrollingDeltaY))
        if e.phase == .ended || e.momentumPhase == .ended { timeline?.scrollEnded() }
    }

    fileprivate func haptic(_ kind: HapticKind) {}
    #endif
}

private final class TimelineRelay: TimelineListener {
    weak var view: NitrakitTimelineView?

    init(_ view: NitrakitTimelineView) { self.view = view }

    func selected(clip: String) {
        DispatchQueue.main.async { [weak view] in view?.onSelected?(clip) }
    }

    func haptic(kind: HapticKind) {
        DispatchQueue.main.async { [weak view] in view?.haptic(kind) }
    }

    func request(id: UInt64, kind: RequestType, clip: String, property: String) {
        DispatchQueue.main.async { [weak view] in view?.request(id, kind, clip, property) }
    }

    func stickerThumbsNeeded(ids: [String]) {
        DispatchQueue.main.async { [weak view] in view?.stickerThumbs(ids) }
    }

    func stickerChosen(id: String) {
        DispatchQueue.main.async { [weak view] in view?.stickerChosen(id) }
    }

    func customItem(id: String) {
        DispatchQueue.main.async { [weak view] in view?.onCustomItem?(id) }
    }

    func fullscreen() {
        DispatchQueue.main.async { [weak view] in view?.onFullscreen?() }
    }

    func accessibilityChanged() {
        DispatchQueue.main.async { [weak view] in view?.accessibilityChanged() }
    }
}

#if os(iOS)
/// A control the timeline draws, for VoiceOver and UI automation.
private final class TimelineElement: UIAccessibilityElement {
    let index: Int
    weak var view: NitrakitTimelineView?

    init(_ view: NitrakitTimelineView, _ index: Int, _ node: AccessibilityNode) {
        self.index = index
        self.view = view
        super.init(accessibilityContainer: view)
        accessibilityFrameInContainerSpace = CGRect(
            x: CGFloat(node.x), y: CGFloat(node.y), width: CGFloat(node.width), height: CGFloat(node.height))
        accessibilityLabel = node.label
        accessibilityValue = node.value.isEmpty ? nil : node.value
        var traits: UIAccessibilityTraits = []
        switch node.role {
        case .button, .item, .tab, .slider, .toggle: traits.insert(.button)
        case .image: traits.insert(.image)
        case .text: traits.insert(.staticText)
        }
        if node.selected { traits.insert(.selected) }
        if !node.enabled { traits.insert(.notEnabled) }
        accessibilityTraits = traits
    }

    override func accessibilityActivate() -> Bool {
        view?.timeline?.accessibilityActivate(index: UInt32(index))
        return true
    }
}

extension NitrakitTimelineView {
    fileprivate func accessibilityChanged() {
        guard let t = timeline else { return }
        let elements = t.accessibilityNodes().enumerated().map { TimelineElement(self, $0.offset, $0.element) }
        accessibilityElements = elements
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
        }
    }
}
#else
extension NitrakitTimelineView {
    fileprivate func accessibilityChanged() {}
}
#endif
