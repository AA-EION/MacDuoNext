import AVFoundation
import CoreML
import CoreVideo
import MacDuoNextCore
import QuartzCore
import Vision
import os

/// Finds the viewer's face with the built-in camera.
///
/// Everything stays on the Mac and in memory: frames go straight from the
/// camera to Vision's face rectangle detector, which ships with macOS and
/// runs on the Neural Engine, and only the newest box is kept. No model is
/// downloaded, no frame is stored, nothing leaves the process.
///
/// It is built to be cheap. Vision's face rectangle detector is the smallest
/// it has, a few milliseconds per frame, and on Apple silicon it runs on the
/// Neural Engine. It is pinned there explicitly so it never falls back to
/// the GPU, which is busy tracing the glass. The camera runs at 640 by 480 in
/// its native YUV format, so no frame is converted; late frames are dropped
/// rather than queued; and the search is narrowed to where the face should
/// be, predicted from the last eye position and the lid angle sensor, with
/// the whole frame searched again when the face is not there. The camera only
/// runs while the lid is past the start angle, and the green light shows it.
public final class FaceTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {

    public enum Authorization: Equatable {
        case authorized
        case notDetermined
        case denied
        /// No built-in camera, or one this app cannot use.
        case unavailable
    }

    private static let log = Logger(subsystem: "com.macduonext.app", category: "camera")

    private let sessionQueue = DispatchQueue(label: "com.macduonext.camera.session", qos: .userInitiated)
    private let frameQueue = DispatchQueue(label: "com.macduonext.camera.frames", qos: .userInteractive)
    private let session = AVCaptureSession()
    private let request: VNDetectFaceRectanglesRequest = {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        return request
    }()
    /// Which processor runs the detector, for the log.
    public private(set) var computeDescription = "automatic"
    private let sequence = VNSequenceRequestHandler()
    private var isConfigured = false
    private var camera: AVCaptureDevice?
    /// Rate statistics, logged every few seconds while running.
    private var statsSince: Double = 0
    private var statsFrames = 0
    private var statsDetectionTime: Double = 0
    /// Read on the session queue only.
    private var wantsRunning = false

    private let lock = NSLock()
    private var newest: FaceSighting?
    private var frameCount = 0
    private var faceCount = 0
    private var searchHint: NormalisedRect?
    private var missesInHint = 0
    private var frameSize: (width: Double, height: Double)?

    /// After this many frames with no face inside the hint, the whole frame
    /// is searched until the face turns up again.
    private static let hintMissLimit = 2

    public override init() {
        super.init()
        preferNeuralEngine()
    }

    /// Pins the detector's network to the Neural Engine where there is one.
    /// Vision usually picks it anyway; pinning keeps it off the GPU, which is
    /// busy drawing the glass. Pre- and post-processing keep Vision's choice.
    /// Intel Macs have no Neural Engine and keep Vision's choice throughout.
    private func preferNeuralEngine() {
        guard let stages = try? request.supportedComputeStageDevices,
              let devices = stages[.main] else { return }
        let neural = devices.first { device in
            if case .neuralEngine = device { return true }
            return false
        }
        if let neural {
            request.setComputeDevice(neural, for: .main)
            computeDescription = "Neural Engine"
        }
        Self.log.notice("face detector compute: \(self.computeDescription, privacy: .public)")
    }

    /// Holds the camera at 30 frames a second. Left alone, the built-in
    /// camera stretches its exposure in dim light and drops to 15 or fewer,
    /// and the head then visibly lags. A shorter exposure is noisier, which
    /// the face detector does not mind.
    private func lockFrameRate(_ camera: AVCaptureDevice) {
        let target = CMTime(value: 1, timescale: 30)
        guard camera.activeFormat.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
        }) else { return }
        do {
            try camera.lockForConfiguration()
            camera.activeVideoMinFrameDuration = target
            camera.activeVideoMaxFrameDuration = target
            camera.unlockForConfiguration()
        } catch {
            Self.log.error("camera frame rate not locked: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Permission

    public static var authorization: Authorization {
        guard builtInCamera() != nil else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    /// Asks once. macOS shows its own prompt with the usage description.
    public static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    /// The camera in the lid. The geometry assumes it sits above the screen,
    /// so a Continuity Camera or a webcam would put the eye in the wrong place.
    static func builtInCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.first { !$0.isContinuityCamera }
    }

    // MARK: - Running

    /// Starts the camera. Returns at once; the camera takes a few hundred
    /// milliseconds to deliver its first frame.
    public func start() {
        sessionQueue.async { [self] in
            wantsRunning = true
            guard configureIfNeeded(), !session.isRunning else { return }
            session.startRunning()
            // Starting applies the session preset, which resets the rate.
            if let camera { lockFrameRate(camera) }
            Self.log.notice("camera started")
        }
    }

    /// Stops the camera and forgets the last face.
    public func stop() {
        lock.lock()
        newest = nil
        searchHint = nil
        missesInHint = 0
        lock.unlock()
        sessionQueue.async { [self] in
            wantsRunning = false
            guard session.isRunning else { return }
            session.stopRunning()
            lock.lock()
            let frames = frameCount, faces = faceCount
            frameCount = 0
            faceCount = 0
            lock.unlock()
            Self.log.notice("camera stopped after \(frames) frames, face in \(faces)")
        }
    }

    /// Where the face is expected in the next frame, or `nil` to search all
    /// of it. Set from the main thread on every drawn frame.
    public func setSearchHint(_ hint: NormalisedRect?) {
        lock.lock()
        searchHint = hint
        lock.unlock()
    }

    /// The size of the frames the camera delivers, once one has arrived.
    public func currentFrameSize() -> (width: Double, height: Double)? {
        lock.lock()
        defer { lock.unlock() }
        return frameSize
    }

    /// The newest face, if one has been seen since the camera started.
    public func latestFace() -> FaceSighting? {
        lock.lock()
        defer { lock.unlock() }
        return newest
    }

    private func configureIfNeeded() -> Bool {
        if isConfigured { return true }
        guard let camera = Self.builtInCamera() else {
            Self.log.error("no built-in camera")
            return false
        }
        do {
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            for preset in [AVCaptureSession.Preset.vga640x480, .hd1280x720, .low] where session.canSetSessionPreset(preset) {
                session.sessionPreset = preset
                break
            }
            let input = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(input) else { return false }
            session.addInput(input)

            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: frameQueue)
            guard session.canAddOutput(output) else { return false }
            session.addOutput(output)
            // The geometry expects the camera's own view, not a mirror.
            if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            self.camera = camera
            isConfigured = true
            return true
        } catch {
            Self.log.error("camera input failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: - Frames

    /// Called on the frame queue only.
    private func recordStats(detection: Double) {
        let now = CACurrentMediaTime()
        if statsFrames == 0 { statsSince = now }
        statsFrames += 1
        statsDetectionTime += detection
        let span = now - statsSince
        guard span >= 5 else { return }
        let rate = Double(statsFrames - 1) / span
        let milliseconds = statsDetectionTime / Double(statsFrames) * 1000
        Self.log.notice(
            "camera \(rate, format: .fixed(precision: 1)) fps, detection \(milliseconds, format: .fixed(precision: 1)) ms"
        )
        statsFrames = 0
        statsDetectionTime = 0
    }

    /// When the frame was exposed, on the same clock as `CACurrentMediaTime`.
    /// Capture timestamps run on the host clock; anything implausible falls
    /// back to the arrival time less one frame.
    private static func captureTime(of sampleBuffer: CMSampleBuffer) -> Double {
        let now = CACurrentMediaTime()
        let stamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        if stamp.isFinite, stamp <= now, now - stamp < 0.5 {
            return stamp
        }
        return now - 1.0 / 30
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let captured = Self.captureTime(of: sampleBuffer)
        let width = Double(CVPixelBufferGetWidth(pixels))
        let height = Double(CVPixelBufferGetHeight(pixels))

        lock.lock()
        let hint = missesInHint < Self.hintMissLimit ? searchHint : nil
        lock.unlock()
        let region = hint.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
            ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        request.regionOfInterest = region
        let detectionStarted = CACurrentMediaTime()
        do {
            try sequence.perform([request], on: pixels, orientation: .up)
        } catch {
            return
        }
        recordStats(detection: CACurrentMediaTime() - detectionStarted)
        // The largest face is the one at the keyboard.
        let face = (request.results ?? [])
            .filter { $0.confidence > 0.5 }
            .max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }

        lock.lock()
        frameCount += 1
        frameSize = (width, height)
        if let face {
            faceCount += 1
            missesInHint = 0
            // Boxes come back relative to the region searched.
            let box = face.boundingBox
            newest = FaceSighting(
                x: Double(region.minX + box.minX * region.width),
                y: Double(region.minY + box.minY * region.height),
                width: Double(box.width * region.width),
                height: Double(box.height * region.height),
                imageWidth: width,
                imageHeight: height,
                timestamp: captured
            )
        } else if hint != nil {
            missesInHint += 1
        } else {
            // The whole frame came up empty; give the next hint a chance.
            missesInHint = 0
        }
        lock.unlock()
    }
}
