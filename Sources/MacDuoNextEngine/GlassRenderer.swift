import AppKit
import MacDuoNextCore
import Metal
import MetalPerformanceShaders
import QuartzCore

/// Everything one frame needs to know about the room.
public struct GlassFrame: Equatable {
    /// The real screen, where the lid holds it now: the frosted sheet.
    public var lid: Frame3
    /// The plane the picture was left on: the screen as it stood when the
    /// effect began.
    public var picture: Frame3
    /// The viewer's eye, in world points.
    public var eye: Vector3
    /// How far the effect has come in, 0...1. Fades in the sheet's own
    /// reflection and grain; the blur and light loss need no fade, since they
    /// grow from nothing with the distance behind the sheet.
    public var amount: Double
    /// Points of blur for each point the plane lies behind the sheet.
    public var scatter: Double
    /// The most blur, in points.
    public var maxBlurRadius: Double
    /// Light lost per screen height behind the sheet: the brightness falls
    /// as `exp(-lightLoss * depth / screenHeight)`.
    public var lightLoss: Double
    /// How much the frost's milky veil fills in, 0...1.
    public var haze: Double
    /// Strength of the sheet's reflection, 0...1.
    public var reflections: Double
    /// Strength of the frost's fixed grain, 0...1.
    public var grain: Double

    public init(
        lid: Frame3,
        picture: Frame3,
        eye: Vector3,
        amount: Double,
        scatter: Double,
        maxBlurRadius: Double,
        lightLoss: Double,
        haze: Double,
        reflections: Double,
        grain: Double
    ) {
        self.lid = lid
        self.picture = picture
        self.eye = eye
        self.amount = amount
        self.scatter = scatter
        self.maxBlurRadius = maxBlurRadius
        self.lightLoss = lightLoss
        self.haze = haze
        self.reflections = reflections
        self.grain = grain
    }
}

/// The 3D engine behind the overlay.
///
/// One compute pass draws every drawable pixel, already encoded and dithered,
/// straight into the drawable: the ray from the eye through the frosted sheet
/// of the real screen to the plane the picture was left on. The picture sits
/// on a black margin in one texture with a Gaussian pyramid over it, so a
/// frosted sample of any radius costs a handful of trilinear taps.
@MainActor
public final class GlassRenderer {

    /// Display P3 carries the same transfer function as sRGB, so the sRGB
    /// texture formats decode it correctly.
    public static let colourSpaceName = CGColorSpace.displayP3

    /// Black margin around the picture, in points. Stays above the largest
    /// blur radius, so the blur reaches real black on every side.
    nonisolated private static let paddingInPoints: CGFloat = 120

    private struct Uniforms {
        var worldToModel0: SIMD4<Float>
        var worldToModel1: SIMD4<Float>
        var worldToModel2: SIMD4<Float>
        var eyeAndAmount: SIMD4<Float>
        var lidOriginAndScale: SIMD4<Float>
        var lidAxisY: SIMD4<Float>
        var lidNormal: SIMD4<Float>
        var screen: SIMD4<Float>
        var padded: SIMD4<Float>
        var frost: SIMD4<Float>
        var surface: SIMD4<Float>
        var keyLight: SIMD4<Float>
    }

    /// One held picture, built off the main thread and adopted on it.
    public struct PreparedPicture {
        let texture: MTLTexture
        let colourSpace: CGColorSpace
        let paddedOrigin: CGPoint
        let paddedSize: CGSize
        let maxLevel: Float
        let pixelScale: CGFloat
        let screenSize: CGSize
    }

    /// Where the next frame goes.
    ///
    /// A layer belongs to one view at a time, so every overlay window needs
    /// its own.
    public private(set) var layer = CAMetalLayer()

    nonisolated private let device: MTLDevice
    nonisolated private let queue: MTLCommandQueue
    private let tracer: MTLComputePipelineState
    private let timing = FrameTiming()

    private var texture: MTLTexture?
    private var screenSize: CGSize = .zero
    private var pixelScale: CGFloat = 2
    private var paddedOrigin: CGPoint = .zero
    private var paddedSize: CGSize = .zero
    private var maxLevel: Float = 0

    /// The picture a live stream writes into. `makePicture` builds its own
    /// texture instead, so only one of the two is in use at a time.
    private var liveTexture: MTLTexture?
    private var liveSize: CGSize = .zero
    private var liveScale: CGFloat = 0
    private var isLiveSource = false
    /// The newest live frame, waiting for the next drawn frame to take it.
    private var pendingFrame: CapturedFrame?
    /// A held picture to start from, waiting for the same moment. A live
    /// frame that arrives first wins, since it is the newer of the two.
    private var pendingSeed: (buffer: MTLBuffer, width: Int, height: Int)?
    private static var hasReportedPyramidFailure = false
    /// Built once, re-encoded every frame.
    private lazy var livePyramid = MPSImageGaussianPyramid(device: device, centerWeight: 0.375)

    public var isReady: Bool { texture != nil }

    /// A live frame or seed is waiting to be drawn.
    public var hasPendingPicture: Bool { pendingFrame != nil || pendingSeed != nil }

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        do {
            let options = MTLCompileOptions()
            options.fastMathEnabled = true
            let library = try device.makeLibrary(source: GlassShaders.source, options: options)
            guard let kernel = library.makeFunction(name: "glassKernel") else {
                EngineLog.render.error("glass kernel missing")
                return nil
            }
            tracer = try device.makeComputePipelineState(function: kernel)
        } catch {
            EngineLog.render.error("glass shaders failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        EngineLog.render.notice("glass engine on \(device.name, privacy: .public)")
        configure(layer)
    }

    /// A fresh layer for a new overlay window. Later frames go to this one.
    public func makeLayer() -> CAMetalLayer {
        let fresh = CAMetalLayer()
        configure(fresh)
        layer = fresh
        return fresh
    }

    private func configure(_ target: CAMetalLayer) {
        target.device = device
        // The kernel writes encoded, dithered values itself, so the drawable
        // is plain 8-bit and writable from compute.
        target.pixelFormat = .bgra8Unorm
        target.framebufferOnly = false
        // An opaque layer covering the screen makes the window server mark
        // every window behind it as hidden, and apps stop drawing. The shader
        // writes alpha 1 everywhere, so blending gives the same picture.
        target.isOpaque = false
        // Presented in step with the refresh, so frames never tear. The
        // overlay draws from a CAMetalDisplayLink, which hands drawables over
        // when they are free, so this never blocks the main thread.
        target.displaySyncEnabled = true
        target.needsDisplayOnBoundsChange = true
    }

    /// Puts the picture on a black margin, uploads it, and builds the pyramid.
    /// Call this off the main thread.
    nonisolated public func makePicture(image: CGImage, screenSize: CGSize, pixelScale: CGFloat) -> PreparedPicture? {
        let started = CFAbsoluteTimeGetCurrent()
        let padding = Self.paddingInPoints
        let paddedSize = CGSize(
            width: screenSize.width + 2 * padding,
            height: screenSize.height + 2 * padding
        )
        let width = Int((paddedSize.width * pixelScale).rounded())
        let height = Int((paddedSize.height * pixelScale).rounded())
        guard width > 0, height > 0 else { return nil }
        let byteCount = width * height * 4

        guard let staging = device.makeBuffer(length: byteCount, options: .storageModeShared) else { return nil }

        let colourSpace: CGColorSpace
        if let space = image.colorSpace, space.model == .rgb {
            colourSpace = space
        } else {
            colourSpace = CGColorSpaceCreateDeviceRGB()
        }
        guard let context = CGContext(
            data: staging.contents(),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colourSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        let contextReady = CFAbsoluteTimeGetCurrent()

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let inset = padding * pixelScale
        context.draw(image, in: CGRect(
            x: inset,
            y: inset,
            width: CGFloat(width) - 2 * inset,
            height: CGFloat(height) - 2 * inset
        ))
        let drawn = CFAbsoluteTimeGetCurrent()

        let levels = Int(floor(log2(Double(max(width, height))))) + 1
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: true
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard var texture = device.makeTexture(descriptor: descriptor),
              let commands = queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else { return nil }
        blit.copy(
            from: staging,
            sourceOffset: 0,
            sourceBytesPerRow: width * 4,
            sourceBytesPerImage: byteCount,
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()

        MPSImageGaussianPyramid(device: device, centerWeight: 0.375)
            .encode(commandBuffer: commands, inPlaceTexture: &texture, fallbackCopyAllocator: nil)
        commands.commit()
        commands.waitUntilCompleted()
        let finished = CFAbsoluteTimeGetCurrent()

        EngineLog.render.notice(
            """
            metal texture \(width)x\(height) px, \(levels) levels: \
            context \((contextReady - started) * 1000, format: .fixed(precision: 1)) ms, \
            draw \((drawn - contextReady) * 1000, format: .fixed(precision: 1)) ms, \
            gpu \((finished - drawn) * 1000, format: .fixed(precision: 1)) ms
            """
        )
        return PreparedPicture(
            texture: texture,
            colourSpace: colourSpace,
            paddedOrigin: CGPoint(x: -padding, y: -padding),
            paddedSize: paddedSize,
            maxLevel: Float(levels - 1),
            pixelScale: pixelScale,
            screenSize: screenSize
        )
    }

    // MARK: - Live source

    /// Prepares the picture for a live stream. The margin is filled with black
    /// once; every frame after that only overwrites the interior. Nothing is
    /// drawn until the first frame lands.
    @discardableResult
    public func beginLive(screenSize: CGSize, pixelScale: CGFloat) -> Bool {
        let padding = Self.paddingInPoints
        let padded = CGSize(
            width: screenSize.width + 2 * padding,
            height: screenSize.height + 2 * padding
        )
        let width = Int((padded.width * pixelScale).rounded())
        let height = Int((padded.height * pixelScale).rounded())
        guard width > 0, height > 0 else { return false }

        if liveTexture == nil || liveSize != padded || liveScale != pixelScale {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm_srgb,
                width: width,
                height: height,
                mipmapped: true
            )
            // `renderTarget` is only there for the one clear that blacks the
            // margin.
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            descriptor.storageMode = .private
            guard let fresh = device.makeTexture(descriptor: descriptor) else { return false }
            clearToBlack(fresh)
            liveTexture = fresh
            liveSize = padded
            liveScale = pixelScale
        }

        texture = nil
        isLiveSource = true
        self.screenSize = screenSize
        self.pixelScale = pixelScale
        paddedOrigin = CGPoint(x: -padding, y: -padding)
        paddedSize = padded
        maxLevel = Float(Int(floor(log2(Double(max(width, height))))))
        layer.colorspace = CGColorSpace(name: Self.colourSpaceName)
        layer.drawableSize = CGSize(
            width: screenSize.width * pixelScale,
            height: screenSize.height * pixelScale
        )
        return true
    }

    /// Starts the live picture from one held frame. The stream's first frame
    /// overwrites it.
    @discardableResult
    public func seed(image: CGImage) -> Bool {
        guard isLiveSource, liveTexture != nil else { return false }
        let inset = Int((Self.paddingInPoints * pixelScale).rounded())
        let width = Int((screenSize.width * pixelScale).rounded())
        let height = Int((screenSize.height * pixelScale).rounded())
        guard width > 0, height > 0, inset >= 0 else { return false }
        let bytesPerRow = width * 4
        guard let staging = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              // The stream's own space, so the handover does not shift colour.
              let space = CGColorSpace(name: Self.colourSpaceName),
              let context = CGContext(
                data: staging.contents(),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        pendingSeed = (staging, width, height)
        texture = liveTexture
        return true
    }

    /// Takes one live frame. The copy and the pyramid are encoded on the same
    /// command buffer as the frame that draws them.
    public func absorb(_ frame: CapturedFrame) {
        guard isLiveSource, liveTexture != nil else { return }
        pendingFrame = frame
        pendingSeed = nil
        // The texture object is the one the next pass reads, and the copy into
        // it is encoded ahead of that pass.
        texture = liveTexture
    }

    /// Copies the newest frame into the picture and rebuilds the pyramid.
    private func absorbPending(into commands: MTLCommandBuffer) {
        guard var target = liveTexture, pendingFrame != nil || pendingSeed != nil else { return }
        let inset = Int((Self.paddingInPoints * pixelScale).rounded())
        guard let blit = commands.makeBlitCommandEncoder() else { return }
        if let frame = pendingFrame {
            let width = min(frame.texture.width, target.width - 2 * inset)
            let height = min(frame.texture.height, target.height - 2 * inset)
            guard width > 0, height > 0 else { blit.endEncoding(); return }
            blit.copy(
                from: frame.texture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: target,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: inset, y: inset, z: 0)
            )
            commands.addCompletedHandler { [frame] _ in
                withExtendedLifetime(frame) {}
            }
        } else if let seed = pendingSeed {
            let width = min(seed.width, target.width - 2 * inset)
            let height = min(seed.height, target.height - 2 * inset)
            guard width > 0, height > 0 else { blit.endEncoding(); return }
            blit.copy(
                from: seed.buffer,
                sourceOffset: 0,
                sourceBytesPerRow: seed.width * 4,
                sourceBytesPerImage: seed.width * 4 * seed.height,
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: target,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: inset, y: inset, z: 0)
            )
        }
        pendingFrame = nil
        pendingSeed = nil
        blit.endEncoding()
        let built = livePyramid.encode(
            commandBuffer: commands,
            inPlaceTexture: &target,
            fallbackCopyAllocator: nil
        )
        if !built, !Self.hasReportedPyramidFailure {
            Self.hasReportedPyramidFailure = true
            EngineLog.render.error("live pyramid in place encode returned false")
        }
        liveTexture = target
        texture = target
    }

    /// Frees the live picture.
    public func discardLive() {
        pendingFrame = nil
        pendingSeed = nil
        if isLiveSource { texture = nil }
        isLiveSource = false
        liveTexture = nil
        liveSize = .zero
        liveScale = 0
    }

    private func clearToBlack(_ target: MTLTexture) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
    }

    // MARK: - Still source

    public func adopt(_ picture: PreparedPicture) {
        isLiveSource = false
        texture = picture.texture
        // Without a tag the window server treats the drawable as sRGB and
        // converts it to the display space.
        layer.colorspace = picture.colourSpace
        paddedOrigin = picture.paddedOrigin
        paddedSize = picture.paddedSize
        maxLevel = picture.maxLevel
        pixelScale = picture.pixelScale
        screenSize = picture.screenSize
        layer.drawableSize = CGSize(
            width: picture.screenSize.width * picture.pixelScale,
            height: picture.screenSize.height * picture.pixelScale
        )
    }

    /// Lets go of the picture and the frame between runs.
    public func release() {
        texture = nil
    }

    /// Draws one frame into `drawable`, or into the layer's next drawable.
    public func render(_ frame: GlassFrame, drawable given: CAMetalDrawable? = nil) {
        guard let commands = queue.makeCommandBuffer() else { return }
        absorbPending(into: commands)
        guard let texture, screenSize.width > 0, screenSize.height > 0,
              let drawable = given ?? layer.nextDrawable(),
              let compute = commands.makeComputeCommandEncoder() else {
            commands.commit()
            return
        }
        let target = drawable.texture
        let rows = frame.picture.worldToLocalRows
        let keyLight = Vector3(-0.35, 0.8, 0.5).normalized
        func float4(_ v: Vector3, _ w: Double = 0) -> SIMD4<Float> {
            SIMD4(Float(v.x), Float(v.y), Float(v.z), Float(w))
        }
        var uniforms = Uniforms(
            worldToModel0: SIMD4(rows[0], rows[1], rows[2], rows[3]),
            worldToModel1: SIMD4(rows[4], rows[5], rows[6], rows[7]),
            worldToModel2: SIMD4(rows[8], rows[9], rows[10], rows[11]),
            eyeAndAmount: float4(frame.eye, min(max(frame.amount, 0), 1)),
            lidOriginAndScale: float4(frame.lid.origin, Double(pixelScale)),
            lidAxisY: float4(frame.lid.yAxis),
            lidNormal: float4(frame.lid.zAxis),
            screen: SIMD4(
                Float(screenSize.width), Float(screenSize.height), Float(target.width), Float(target.height)
            ),
            padded: SIMD4(
                Float(paddedOrigin.x), Float(paddedOrigin.y),
                Float(paddedSize.width), Float(paddedSize.height)
            ),
            frost: SIMD4(
                Float(max(frame.scatter, 0)),
                Float(max(frame.maxBlurRadius, 0) * Double(pixelScale)),
                Float(max(frame.lightLoss, 0)),
                Float(min(max(frame.haze, 0), 1))
            ),
            surface: SIMD4(maxLevel, Float(max(frame.reflections, 0)), Float(max(frame.grain, 0)) * 0.08, 0),
            keyLight: float4(keyLight, 1.6)
        )

        compute.setComputePipelineState(tracer)
        compute.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        compute.setTexture(target, index: 0)
        compute.setTexture(texture, index: 1)
        let threadWidth = tracer.threadExecutionWidth
        let threadHeight = max(tracer.maxTotalThreadsPerThreadgroup / threadWidth, 1)
        compute.dispatchThreads(
            MTLSize(width: target.width, height: target.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
        compute.endEncoding()
        commands.present(drawable)
        let timing = self.timing
        commands.addCompletedHandler { buffer in
            timing.record(gpuSeconds: buffer.gpuEndTime - buffer.gpuStartTime)
        }
        commands.commit()
    }
}

/// GPU time per frame, logged every few seconds while drawing.
private final class FrameTiming: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var total: Double = 0
    private var worst: Double = 0
    private var since = CACurrentMediaTime()

    func record(gpuSeconds: Double) {
        guard gpuSeconds > 0, gpuSeconds < 1 else { return }
        lock.lock()
        frames += 1
        total += gpuSeconds
        worst = max(worst, gpuSeconds)
        let now = CACurrentMediaTime()
        let span = now - since
        guard span >= 5 else {
            lock.unlock()
            return
        }
        let count = frames
        let average = total / Double(frames) * 1000
        let peak = worst * 1000
        frames = 0
        total = 0
        worst = 0
        since = now
        lock.unlock()
        EngineLog.render.notice(
            """
            gpu \(average, format: .fixed(precision: 2)) ms average, \(peak, format: .fixed(precision: 2)) ms worst, \
            \(Double(count) / span, format: .fixed(precision: 1)) frames per second
            """
        )
    }
}
