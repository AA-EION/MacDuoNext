import AppKit
import MacDuoNextCore
import Metal
import MetalPerformanceShaders
import QuartzCore

/// Everything one frame needs to know about the room.
public struct GlassFrame {
    /// The real screen, where the lid holds it now.
    public var lid: Frame3
    /// The held picture: the screen as it stood when the effect began.
    public var picture: Frame3
    /// The viewer's eye, in world points.
    public var eye: Vector3
    /// 0 draws the picture alone, exactly as the flat effect did; 1 draws it
    /// fully under the glass.
    public var glassAmount: Double
    /// How bright the room around the glass is, 0...1.
    public var environmentStrength: Double
    public var blurStrength: Double
    public var dimStrength: Double
    public var blurFloor: Double
    public var dimFloor: Double
    public var dimReach: Double
    public var maxBlurRadius: Double
    public var maxDim: Double

    public init(
        lid: Frame3,
        picture: Frame3,
        eye: Vector3,
        glassAmount: Double,
        environmentStrength: Double,
        blurStrength: Double,
        dimStrength: Double,
        blurFloor: Double,
        dimFloor: Double,
        dimReach: Double,
        maxBlurRadius: Double,
        maxDim: Double
    ) {
        self.lid = lid
        self.picture = picture
        self.eye = eye
        self.glassAmount = glassAmount
        self.environmentStrength = environmentStrength
        self.blurStrength = blurStrength
        self.dimStrength = dimStrength
        self.blurFloor = blurFloor
        self.dimFloor = dimFloor
        self.dimReach = dimReach
        self.maxBlurRadius = maxBlurRadius
        self.maxDim = maxDim
    }
}

/// The 3D engine behind the overlay.
///
/// One compute pass traces the room for every drawable pixel into a
/// half-float frame, and one small render pass presents it. The picture sits
/// on a black margin in one texture with a Gaussian pyramid over it, so blur
/// is a single trilinear sample at any radius.
///
/// Ray tracing uses Metal's acceleration structures when the GPU supports
/// them (all Apple silicon; M3 and later trace in hardware) and falls back to
/// an analytic slab elsewhere.
@MainActor
public final class GlassRenderer {

    /// Display P3 carries the same transfer function as sRGB, so the sRGB
    /// texture formats decode it correctly.
    public static let colourSpaceName = CGColorSpace.displayP3

    /// Black margin around the picture, in points. Stays above the largest
    /// blur radius, so the blur reaches real black on every side.
    nonisolated private static let paddingInPoints: CGFloat = 120

    /// Glass index of refraction: soda-lime and aluminosilicate cover glass.
    private static let indexOfRefraction: Float = 1.52

    private struct Uniforms {
        var worldToModel0: SIMD4<Float>
        var worldToModel1: SIMD4<Float>
        var worldToModel2: SIMD4<Float>
        var eyeAndGlass: SIMD4<Float>
        var lidOriginAndScale: SIMD4<Float>
        var lidAxisY: SIMD4<Float>
        var screen: SIMD4<Float>
        var padded: SIMD4<Float>
        var blur: SIMD4<Float>
        var dim: SIMD4<Float>
        var slab: SIMD4<Float>
        var glass: SIMD4<Float>
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
    private let presenter: MTLRenderPipelineState
    /// True when the tracer walks an acceleration structure.
    public let tracesRays: Bool
    /// True on GPUs with ray tracing hardware (Apple family 9: M3 and later).
    public let hasRayTracingHardware: Bool
    private var scene: GlassScene?
    private var frameTexture: MTLTexture?

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

    /// A short description of the path in use, for the log and the panel.
    public var pathDescription: String {
        if tracesRays {
            return hasRayTracingHardware ? "hardware ray tracing" : "ray tracing"
        }
        return "analytic glass"
    }

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue

        var library: MTLLibrary?
        var tracesRays = false
        if device.supportsRaytracing {
            library = Self.compile(device: device, rayTracing: true)
            tracesRays = library != nil
        }
        if library == nil {
            library = Self.compile(device: device, rayTracing: false)
        }
        guard let library,
              let kernel = library.makeFunction(name: "glassKernel"),
              let vertex = library.makeFunction(name: "presentVertex"),
              let fragment = library.makeFunction(name: "presentFragment") else {
            EngineLog.render.error("glass shaders unavailable")
            return nil
        }
        do {
            tracer = try device.makeComputePipelineState(function: kernel)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
            presenter = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            EngineLog.render.error("metal pipeline failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        self.tracesRays = tracesRays
        hasRayTracingHardware = device.supportsFamily(.apple9)
        EngineLog.render.notice(
            "glass engine on \(device.name, privacy: .public): \(tracesRays ? "ray traced" : "analytic", privacy: .public), hardware RT \(device.supportsFamily(.apple9))"
        )
        configure(layer)
    }

    private static func compile(device: MTLDevice, rayTracing: Bool) -> MTLLibrary? {
        let options = MTLCompileOptions()
        options.preprocessorMacros = ["USE_RAYTRACING": NSNumber(value: rayTracing ? 1 : 0)]
        options.fastMathEnabled = true
        do {
            return try device.makeLibrary(source: GlassShaders.source, options: options)
        } catch {
            EngineLog.render.error(
                "glass shaders (ray tracing \(rayTracing)) failed: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
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
        target.pixelFormat = .bgra8Unorm_srgb
        target.framebufferOnly = true
        // An opaque layer covering the screen makes the window server mark
        // every window behind it as hidden, and apps stop drawing. The shader
        // writes alpha 1 everywhere, so blending gives the same picture.
        target.isOpaque = false
        // Waiting for the refresh here blocks the main thread. While a capture
        // stream leaves this app out of its own picture, the window server
        // draws the screen twice, the drawable comes back late, and the wait
        // lands a refresh later: 60 frames per second becomes 32. The display
        // link already paces the drawing.
        target.displaySyncEnabled = false
        target.needsDisplayOnBoundsChange = true
    }

    /// Builds the glass for a screen, unless it is already built.
    public func prepareGlass(_ shape: GlassSlabMesh.Shape) {
        guard scene?.shape != shape else { return }
        scene = GlassScene(device: device, queue: queue, shape: shape, buildsAccelerationStructure: tracesRays)
        if scene == nil {
            EngineLog.render.error("glass scene could not be built; drawing without glass")
        }
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
        frameTexture = nil
    }

    /// Draws one frame.
    public func render(_ frame: GlassFrame) {
        guard let commands = queue.makeCommandBuffer() else { return }
        absorbPending(into: commands)
        let width = Int((screenSize.width * pixelScale).rounded())
        let height = Int((screenSize.height * pixelScale).rounded())
        guard let texture, width > 0, height > 0,
              let target = frameTarget(width: width, height: height),
              let drawable = layer.nextDrawable() else {
            commands.commit()
            return
        }

        let rows = frame.picture.worldToLocalRows
        let shape = scene?.shape
        let bounds = shape?.bounds ?? (minX: 0, minY: 0, maxX: Double(screenSize.width), maxY: Double(screenSize.height))
        // Without a scene there is nothing to trace; the straight picture
        // still draws.
        let glassAmount = scene == nil ? 0 : frame.glassAmount
        let keyLight = Vector3(-0.35, 0.8, 0.5).normalized
        var uniforms = Uniforms(
            worldToModel0: SIMD4(rows[0], rows[1], rows[2], rows[3]),
            worldToModel1: SIMD4(rows[4], rows[5], rows[6], rows[7]),
            worldToModel2: SIMD4(rows[8], rows[9], rows[10], rows[11]),
            eyeAndGlass: SIMD4(Float(frame.eye.x), Float(frame.eye.y), Float(frame.eye.z), Float(glassAmount)),
            lidOriginAndScale: SIMD4(
                Float(frame.lid.origin.x), Float(frame.lid.origin.y), Float(frame.lid.origin.z), Float(pixelScale)
            ),
            lidAxisY: SIMD4(Float(frame.lid.yAxis.x), Float(frame.lid.yAxis.y), Float(frame.lid.yAxis.z), 0),
            screen: SIMD4(Float(screenSize.width), Float(screenSize.height), Float(width), Float(height)),
            padded: SIMD4(
                Float(paddedOrigin.x), Float(paddedOrigin.y),
                Float(paddedSize.width), Float(paddedSize.height)
            ),
            blur: SIMD4(
                Float(frame.maxBlurRadius * Double(pixelScale)), Float(frame.blurStrength),
                Float(frame.blurFloor), maxLevel
            ),
            dim: SIMD4(Float(frame.dimFloor), Float(frame.dimStrength), Float(frame.dimReach), Float(frame.maxDim)),
            slab: SIMD4(Float(bounds.minX), Float(bounds.minY), Float(bounds.maxX), Float(bounds.maxY)),
            glass: SIMD4(
                Float(shape?.thickness ?? 1), Self.indexOfRefraction,
                Float(max(frame.environmentStrength, 0)), 0
            ),
            keyLight: SIMD4(Float(keyLight.x), Float(keyLight.y), Float(keyLight.z), 1.6)
        )

        guard let compute = commands.makeComputeCommandEncoder() else {
            commands.commit()
            return
        }
        compute.setComputePipelineState(tracer)
        compute.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        if tracesRays {
            // The kernel declares these buffers whenever it traces rays, so a
            // missing scene still binds something valid; the glass amount is
            // then 0 and they are never read.
            if let scene, let structure = scene.accelerationStructure {
                compute.setAccelerationStructure(structure, bufferIndex: 1)
                compute.setBuffer(scene.normals, offset: 0, index: 2)
                compute.setBuffer(scene.indices, offset: 0, index: 3)
            } else {
                compute.endEncoding()
                commands.commit()
                return
            }
        }
        compute.setTexture(target, index: 0)
        compute.setTexture(texture, index: 1)
        let threadWidth = tracer.threadExecutionWidth
        let threadHeight = max(tracer.maxTotalThreadsPerThreadgroup / threadWidth, 1)
        compute.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
        compute.endEncoding()

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            commands.commit()
            return
        }
        encoder.setRenderPipelineState(presenter)
        encoder.setFragmentTexture(target, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    /// The half-float frame the tracer writes, kept between frames.
    private func frameTarget(width: Int, height: Int) -> MTLTexture? {
        if let frameTexture, frameTexture.width == width, frameTexture.height == height {
            return frameTexture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        frameTexture = device.makeTexture(descriptor: descriptor)
        return frameTexture
    }
}
