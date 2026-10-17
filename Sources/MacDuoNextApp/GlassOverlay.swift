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
    /// Eye distance in screen heights, when no face is tracked.
    var viewingDistance: Double = 2.6
    /// Degrees the left-behind screen leans back per degree of closing. One
    /// leaves it exactly where it stood.
    var recession: Double = 1
    /// False: clear glass, no frost or light loss.
    var isGlassEnabled = true
    /// How strongly the glass scatters, 0...1.
    var frost: Double = 0.75
    /// How much light is lost behind the glass, 0...1.
    var lightLoss: Double = 0.6
    /// The most blur, in points.
    var maxBlurRadius: Double = 60
    /// Strength of the glass's reflection, 0...1.
    var reflections: Double = 0.6
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

    /// Measures the screen, so the room is to scale.
    private func prepareRoom(on screen: NSScreen) {
        geometry = screen.lidGeometry
    }

    /// Draws the room with the lid at `currentAngle` and the eye at `eye`.
    ///
    /// The captured screen is never altered: it stands, as it was, where the
    /// screen stood at the start angle. Everything that happens to it on the
    /// way to the eye is the glass of the real screen, which the renderer
    /// simulates from the distance between the two.
    func update(
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
        // The glass's own reflection and grain come in over the first
        // degrees of the close, so the frame that fades in, and the one that
        // fades out, is the screen itself.
        let amount = Self.smoothstep((startAngle - currentAngle) / Self.surfaceRampDegrees)
        let glass = tuning.isGlassEnabled
        let frost = glass ? min(max(tuning.frost, 0), 1) : 0
        // Eye positions are rounded to a hundredth of a point, so a spring
        // creeping towards rest does not keep the GPU busy.
        let roundedEye = (eye * 100).rounded(.toNearestOrEven) / 100
        let frame = GlassFrame(
            lid: geometry.lidFrame(angle: currentAngle),
            picture: geometry.lidFrame(angle: pictureAngle),
            eye: roundedEye,
            amount: amount,
            scatter: frost * Self.maxScatter,
            maxBlurRadius: tuning.maxBlurRadius,
            lightLoss: glass ? min(max(tuning.lightLoss, 0), 1) * Self.maxLightLoss : 0,
            haze: frost * Self.maxHaze,
            reflections: glass ? tuning.reflections : 0,
            grain: frost
        )
        guard frame != lastFrame || renderer.hasPendingPicture || !hasRevealed else { return }
        lastFrame = frame
        renderer.render(frame, drawable: drawable)
    }

    /// Degrees of closing over which the glass's surface fades in.
    private static let surfaceRampDegrees: Double = 12
    /// Fully frosted, a point one screen height behind the glass spreads
    /// over a third of a screen height.
    private static let maxScatter: Double = 0.33
    /// At the strongest setting, light from one screen height behind the
    /// glass keeps exp(-9), about a ten-thousandth: black.
    private static let maxLightLoss: Double = 9
    private static let maxHaze: Double = 0.2

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
