#if canImport(Nitrakit)
import Nitrakit
#endif
import QuartzCore

#if os(macOS)
import AppKit
public typealias PlatformView = NSView
#else
import UIKit
public typealias PlatformView = UIView
#endif

/// Shows an editor's project. Owns the `Player`; position and state callbacks arrive on the main thread.
public final class NitrakitPreviewView: PlatformView {
    public private(set) var player: Player?
    /// Debug: a panel of playback numbers (fps, frame times, decoders, audio) over the preview.
    public var debugStats = false {
        didSet { player?.setDebugStats(on: debugStats, scale: Float(metalLayer.contentsScale)) }
    }
    public var onPosition: ((Int64) -> Void)?
    public var onPlaying: ((Bool) -> Void)?

    /// The project to preview; it starts once the view has a size.
    /// Writes the frame shown as an image (JPEG, or PNG for a `.png` path), longer side at most
    /// `maxSide` px: e.g. a cover for your project list. Blocks until the frame is ready.
    public func snapshot(to path: String, maxSide: Int = 720) throws {
        guard let player else { throw EditorError.media(message: "the preview isn't showing") }
        try player.snapshot(path: path, maxSide: UInt32(maxSide))
    }

    public var editor: Editor? {
        didSet {
            player = nil
            if editor != nil, bounds.width > 0, bounds.height > 0 { try? attach(editor!) }
        }
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

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2
        sizeChanged()
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }
    #else
    public override class var layerClass: AnyClass { CAMetalLayer.self }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        metalLayer.contentsScale = scale
        sizeChanged()
    }

    private var scale: CGFloat { window?.screen.scale ?? UIScreen.main.scale }

    /// Off screen: nothing should keep playing.
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { player?.pause() }
    }
    #endif

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var pixelSize: (UInt32, UInt32) {
        (UInt32(max(1, (bounds.width * scale).rounded())), UInt32(max(1, (bounds.height * scale).rounded())))
    }

    private var lastSize: (UInt32, UInt32) = (0, 0)

    private func sizeChanged() {
        let s = pixelSize
        if player == nil, let editor, bounds.width > 0, bounds.height > 0 {
            try? attach(editor)
            return
        }
        guard let player, s != lastSize else { return }
        lastSize = s
        player.resize(width: s.0, height: s.1)
    }

    /// Starts previewing `editor`; it follows the editor's edits from then on.
    public func attach(_ editor: Editor) throws {
        player = nil
        metalLayer.contentsScale = scale
        let s = pixelSize
        lastSize = s
        let ptr = UInt64(UInt(bitPattern: Unmanaged.passUnretained(metalLayer).toOpaque()))
        let p = try editor.createPlayer(view: ptr, width: s.0, height: s.1)
        p.setListener(listener: Relay(self))
        p.enableCanvas(scale: Float(scale))
        if debugStats { p.setDebugStats(on: true, scale: Float(scale)) }
        player = p
    }

    public func detach() {
        player = nil
    }

    private func pointer(_ phase: PointerPhase, _ id: UInt64, _ p: CGPoint, _ time: TimeInterval) {
        player?.canvasPointer(phase: phase, id: id, x: Float(p.x), y: Float(p.y), timeMs: time * 1000)
    }

    #if os(macOS)
    public override var isFlipped: Bool { true }

    private func local(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }
    public override func mouseDown(with e: NSEvent) { pointer(.down, 0, local(e), e.timestamp) }
    public override func mouseDragged(with e: NSEvent) { pointer(.move, 0, local(e), e.timestamp) }
    public override func mouseUp(with e: NSEvent) { pointer(.up, 0, local(e), e.timestamp) }
    #else
    private func send(_ phase: PointerPhase, _ touches: Set<UITouch>) {
        for t in touches {
            pointer(phase, UInt64(UInt(bitPattern: ObjectIdentifier(t).hashValue)), t.location(in: self), t.timestamp)
        }
    }

    public override func touchesBegan(_ t: Set<UITouch>, with e: UIEvent?) {
        // Every finger on the view just landed: a new sequence.
        if (e?.touches(for: self) ?? t).allSatisfy({ $0.phase == .began }) { player?.canvasTouchStart() }
        send(.down, t)
    }
    public override func touchesMoved(_ t: Set<UITouch>, with e: UIEvent?) { send(.move, t) }
    public override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent?) { send(.up, t) }
    public override func touchesCancelled(_ t: Set<UITouch>, with e: UIEvent?) { send(.cancel, t) }
    #endif
}

private final class Relay: PlayerListener {
    weak var view: NitrakitPreviewView?

    init(_ view: NitrakitPreviewView) { self.view = view }

    func position(timeUs: Int64) {
        DispatchQueue.main.async { [weak view] in view?.onPosition?(timeUs) }
    }

    func playing(playing: Bool) {
        DispatchQueue.main.async { [weak view] in view?.onPlaying?(playing) }
    }
}
