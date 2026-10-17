import Foundation

/// One face the detector found in one camera frame.
public struct FaceSighting: Equatable, Sendable {
    /// Normalised bounding box, origin at the bottom left of the picture, as
    /// Vision reports it.
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// Size of the frame in pixels.
    public var imageWidth: Double
    public var imageHeight: Double
    /// Host time of the capture, in seconds.
    public var timestamp: Double

    public init(
        x: Double, y: Double, width: Double, height: Double,
        imageWidth: Double, imageHeight: Double, timestamp: Double
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.timestamp = timestamp
    }
}

/// Turns a face box into the point between the eyes, in camera space.
///
/// A pinhole model: the box width against an average face width gives the
/// distance, and the box position gives the direction. Nothing is learned per
/// person, so the error is a few centimetres, which the parallax tolerates.
public struct EyeEstimator: Equatable {
    /// Horizontal field of view of the camera's full 16:9 picture. Built-in
    /// MacBook cameras sit between about 60 and 70 degrees. Narrower frames,
    /// such as 640 by 480, are taken as centre crops of it.
    public var horizontalFieldOfView: Double = 65 * .pi / 180
    /// Width of the face box Vision draws on an adult face, in millimetres.
    public var faceWidthMillimetres: Double = 145
    /// Height of the eyes inside the box, as a fraction from its bottom.
    public var eyeLine: Double = 0.62
    /// Estimates outside this range are detector mistakes.
    public var distanceRange: ClosedRange<Double> = 180...1600

    public init() {}

    /// Camera space in millimetres: x right of the picture, y up, z away from
    /// the lens. `nil` for a box that cannot be a face at a usable distance.
    public func eye(for face: FaceSighting) -> Vector3? {
        guard face.width > 0.01, face.imageWidth > 0, face.imageHeight > 0 else { return nil }
        let aspect = face.imageWidth / face.imageHeight
        let crop = min(aspect / (16.0 / 9.0), 1)
        let focal = face.imageWidth / 2 / (tan(horizontalFieldOfView / 2) * crop)
        let faceWidthPixels = face.width * face.imageWidth
        let distance = focal * faceWidthMillimetres / faceWidthPixels
        guard distanceRange.contains(distance) else { return nil }
        let centreX = (face.x + face.width / 2) * face.imageWidth - face.imageWidth / 2
        let centreY = (face.y + face.height * eyeLine) * face.imageHeight - face.imageHeight / 2
        return Vector3(centreX * distance / focal, centreY * distance / focal, distance)
    }
}

public extension EyeEstimator {
    /// Where a face whose eyes are at `eye` (camera space, millimetres)
    /// would appear in a frame: the inverse of `eye(for:)`, as a normalised
    /// box with the origin at the bottom left. `nil` behind the lens.
    func predictedBox(eye: Vector3, imageWidth: Double, imageHeight: Double) -> NormalisedRect? {
        guard eye.z > 1, imageWidth > 0, imageHeight > 0 else { return nil }
        let aspect = imageWidth / imageHeight
        let crop = min(aspect / (16.0 / 9.0), 1)
        let focal = imageWidth / 2 / (tan(horizontalFieldOfView / 2) * crop)
        let width = focal * faceWidthMillimetres / eye.z / imageWidth
        // Vision's boxes run a little taller than wide.
        let height = width * imageWidth / imageHeight * 1.1
        let centreX = (eye.x * focal / eye.z + imageWidth / 2) / imageWidth
        let eyeY = (eye.y * focal / eye.z + imageHeight / 2) / imageHeight
        return NormalisedRect(x: centreX - width / 2, y: eyeY - height * eyeLine, width: width, height: height)
    }
}

/// A rectangle in the unit square, origin bottom left.
public struct NormalisedRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Grown about its centre by `factor`, then clipped to the unit square.
    /// `nil` when nothing of it is left in the frame.
    public func expanded(by factor: Double, minimumSide: Double = 0.2) -> NormalisedRect? {
        let grownWidth = max(width * factor, minimumSide)
        let grownHeight = max(height * factor, minimumSide)
        let minX = max(x + width / 2 - grownWidth / 2, 0)
        let minY = max(y + height / 2 - grownHeight / 2, 0)
        let maxX = min(x + width / 2 + grownWidth / 2, 1)
        let maxY = min(y + height / 2 + grownHeight / 2, 1)
        guard maxX - minX > 0.05, maxY - minY > 0.05 else { return nil }
        return NormalisedRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Recent lid angles, so a camera frame can be placed with the angle the lid
/// had when it was captured rather than when it was processed.
///
/// The camera rides on the lid. While the lid moves, a frame that is 40 ms
/// old was taken from a camera a degree or two away from where it is now, and
/// using today's angle would read that as the head moving. Interpolating the
/// sensor history at the frame's capture time removes that displacement.
public struct LidAngleHistory {
    private var samples: [(time: Double, angle: Double)] = []
    public var capacity: Int

    public init(capacity: Int = 64) {
        self.capacity = capacity
    }

    public mutating func record(angle: Double, at time: Double) {
        if let last = samples.last, time <= last.time {
            samples.removeLast()
        }
        samples.append((time, angle))
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    public mutating func reset() {
        samples.removeAll()
    }

    /// The angle at `time`, interpolated between readings and held at the
    /// ends. `nil` before the first reading.
    public func angle(at time: Double) -> Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if time <= first.time { return first.angle }
        if time >= last.time { return last.angle }
        var low = 0
        var high = samples.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if samples[middle].time <= time { low = middle } else { high = middle }
        }
        let a = samples[low], b = samples[high]
        let span = b.time - a.time
        guard span > 0 else { return b.angle }
        return a.angle + (b.angle - a.angle) * (time - a.time) / span
    }
}

/// Where the eye is, for each frame the overlay draws.
///
/// While a face is in view the eye follows it, so the held picture stays put
/// in the room as the head moves. The camera delivers 30 sightings a second
/// and the display draws 60 to 120 frames, so between sightings the eye is
/// carried forward along the filtered head velocity: it moves on every frame
/// the display draws instead of stepping at the camera's rate. When the face is lost the eye keeps still
/// for a moment, in case the detector only blinked, and then drifts back to
/// the centred position as slowly as the settle allows. A critically damped
/// spring from rest eases in and out on its own, which keeps that drift calm.
public struct ViewpointController {

    public enum State: Equatable {
        /// No face yet; the eye sits at the centre.
        case centred
        /// Gliding from wherever it was onto a face just found.
        case acquiring
        case tracking
        /// The face went away recently; holding the last position.
        case holding
        /// Drifting back to the centre.
        case returning
    }

    /// How long a lost face is held before the drift starts, in seconds.
    public var holdDuration: Double = 0.6
    /// Spring frequency, radians per second, while following a face. High:
    /// the filter already removes the jitter, and the spring only rounds off
    /// the last corners, with about 2 / frequency seconds of lag.
    public var trackingFrequency: Double = 60
    /// How far past the newest sighting the head is extrapolated, at most.
    public var maximumLead: Double = 0.1
    /// While gliding onto a newly found face. A jump would break the illusion.
    public var acquiringFrequency: Double = 3.5
    /// How long the glide onto a face lasts before full tracking.
    public var acquiringDuration: Double = 0.8
    /// The drift back to centre. A critically damped spring is within 1 %
    /// after about 6.6 / frequency seconds, so this takes about 11 s.
    public var returningFrequency: Double = 0.6

    public private(set) var state: State = .centred
    public private(set) var eye: Vector3

    private var springs: [CriticallyDampedSpring]
    /// Positions are in points, so speeds are in points per second; a head
    /// moving normally runs at a few hundred.
    private var filter = OneEuroFilter3(minimumCutoff: 2.0, beta: 0.04, derivativeCutoff: 1.5)
    private var lastObservationTime: Double?
    private var lastSeen: Double = -.greatestFiniteMagnitude
    private var target: Vector3?
    private var stateSince: Double = 0

    public init(centre: Vector3) {
        eye = centre
        springs = [centre.x, centre.y, centre.z].map { CriticallyDampedSpring(value: $0) }
    }

    /// Back to the centre at once, for a new run of the effect.
    public mutating func reset(to centre: Vector3) {
        eye = centre
        for (index, value) in [centre.x, centre.y, centre.z].enumerated() {
            springs[index].reset(to: value)
        }
        filter.reset()
        lastObservationTime = nil
        lastSeen = -.greatestFiniteMagnitude
        target = nil
        state = .centred
    }

    /// - Parameters:
    ///   - observed: the newest tracked eye in world space and the time it
    ///     was captured, or `nil` when the detector has nothing.
    ///   - centre: where the eye goes without a face.
    ///   - followsFace: false while head tracking is off or Reduce Motion is
    ///     on; the eye then only ever drifts to the centre.
    @discardableResult
    public mutating func advance(
        now: Double,
        dt: Double,
        observed: (position: Vector3, time: Double)?,
        centre: Vector3,
        followsFace: Bool = true
    ) -> Vector3 {
        if followsFace, let observed, observed.time != lastObservationTime {
            lastObservationTime = observed.time
            target = filter.filter(observed.position, at: observed.time)
            lastSeen = now
            switch state {
            case .centred, .returning:
                enter(.acquiring, at: now)
            case .holding:
                enter(.tracking, at: now)
            case .acquiring, .tracking:
                break
            }
        }

        let sinceSeen = now - lastSeen
        switch state {
        case .acquiring where now - stateSince >= acquiringDuration:
            enter(.tracking, at: now)
        case .acquiring, .tracking:
            if !followsFace || sinceSeen > holdDuration / 2 {
                enter(.holding, at: now)
            }
        case .holding where !followsFace || sinceSeen > holdDuration:
            enter(.returning, at: now)
            filter.reset()
        default:
            break
        }

        let goal: Vector3
        let frequency: Double
        let head = filter.predicted(at: now, maxLead: maximumLead) ?? target ?? centre
        switch state {
        case .acquiring:
            goal = head
            frequency = acquiringFrequency
        case .tracking:
            goal = head
            frequency = trackingFrequency
        case .holding:
            goal = eye
            frequency = trackingFrequency
        case .returning, .centred:
            goal = centre
            frequency = returningFrequency
        }

        // Semi-implicit Euler is stable below frequency * dt = 2; substeps
        // keep a fast spring stable through a slow frame.
        let elapsed = min(max(dt, 0), 1.0 / 10)
        let substeps = max(Int((frequency * elapsed / 0.5).rounded(.up)), 1)
        let step = elapsed / Double(substeps)
        let components = [goal.x, goal.y, goal.z]
        for index in 0..<3 {
            springs[index].frequency = frequency
            for _ in 0..<substeps {
                springs[index].advance(to: components[index], dt: step)
            }
        }
        eye = Vector3(springs[0].value, springs[1].value, springs[2].value)
        if state == .returning, (eye - centre).length < 0.5,
           springs.allSatisfy({ abs($0.velocity) < 0.5 }) {
            state = .centred
        }
        return eye
    }

    public var isFollowingFace: Bool {
        state == .acquiring || state == .tracking || state == .holding
    }

    private mutating func enter(_ next: State, at now: Double) {
        guard state != next else { return }
        state = next
        stateSince = now
        // Holding means holding still, and the drift home starts from rest,
        // so it eases in and cannot overshoot.
        if next == .holding {
            for index in springs.indices { springs[index].velocity = 0 }
        }
    }
}

/// When the camera may run.
///
/// It starts only once the lid has closed past the start angle and the effect
/// is up, and it keeps looking for the face until the lid is shut, the effect
/// ends, or the person turns tracking off.
public struct CameraSchedule: Equatable {
    /// At or below this the lid counts as shut, in degrees.
    public var closedAngle: Double = 5

    public init() {}

    public func wantsCamera(
        isTrackingEnabled: Bool,
        isAuthorized: Bool,
        isEffectActive: Bool,
        isSuspended: Bool,
        angle: Double
    ) -> Bool {
        isTrackingEnabled && isAuthorized && isEffectActive && !isSuspended && angle > closedAngle
    }
}
