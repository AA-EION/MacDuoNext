import AppKit
import Combine
import MacDuoNextCore
import MacDuoNextLidKit
import MacDuoNextVision
import QuartzCore

/// Watches the lid angle and drives the glass overlay.
///
/// A timer polls the sensor, and a display link advances a spring at the
/// screen refresh rate so the ramp stays smooth between readings. While the
/// effect is up, the camera looks for the viewer, and each drawn frame puts
/// the eye where the face is, so the held picture stays put in the room.

/// Identity of the built-in display. `NSApplication` posts a screen change for
/// a backlight change too, and this tells the two apart.
struct Layout: Equatable {
    var displayID: CGDirectDisplayID?
    var frame: CGRect?
}

/// What head tracking is doing, for the settings panel.
enum TrackingStatus: Equatable {
    case off
    /// Waiting for the lid to pass the start angle; the camera is off.
    case standby
    case searching
    case tracking
    /// Lost the face; drifting back to the centre.
    case returning
}

@MainActor
final class LidController: ObservableObject {

    @Published private(set) var currentAngle: Double = 0
    @Published private(set) var isSensorAvailable = false
    @Published private(set) var isActive = false
    @Published private(set) var trackingStatus: TrackingStatus = .off
    @Published private(set) var cameraAuthorization: FaceTracker.Authorization = .notDetermined

    let snapshotter = ScreenSnapshotter()

    private let preferences: Preferences
    private let sensor = LidAngleSensor()
    private let overlay = GlassOverlay()
    private let streamer = ScreenStreamer()
    private let faceTracker = FaceTracker()
    private let eyeEstimator = EyeEstimator()
    private let cameraSchedule = CameraSchedule()
    private var viewpoint = ViewpointController(centre: .zero)
    private var angleHistory = LidAngleHistory()
    private var isCameraRunning = false
    /// The room of the current run, measured when the effect starts.
    private var room: LidGeometry?
    /// Where the head was when the camera last stopped while tracking.
    private var lastTrackedEye: (position: Vector3, time: Double)?

    private var enabledSubscription: AnyCancellable?
    private var pictureTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var pollInterval: TimeInterval = 0
    private var displayLink: CAMetalDisplayLink?
    private var displayLinkProxy: MetalDisplayLinkProxy?
    private var lastFrameTime: CFTimeInterval = 0
    /// Recent changes of the sensor reading, for the angle at display time.
    private var anglePredictor = LidAnglePredictor()
    private var lastPublishTime: CFTimeInterval = 0

    private var rawAngle: Double = 0
    /// Degrees per second, negative while the lid closes.
    private var angularVelocity: Double = 0
    private var lastChangedAngle: Double?
    private var lastChangeTime: CFTimeInterval = 0
    private var lastClosingTime: CFTimeInterval = -.greatestFiniteMagnitude
    /// Only rounds off the corners where a new reading corrects the
    /// prediction; the prediction itself removes the sensor's lag.
    private var visualAngle = CriticallyDampedSpring(frequency: 40)
    private var consecutiveFailedReads = 0
    private var startedAt: CFTimeInterval = 0
    private var preview: PreviewRun?
    private var isSuspended = false
    private var isCapturePending = false
    private var motionIntent = LidMotionIntent()
    private var openDwell = LidOpenDwell()
    /// Where the lid last moved to by more than `timeoutMovementThreshold`,
    /// and when. The timeout counts from there.
    private var timeoutReferenceAngle: Double?
    private var timeoutReferenceTime: CFTimeInterval = 0
    /// Set when the timeout ends the effect, cleared once the lid rises back
    /// above the threshold. Closing further from the same resting spot must
    /// not retrigger it.
    private var timeoutAwaitingRelease = false
    /// The setting as last seen, so flipping it drops stale tracking.
    private var wasTimeoutEnabled = false
    /// True while `beginClosingOut()` is easing the picture back to flat.
    private var isClosingOut = false
    private var closingOutStartedAt: CFTimeInterval = 0
    private var builtInLayout = Layout()
    private var peakAngle: Double = 0
    /// The lowest reading since the effect started. Opening releases only
    /// once the lid has risen `LidEffectPolicy.minimumReleaseRise` above it.
    private var lowestRunAngle: Double = 0

    private static let idlePollInterval: TimeInterval = 1.0 / 8
    /// While the effect is up or close, the sensor is read at 60 Hz so each
    /// change of its value is seen within a frame.
    private static let activePollInterval: TimeInterval = 1.0 / 60
    private static let fadeInDuration: TimeInterval = 0.07
    /// Degrees above the pre-warm zone at which polling speeds up.
    private static let fastPollMargin: Double = 20

    /// Closing speed that counts as a deliberate close, in degrees per second.
    /// A still lid reads under 0.5.
    private static let triggerClosingSpeed: Double = 2

    /// Opening speed that counts as a deliberate reversal, in degrees per second.
    private static let triggerOpeningSpeed: Double = 2

    /// How long after the lid last moved down the effect may still start.
    private static let closingMemory: TimeInterval = 1.5

    private static let predictionSpeedFloor: Double = 40

    /// Sensor latency the prediction adds on top of the reading's own age.
    private static let predictionLatency: TimeInterval = 0.04

    /// The ordinary hysteresis release waits this long. A prediction can fire
    /// while the last reading is still above the trigger angle, but deliberate
    /// opening is allowed to release immediately.
    private static let minimumEffectDuration: TimeInterval = 0.35

    /// How long a lid held above the start angle waits before it counts as
    /// opened again, for openings slower than `triggerOpeningSpeed`.
    private static let openDwellDuration: TimeInterval = 1

    /// Movement within this many degrees counts as holding still.
    private static let timeoutMovementThreshold: Double = 2

    /// How long the lid has to hold still before the timeout ends the effect.
    private static let timeoutStillDuration: TimeInterval = 2

    /// How close the eased angle must get to flat before the last frame
    /// snaps there. Half a degree short, the dim curve still darkens the top
    /// of the picture by several percent, and the fade would then reveal a
    /// brighter screen underneath.
    private static let closingOutSettleEpsilon: Double = 0.05

    /// Safety cap, in case the spring never quite settles.
    private static let closingOutMaxDuration: TimeInterval = 1.2

    /// A scripted angle sweep, so the settings panel can show the effect
    /// without the lid moving. It feeds the same path the sensor feeds.
    private struct PreviewRun {
        let startedAt: CFTimeInterval
        let open: Double
        let shut: Double
        let closing: CFTimeInterval = 1.4
        let hold: CFTimeInterval = 0.8
        let opening: CFTimeInterval = 0.6

        /// `nil` once the run is over.
        func angle(at now: CFTimeInterval) -> Double? {
            let elapsed = now - startedAt
            if elapsed < closing { return open + (shut - open) * (elapsed / closing) }
            if elapsed < closing + hold { return shut }
            if elapsed < closing + hold + opening {
                return shut + (open - shut) * ((elapsed - closing - hold) / opening)
            }
            return nil
        }
    }

    init(preferences: Preferences) {
        self.preferences = preferences
        enabledSubscription = preferences.$isEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard !enabled else { return }
                self?.disableEffect()
            }
    }

    // MARK: - Lifecycle

    func start() {
        isSensorAvailable = sensor.isAvailable
        refreshCameraAuthorization()
        guard isSensorAvailable else { return }

        if let angle = sensor.angle() {
            rawAngle = angle
            currentAngle = angle
            visualAngle.reset(to: angle)
        }
        // Before the first poll, which reads it.
        builtInLayout = Layout(displayID: NSScreen.builtIn?.displayID, frame: NSScreen.builtIn?.frame)
        setPollInterval(Self.idlePollInterval)
        observeSystemEvents()
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.macduonext.app.preview"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.runPreview() }
        }
        overlay.warmUp()
        Task {
            await snapshotter.warmFilter()
            // After the overlay has put its presence window up, so the filter
            // can name this app and leave the overlay out of the picture.
            try? await Task.sleep(nanoseconds: 500_000_000)
            await streamer.warmFilter()
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollInterval = 0
        stopEffectAndCapture()
    }

    private func stopEffectAndCapture() {
        stopCamera()
        pictureTask?.cancel()
        pictureTask = nil
        isCapturePending = false
        isClosingOut = false
        stopDisplayLink()
        overlay.dismiss(animated: false)
        snapshotter.stop()
        streamer.stop()
        overlay.discardLive()
        preview = nil
        isActive = false
    }

    private func disableEffect() {
        stopEffectAndCapture()
        lastChangedAngle = nil
        angularVelocity = 0
        lastClosingTime = -.greatestFiniteMagnitude
        motionIntent.reset()
        openDwell.reset()
        peakAngle = 0
        if pollTimer != nil { setPollInterval(Self.idlePollInterval) }
    }

    /// Plays the effect once on the current screen contents.
    func runPreview() {
        guard preferences.isEnabled, !isSuspended, preview == nil, !isActive else { return }
        // Well above the trigger angle, so the sweep runs the pre-warm the way
        // a real close does.
        preview = PreviewRun(
            startedAt: CACurrentMediaTime(),
            open: max(
                preferences.thresholdAngle + preferences.hysteresis + 5,
                min(preferences.thresholdAngle + 35, 130)
            ),
            shut: max(preferences.thresholdAngle - 55, 5)
        )
        setPollInterval(Self.activePollInterval)
    }

    // MARK: - Polling

    private func setPollInterval(_ interval: TimeInterval) {
        guard pollInterval != interval else { return }
        pollInterval = interval
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func poll() {
        guard !isSuspended else { return }

        let angle: Double
        if let run = preview {
            guard let scripted = run.angle(at: CACurrentMediaTime()) else {
                preview = nil
                peakAngle = 0
                if isActive { setActive(false) }
                return
            }
            angle = scripted
        } else {
            guard let read = sensor.angle() else {
                consecutiveFailedReads += 1
                if consecutiveFailedReads > 30, isActive {
                    Diagnostics.lid.notice(
                        """
                        release: sensor read failed \(self.consecutiveFailedReads) times in a row, \
                        last angle \(self.rawAngle, format: .fixed(precision: 2))
                        """
                    )
                    setActive(false)
                }
                return
            }
            if consecutiveFailedReads > 0 {
                Diagnostics.lid.notice(
                    "sensor recovered after \(self.consecutiveFailedReads) failed reads, angle \(read, format: .fixed(precision: 2))"
                )
            }
            consecutiveFailedReads = 0
            angle = read
        }

        rawAngle = angle
        angleHistory.record(angle: angle, at: CACurrentMediaTime())
        anglePredictor.record(angle: angle, at: CACurrentMediaTime())
        peakAngle = max(peakAngle, angle)
        if isActive { lowestRunAngle = min(lowestRunAngle, angle) }
        publish(angle: angle)

        if preferences.isEnabled {
            updateVelocity(with: angle)
            openDwell.update(angle: angle, at: CACurrentMediaTime(), dwellAngle: effectPolicy.dwellAngle)
            reconcile(angle: angle)
        }

        updateCamera(angle: angle)

        let prewarmZone = preferences.thresholdAngle + preferences.prewarmCeiling
        let wantsFastPolling = preferences.isEnabled
            && (preview != nil || isActive || angle <= prewarmZone + Self.fastPollMargin)
        setPollInterval(wantsFastPolling ? Self.activePollInterval : Self.idlePollInterval)
    }

    private var effectPolicy: LidEffectPolicy {
        LidEffectPolicy(threshold: preferences.thresholdAngle, hysteresis: preferences.hysteresis)
    }

    /// Whether the picture belongs on screen for this angle. It widens the
    /// angle for release and keeps a lid held below the angle showing, unless
    /// the timeout ends it first.
    private func wantsEffect(angle: Double) -> Bool {
        // `builtInLayout` is kept current by the screen change observer, so
        // this does not enumerate the screens on every sample.
        guard preferences.isEnabled, builtInLayout.displayID != nil else { return false }
        if preferences.isTimeoutEnabled != wasTimeoutEnabled {
            timeoutReferenceAngle = nil
            timeoutAwaitingRelease = false
            wasTimeoutEnabled = preferences.isTimeoutEnabled
        }

        let now = CACurrentMediaTime()
        let threshold = preferences.thresholdAngle
        let minimumDurationElapsed = now - startedAt > Self.minimumEffectDuration

        if !isActive, preferences.isTimeoutEnabled, timeoutAwaitingRelease {
            guard angle >= threshold else { return false }
            timeoutAwaitingRelease = false
        }

        let wanted = effectPolicy.wantsEffect(
            isEnabled: preferences.isEnabled,
            isActive: isActive,
            angle: angle,
            predictedAngle: predictedAngle(),
            riseSinceLowest: angle - lowestRunAngle,
            hasBeenAboveThreshold: peakAngle >= threshold,
            wasClosingRecently: motionIntent.wasClosingRecently(
                at: now,
                memoryDuration: Self.closingMemory
            ),
            isClearlyOpening: angularVelocity >= Self.triggerOpeningSpeed,
            hasDwelledOpen: openDwell.hasDwelled(at: now, duration: Self.openDwellDuration),
            minimumDurationElapsed: minimumDurationElapsed
        )

        // The timeout only cuts short a run the policy would keep showing.
        if isActive, wanted, minimumDurationElapsed,
           preferences.isTimeoutEnabled, isPastTimeout(angle: angle) {
            timeoutAwaitingRelease = true
            return false
        }
        return wanted
    }

    /// True once the angle has held within `timeoutMovementThreshold` of its
    /// last significant position for `timeoutStillDuration`.
    private func isPastTimeout(angle: Double) -> Bool {
        let now = CACurrentMediaTime()
        if let reference = timeoutReferenceAngle,
           abs(angle - reference) <= Self.timeoutMovementThreshold {
            return now - timeoutReferenceTime >= Self.timeoutStillDuration
        }
        timeoutReferenceAngle = angle
        timeoutReferenceTime = now
        return false
    }

    /// Brings the screen in line with `wantsEffect` on every sample. A run
    /// whose screenshot failed is retried here.
    private func reconcile(angle: Double) {
        guard preferences.isEnabled, !isSuspended else { return }
        let wanted = wantsEffect(angle: angle)
        if wanted != isActive {
            Diagnostics.lid.notice(
                """
                \(wanted ? "start" : "end", privacy: .public) raw \(angle, format: .fixed(precision: 2)) \
                predicted \(self.predictedAngle(), format: .fixed(precision: 2)) \
                velocity \(self.angularVelocity, format: .fixed(precision: 1)) deg/s \
                snapshot \(self.snapshotter.latestImage != nil)
                """
            )
            setActive(wanted)
            return
        }
        if isActive {
            if preferences.isLivePicture { streamer.start() }
            if !overlay.isVisible, !isCapturePending { presentPicture() }
            // A visible overlay with no link would sit at its first frame.
            if overlay.isVisible, displayLink == nil { startDisplayLink() }
        } else if !isClosingOut {
            // The ease back to flat still draws the live picture, and this
            // would free it.
            updatePrewarm(angle: angle, ceiling: preferences.thresholdAngle + preferences.prewarmCeiling)
        }
    }

    private func updateVelocity(with angle: Double) {
        let now = CACurrentMediaTime()
        guard let last = lastChangedAngle else {
            lastChangedAngle = angle
            lastChangeTime = now
            return
        }
        if angle != last {
            let dt = now - lastChangeTime
            if dt > 0.001 {
                let instant = (angle - last) / dt
                angularVelocity = 0.5 * instant + 0.5 * angularVelocity
            }
            lastChangedAngle = angle
            lastChangeTime = now
        } else if now - lastChangeTime > 0.4 {
            angularVelocity = 0
        }
        motionIntent.update(
            angularVelocity: angularVelocity,
            at: now,
            closingSpeed: Self.triggerClosingSpeed,
            openingSpeed: Self.triggerOpeningSpeed
        )
        if angularVelocity >= Self.triggerOpeningSpeed {
            lastClosingTime = -.greatestFiniteMagnitude
        } else if angularVelocity <= -preferences.closingSpeed {
            lastClosingTime = now
        }
    }

    /// Runs only while the lid is closing, so holding it still does not leave
    /// a capture loop running.
    private func updatePrewarm(angle: Double, ceiling: Double) {
        let closingRecently = CACurrentMediaTime() - lastClosingTime < preferences.prewarmLinger
        guard angle <= ceiling, closingRecently else {
            snapshotter.endPrewarm()
            streamer.stop()
            overlay.discardLive()
            return
        }
        guard preferences.isLivePicture else {
            streamer.stop()
            overlay.discardLive()
            snapshotter.beginPrewarm(interval: preferences.prewarmInterval)
            return
        }
        // Only the stream. Asking ScreenCaptureKit for a screenshot at the
        // same time makes it serve neither quickly.
        snapshotter.endPrewarm()
        streamer.start()
    }

    /// A reading can be a full sensor refresh old, so a fast close works from
    /// where the lid is heading rather than the last reading.
    private func predictedAngle() -> Double {
        guard angularVelocity < -Self.predictionSpeedFloor else { return rawAngle }
        let staleness = min(CACurrentMediaTime() - lastChangeTime, 0.12)
        return rawAngle + angularVelocity * (staleness + Self.predictionLatency)
    }

    private func publish(angle: Double) {
        let now = CACurrentMediaTime()
        guard now - lastPublishTime > 0.08 else { return }
        lastPublishTime = now
        if abs(currentAngle - angle) > 0.001 { currentAngle = angle }
    }

    // MARK: - Depth effect

    private func setActive(_ active: Bool) {
        isActive = active
        if active {
            peakAngle = rawAngle
            lowestRunAngle = rawAngle
            openDwell.reset()
            isClosingOut = false
            startedAt = CACurrentMediaTime()
            if preferences.isTimeoutEnabled {
                timeoutReferenceAngle = rawAngle
                timeoutReferenceTime = startedAt
            }
            visualAngle.reset(to: rawAngle)
            beginViewpoint()
            snapshotter.endPrewarm()
            setPollInterval(Self.activePollInterval)
            presentPicture()
            updateCamera(angle: rawAngle)
        } else {
            snapshotter.discard()
            timeoutReferenceAngle = nil
            updateCamera(angle: rawAngle)
            beginClosingOut()
        }
    }

    /// Eases the picture back to flat before the overlay fades away. Ending
    /// the effect with the lid still shut would otherwise fade out a warped
    /// picture. `step(_:)` drives the ease and calls `finishClosingOut()`.
    private func beginClosingOut() {
        // Nothing to ease before the picture is up, or with no link to draw it.
        guard overlay.isVisible, displayLink != nil else {
            stopDisplayLink()
            overlay.dismiss(animated: true)
            return
        }
        isClosingOut = true
        closingOutStartedAt = CACurrentMediaTime()
    }

    private func finishClosingOut() {
        isClosingOut = false
        stopDisplayLink()
        overlay.dismiss(animated: true)
    }

    private func endEffect() {
        setActive(false)
    }

    /// Shows the held screenshot, or waits for one. A pre-warm capture that is
    /// already running counts as that wait.
    private func presentPicture() {
        guard preferences.isEnabled, !isSuspended, isActive else { return }
        if preferences.isLivePicture, let screen = NSScreen.builtIn,
           overlay.showLive(
               on: screen,
               startAngle: preferences.thresholdAngle,
               tuning: tuning,
               fadeIn: Self.fadeInDuration
           ) {
            startDisplayLink()
            if let frame = streamer.newFrame() {
                Diagnostics.lid.notice("present: live, a stream frame was ready")
                overlay.absorb(frame)
                return
            }
            // A fast close can reach the trigger angle before the stream has a
            // frame. One screenshot starts the picture off.
            if let image = snapshotter.latestImage {
                Diagnostics.lid.notice("present: live, seeding from the pre-warm screenshot")
                overlay.seed(image: image)
                return
            }
            Diagnostics.lid.notice("present: live, no picture yet, asking for a screenshot")
            requestSeed()
            return
        }

        if let image = snapshotter.latestImage, let screen = snapshotter.latestScreen {
            show(image: image, on: screen)
            return
        }
        isCapturePending = true
        pictureTask?.cancel()
        pictureTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.snapshotter.captureOnce()
            guard !Task.isCancelled else { return }
            self.pictureTask = nil
            self.isCapturePending = false
            Diagnostics.lid.notice(
                """
                capture landed: image \(self.snapshotter.latestImage != nil) \
                on \(self.isActive) overlay \(self.overlay.isVisible)
                """
            )
            guard self.isActive, !self.overlay.isVisible,
                  let image = self.snapshotter.latestImage,
                  let screen = self.snapshotter.latestScreen else { return }
            self.show(image: image, on: screen)
        }
    }

    /// Takes one screenshot to start a live overlay that has nothing to show
    /// yet. A stream frame that lands first makes it unnecessary.
    private func requestSeed() {
        isCapturePending = true
        let started = CACurrentMediaTime()
        pictureTask?.cancel()
        pictureTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.snapshotter.captureOnce()
            guard !Task.isCancelled else { return }
            self.pictureTask = nil
            self.isCapturePending = false
            Diagnostics.lid.notice(
                """
                seed capture landed after \((CACurrentMediaTime() - started) * 1000, format: .fixed(precision: 0)) ms: \
                image \(self.snapshotter.latestImage != nil) on \(self.isActive) \
                ready \(self.overlay.isPictureReady)
                """
            )
            guard self.isActive, !self.overlay.isPictureReady,
                  let image = self.snapshotter.latestImage else { return }
            self.overlay.seed(image: image)
        }
    }

    private func show(image: CGImage, on screen: NSScreen) {
        overlay.show(
            image: image,
            on: screen,
            startAngle: preferences.thresholdAngle,
            tuning: tuning,
            fadeIn: Self.fadeInDuration
        )
        // The link belongs to the overlay window.
        startDisplayLink()
    }

    // MARK: - Animation

    /// Drives drawing from a Metal display link on the overlay's layer. It
    /// hands over a drawable when the display can take one, timed to the
    /// refresh: no tearing, and nothing on the main thread waits for the GPU.
    private func startDisplayLink() {
        stopDisplayLink()
        guard let layer = overlay.metalLayer else {
            Diagnostics.lid.notice("display link skipped, no overlay layer")
            return
        }
        Diagnostics.lid.notice("display link started")
        let proxy = MetalDisplayLinkProxy { [weak self] update in
            MainActor.assumeIsolated { self?.step(update) }
        }
        let link = CAMetalDisplayLink(metalLayer: layer)
        link.delegate = proxy
        link.preferredFrameLatency = 1
        if let screen = NSScreen.builtIn {
            let fastest = Float(screen.maximumFramesPerSecond)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: fastest, preferred: fastest)
        }
        link.add(to: .main, forMode: .common)
        lastFrameTime = CACurrentMediaTime()
        displayLink = link
        displayLinkProxy = proxy
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkProxy = nil
    }

    private func step(_ update: CAMetalDisplayLink.Update) {
        // Everything is placed for the moment this frame lights up, not for
        // now: the lid and the head keep moving in between.
        let shown = update.targetPresentationTimestamp
        let rawInterval = shown - lastFrameTime
        let dt = min(max(rawInterval, 1.0 / 240), 1.0 / 20)
        lastFrameTime = shown
        if let frame = streamer.newFrame() {
            overlay.absorb(frame)
        }
        let predicted = anglePredictor.angle(at: shown) ?? rawAngle
        let target = isClosingOut ? preferences.thresholdAngle : predicted
        advanceVisualAngle(to: target, dt: dt)
        advanceEye(now: shown, dt: dt)

        guard isClosingOut else {
            applyVisual(angle: visualAngle.value, drawable: update.drawable)
            return
        }
        // At or above the threshold the picture is already flat, so a lid
        // that opened past it finishes at once.
        let settled = visualAngle.value >= target - Self.closingOutSettleEpsilon
        let timedOut = CACurrentMediaTime() - closingOutStartedAt > Self.closingOutMaxDuration
        guard settled || timedOut else {
            applyVisual(angle: visualAngle.value, drawable: update.drawable)
            return
        }
        // The frame that fades out must match the screen behind it exactly,
        // so land on the threshold itself rather than just short of it.
        visualAngle.reset(to: target)
        applyVisual(angle: target, drawable: update.drawable)
        finishClosingOut()
    }

    /// A stiff spring needs sub-steps to stay stable through a slow frame.
    private func advanceVisualAngle(to target: Double, dt: Double) {
        let substeps = max(Int((visualAngle.frequency * dt / 0.5).rounded(.up)), 1)
        for _ in 0..<substeps {
            visualAngle.advance(to: target, dt: dt / Double(substeps))
        }
    }

    /// The geometry takes the lid angle itself, so only the blur saturates.
    private func applyVisual(angle: Double, drawable: CAMetalDrawable? = nil) {
        overlay.update(currentAngle: angle, eye: viewpoint.eye, tuning: tuning, drawable: drawable)
    }

    private var tuning: DepthTuning {
        DepthTuning(
            viewingDistance: preferences.viewingDistance,
            recession: preferences.recession,
            isGlassEnabled: preferences.isGlassEnabled,
            frost: preferences.frost,
            lightLoss: preferences.lightLoss,
            maxBlurRadius: preferences.maxBlurRadius,
            reflections: preferences.glassReflections
        )
    }

    // MARK: - Head tracking

    /// Head tracking is on, allowed, and not asked to hold still by Reduce
    /// Motion, which the parallax would otherwise defeat.
    private var followsFace: Bool {
        preferences.isHeadTrackingEnabled
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func refreshCameraAuthorization() {
        cameraAuthorization = FaceTracker.authorization
        refreshTrackingStatus()
    }

    /// Asks for the camera, from the settings panel. Never asked while the lid
    /// closes, so no prompt can appear under the effect.
    func requestCameraAccess() {
        Task { @MainActor in
            _ = await FaceTracker.requestAccess()
            self.refreshCameraAuthorization()
        }
    }

    private func centredEye(in room: LidGeometry) -> Vector3 {
        room.centredEye(startAngle: preferences.thresholdAngle, viewingDistance: preferences.viewingDistance)
    }

    /// A new run starts where the head was last seen, if that was recent:
    /// people sit in the same place, and the camera needs a moment to start.
    /// Otherwise it starts centred. Either way the first face found glides
    /// the eye over.
    private func beginViewpoint() {
        let geometry = NSScreen.builtIn?.lidGeometry
        room = geometry
        guard let geometry else { return }
        var start = centredEye(in: geometry)
        if followsFace, let remembered = lastTrackedEye,
           CACurrentMediaTime() - remembered.time < Self.rememberedEyeLifetime {
            start = remembered.position
        }
        viewpoint.reset(to: start)
    }

    /// Starts the camera once the lid is past the start angle and keeps it
    /// running until the lid shuts or the effect ends.
    private func updateCamera(angle: Double) {
        let wanted = cameraSchedule.wantsCamera(
            isTrackingEnabled: followsFace,
            isAuthorized: cameraAuthorization == .authorized,
            isEffectActive: isActive,
            isSuspended: isSuspended,
            angle: angle
        )
        if wanted, !isCameraRunning {
            isCameraRunning = true
            faceTracker.start()
            Diagnostics.tracking.notice("camera on at \(angle, format: .fixed(precision: 1))°")
        } else if !wanted, isCameraRunning {
            stopCamera()
            Diagnostics.tracking.notice("camera off at \(angle, format: .fixed(precision: 1))°")
        }
        refreshTrackingStatus()
    }

    private func stopCamera() {
        guard isCameraRunning else { return }
        if viewpoint.isFollowingFace {
            lastTrackedEye = (viewpoint.eye, CACurrentMediaTime())
        }
        isCameraRunning = false
        faceTracker.stop()
        faceTracker.setSearchHint(nil)
        refreshTrackingStatus()
    }

    /// Moves the eye one drawn frame along.
    ///
    /// The camera rides on the lid, so a face box only means something
    /// together with the angle the lid had when the frame was exposed. That
    /// angle comes from the sensor history at the frame's capture time, which
    /// takes the lid's own movement out of the face's movement in the
    /// picture. The other way round, the eye that results and the lid angle
    /// right now predict where the face will be in the next frame, and the
    /// detector searches there first.
    private func advanceEye(now: Double, dt: Double) {
        guard let room else { return }
        let centre = centredEye(in: room)
        var observed: (position: Vector3, time: Double)?
        if isCameraRunning, let face = faceTracker.latestFace(),
           now - face.timestamp < Self.faceFreshness,
           let cameraEye = eyeEstimator.eye(for: face) {
            let angleAtCapture = angleHistory.angle(at: face.timestamp) ?? rawAngle
            observed = (room.worldPoint(cameraMillimetres: cameraEye, angle: angleAtCapture), face.timestamp)
        }
        viewpoint.advance(now: now, dt: dt, observed: observed, centre: centre, followsFace: followsFace)

        if isCameraRunning {
            var hint: NormalisedRect?
            if viewpoint.isFollowingFace, let size = faceTracker.currentFrameSize() {
                hint = eyeEstimator.predictedBox(
                    eye: room.cameraPoint(world: viewpoint.eye, angle: rawAngle),
                    imageWidth: size.width,
                    imageHeight: size.height
                )?.expanded(by: Self.searchMargin)
            }
            faceTracker.setSearchHint(hint)
        }
        refreshTrackingStatus()
    }

    private func refreshTrackingStatus() {
        let status: TrackingStatus
        if !followsFace || cameraAuthorization != .authorized {
            status = .off
        } else if !isCameraRunning {
            status = .standby
        } else {
            switch viewpoint.state {
            case .acquiring, .tracking, .holding: status = .tracking
            case .returning: status = .returning
            case .centred: status = .searching
            }
        }
        if status != trackingStatus { trackingStatus = status }
    }

    /// How long a remembered head position is trusted, in seconds.
    private static let rememberedEyeLifetime: Double = 15 * 60
    /// A face box older than this is not used, in seconds.
    private static let faceFreshness: Double = 0.5
    /// The search region around the predicted face, as a multiple of its size.
    private static let searchMargin: Double = 2.6

    // MARK: - System events

    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend() }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // macOS posts this for backlight and colour changes too.
                let screen = NSScreen.builtIn
                let layout = Layout(displayID: screen?.displayID, frame: screen?.frame)
                guard layout != self.builtInLayout else {
                    Diagnostics.lid.notice("screen parameters changed, layout unchanged")
                    return
                }
                Diagnostics.lid.notice(
                    "screen parameters changed, layout now \(String(describing: layout), privacy: .public)"
                )
                self.builtInLayout = layout
                if self.isActive { self.setActive(false) }
                self.streamer.stop()
                self.streamer.invalidateFilter()
                Task { await self.streamer.warmFilter() }
                self.overlay.discardLive()
                self.snapshotter.discard()
                Task { await self.snapshotter.warmFilter() }
            }
        }
    }

    private func suspend() {
        Diagnostics.lid.notice("suspend")
        isSuspended = true
        stopEffectAndCapture()
    }

    private func resume() {
        Diagnostics.lid.notice("resume")
        isSuspended = false
        // A fresh baseline, so waking with a nearly shut lid does not read as
        // closing movement.
        lastChangedAngle = nil
        angularVelocity = 0
        lastClosingTime = -.greatestFiniteMagnitude
        motionIntent.reset()
        openDwell.reset()
        peakAngle = 0
        timeoutReferenceAngle = nil
        timeoutAwaitingRelease = false
        wasTimeoutEnabled = false
        isClosingOut = false
        angleHistory.reset()
        anglePredictor.reset()
        refreshCameraAuthorization()
        if let angle = sensor.angle() {
            rawAngle = angle
            visualAngle.reset(to: angle)
        }
        setPollInterval(Self.idlePollInterval)
    }
}

/// `CAMetalDisplayLink` wants an Objective-C delegate; this forwards its
/// callbacks, which arrive on the run loop the link was added to.
private final class MetalDisplayLinkProxy: NSObject, CAMetalDisplayLinkDelegate {
    private let handler: (CAMetalDisplayLink.Update) -> Void

    init(handler: @escaping (CAMetalDisplayLink.Update) -> Void) {
        self.handler = handler
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        handler(update)
    }
}
