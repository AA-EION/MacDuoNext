import AppKit
import MacDuoNextCore
import MacDuoNextEngine
import Metal
import QuartzCore

/// A borderless window above everything, including the menu bar and full
/// screen spaces. It never takes focus and never takes clicks.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The settings that shape one frame.
struct DepthTuning {
    var viewingDistance: Double = 2.7
    var recession: Double = 2
    var blurEvenness: Double = 0.4
    var dimReach: Double = 0.7
    var maxBlurRadius: Double = 55
    var maxDim: Double = 0.4
    /// 0 draws no glass at all.
    var glass: Double = 1
    /// How rough the pane gets with the lid fully closed, 0...1.
    var frost: Double = 0.75
}

private final class MetalHostView: NSView {
    init(layer metalLayer: CALayer, scale: CGFloat) {
        super.init(frame: .zero)
        metalLayer.contentsScale = scale
        self.layer = metalLayer
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        layer?.frame = bounds
    }
}

/// Owns the overlay window for one run of the effect, and hands each frame of
/// the room to the glass engine.
@MainActor
final class GlassOverlay {

    private var window: OverlayWindow?
    /// The window of the previous run while it fades out. AppKit keeps it
    /// alive past the fade, so a new run has to take it down itself.
    private var fadingWindow: OverlayWindow?
    private var presenceWindow: OverlayWindow?
    /// Built once and kept.
    private var renderer: GlassRenderer?
    private var hasTriedToBuildRenderer = false
    private var buildToken = 0
    private let buildQueue = DispatchQueue(label: "com.macduonext.pictureUpload", qos: .userInteractive)

    private var screenSize: CGSize = .zero
    private var startAngle: Double = 90
    private var geometry = LidGeometry(screenSize: Size2(width: 1, height: 1), pointsPerMillimetre: 5)
    private var gradient = BlurGradient()
    private var tuning = DepthTuning()
    private var fadeIn: TimeInterval = 0.07
    private var hasRevealed = false
    /// The last frame drawn, so a frame that would look the same is skipped.
    private var lastFrame: GlassFrame?

    var isVisible: Bool { window != nil }
    var isPictureReady: Bool { renderer?.isReady ?? false }
    var hostWindow: NSWindow? { window }
    /// The layer the current window draws into, for the display link.
    var metalLayer: CAMetalLayer? { window == nil ? nil : renderer?.layer }
    /// The room for the current run.
    var roomGeometry: LidGeometry { geometry }
    var renderPath: String { renderer?.pathDescription ?? "unavailable" }

    @discardableResult
    func warmUp() -> Bool {
        if !hasTriedToBuildRenderer {
            hasTriedToBuildRenderer = true
            renderer = GlassRenderer()
        }
        keepPresence()
        return renderer != nil
    }

    /// A window one point across that shows nothing.
    ///
    /// ScreenCaptureKit only lists an application that owns a window, and the
    /// stream has to name this application to leave the overlay out of its own
    /// picture.
    private func keepPresence() {
        guard presenceWindow == nil else { return }
        let window = OverlayWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.alphaValue = 0.004
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.orderFrontRegardless()
        presenceWindow = window
    }

    /// Puts up a window for a live stream. It stays transparent until the
    /// first frame is absorbed.
    @discardableResult
    func showLive(
        on screen: NSScreen,
        startAngle: Double,
        tuning: DepthTuning,
        fadeIn: TimeInterval
    ) -> Bool {
        dismiss(animated: false)
        guard warmUp(), let renderer else { return false }
        self.startAngle = startAngle
        self.tuning = tuning
        self.fadeIn = fadeIn
        screenSize = screen.frame.size
        prepareRoom(on: screen)

        let pixelScale = Double(screen.backingScaleFactor)
        guard renderer.beginLive(screenSize: screenSize, pixelScale: CGFloat(pixelScale)) else { return false }
        buildToken += 1
        makeWindow(on: screen, pixelScale: pixelScale)
        return window != nil
    }

    /// Hands one live frame to the renderer and reveals the window once the
    /// first one has landed.
    func absorb(_ frame: CapturedFrame) {
        guard window != nil, let renderer else { return }
        renderer.absorb(frame)
        reveal()
    }

    /// Starts a live overlay from one held frame.
    func seed(image: CGImage) {
        guard window != nil, let renderer, renderer.seed(image: image) else { return }
        reveal()
    }

    func discardLive() {
        renderer?.discardLive()
    }


    func show(
        image: CGImage,
        on screen: NSScreen,
        startAngle: Double,
        tuning: DepthTuning,
        fadeIn: TimeInterval
    ) {
        dismiss(animated: false)
        // The screenshot's screen can be stale once the lid shuts into
        // clamshell mode, so no window goes up at its old frame.
        guard let displayID = screen.displayID, displayID == NSScreen.builtIn?.displayID else { return }
        guard warmUp(), let renderer else { return }
        self.startAngle = startAngle
        self.tuning = tuning
        self.fadeIn = fadeIn
        screenSize = screen.frame.size
        prepareRoom(on: screen)

        let pixelScale = screen.frame.width > 0
            ? Double(image.width) / Double(screen.frame.width)
            : Double(screen.backingScaleFactor)

        makeWindow(on: screen, pixelScale: pixelScale)
        guard let window else { return }

        buildToken += 1
        let token = buildToken
        let size = screenSize
        buildQueue.async { [weak self, weak renderer] in
            guard let renderer else { return }
            let picture = renderer.makePicture(image: image, screenSize: size, pixelScale: CGFloat(pixelScale))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.buildToken == token, self.window === window,
                          let picture else { return }
                    renderer.adopt(picture)
                    self.update(
                        progress: 0,
                        currentAngle: self.startAngle,
                        eye: self.geometry.centredEye(
                            startAngle: self.startAngle,
                            viewingDistance: self.tuning.viewingDistance
                        ),
                        tuning: self.tuning
                    )
                    self.reveal()
                }
            }
        }
    }

    private func makeWindow(on screen: NSScreen, pixelScale: Double) {
        guard let renderer else { return }
        let view = MetalHostView(layer: renderer.makeLayer(), scale: CGFloat(pixelScale))
        view.frame = NSRect(origin: .zero, size: screenSize)
        view.autoresizingMask = [.width, .height]

        let window = OverlayWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.setFrame(screen.frame, display: false)
        window.alphaValue = 0
        window.orderFrontRegardless()
        hasRevealed = false
        lastFrame = nil
        self.window = window
    }

    /// Fades the window in once, and only once the picture has something to
    /// draw.
    private func reveal() {
        guard let window, !hasRevealed, renderer?.isReady == true else { return }
        hasRevealed = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeIn
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    /// Measures the screen and builds the glass to match it.
    private func prepareRoom(on screen: NSScreen) {
        geometry = screen.lidGeometry
        renderer?.prepareGlass(GlassSlabMesh.Shape.macBook(
            pictureSize: geometry.screenSize,
            pointsPerMillimetre: geometry.pointsPerMillimetre
        ))
    }

    /// Draws the room with the lid at `currentAngle` and the eye at `eye`.
    func update(
        progress: Double,
        currentAngle: Double,
        eye: Vector3,
        tuning: DepthTuning,
        drawable: CAMetalDrawable? = nil
    ) {
        guard let renderer, renderer.isReady else { return }
        self.tuning = tuning
        let pictureAngle = geometry.pictureAngle(
            startAngle: startAngle,
            currentAngle: currentAngle,
            recession: tuning.recession
        )
        // The glass comes in over the first part of the close, so the frame
        // that fades in is the flat screen itself and the frame that fades
        // out is again.
        let glassAmount = Self.smoothstep(progress / Self.glassRampProgress)
        // The frost builds over more of the close than the glass does, so
        // the pane turns from clear to rough as the lid comes down.
        let frost = tuning.glass > 0 ? tuning.frost * Self.smoothstep(progress / Self.frostRampProgress) : 0
        // Eye positions are rounded to a hundredth of a point, so a spring
        // creeping towards rest does not keep the GPU busy.
        let roundedEye = (eye * 100).rounded(.toNearestOrEven) / 100
        let frame = GlassFrame(
            lid: geometry.lidFrame(angle: currentAngle),
            picture: geometry.lidFrame(angle: pictureAngle),
            eye: roundedEye,
            glassAmount: glassAmount * min(max(tuning.glass, 0), 1),
            environmentStrength: tuning.glass,
            frost: frost,
            blurStrength: gradient.blurStrength(progress: progress),
            dimStrength: gradient.dimStrength(progress: progress),
            blurFloor: tuning.blurEvenness,
            dimFloor: gradient.dimHingeFloor,
            dimReach: tuning.dimReach,
            maxBlurRadius: tuning.maxBlurRadius,
            maxDim: tuning.maxDim
        )
        guard frame != lastFrame || renderer.hasPendingPicture || !hasRevealed else { return }
        lastFrame = frame
        renderer.render(frame, drawable: drawable)
    }

    /// Progress at which the glass is fully in.
    private static let glassRampProgress: Double = 0.35
    /// Progress at which the frost is fully rough.
    private static let frostRampProgress: Double = 0.7

    private static func smoothstep(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    func dismiss(animated: Bool, duration: TimeInterval = 0.22) {
        closeFadingWindow()
        guard let window else { return }
        self.window = nil
        buildToken += 1
        renderer?.release()

        guard animated else {
            window.orderOut(nil)
            window.close()
            return
        }

        fadingWindow = window
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if let self, self.fadingWindow === window { self.fadingWindow = nil }
                window.orderOut(nil)
                window.close()
            }
        }
    }

    /// Takes down a window that is still fading.
    private func closeFadingWindow() {
        guard let fadingWindow else { return }
        self.fadingWindow = nil
        fadingWindow.orderOut(nil)
        fadingWindow.close()
    }
}
