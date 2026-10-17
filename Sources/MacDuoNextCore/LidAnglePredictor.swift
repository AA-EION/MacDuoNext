import Foundation

/// Where the lid is at the moment a frame reaches the screen.
///
/// The hinge sensor refreshes about ten times a second. Drawn at its last
/// reading, the held picture trails the moving lid by up to a tenth of a
/// second plus the display's own latency, and it looks attached to the lid
/// instead of to the room. This fits a line through the recent changes of the
/// reading and carries it forward to the presentation time.
public struct LidAnglePredictor {
    /// Changes older than this do not inform the speed, in seconds.
    public var window: Double = 0.3
    /// With no change for this long the lid counts as still.
    public var stillAfter: Double = 0.25
    /// The furthest past the newest change the line is carried, in seconds.
    public var maximumLead: Double = 0.15

    private var changes: [(time: Double, angle: Double)] = []

    public init() {}

    public var latestAngle: Double? { changes.last?.angle }

    /// Records a reading. Repeats of the same value are not changes.
    public mutating func record(angle: Double, at time: Double) {
        if let last = changes.last, last.angle == angle { return }
        changes.append((time, angle))
        changes.removeAll { time - $0.time > window }
    }

    public mutating func reset() {
        changes.removeAll()
    }

    /// Degrees per second, from a least-squares line through the recent
    /// changes. Zero when the lid has stopped.
    public func velocity(at time: Double) -> Double {
        guard let last = changes.last, time - last.time < stillAfter else { return 0 }
        let recent = changes.filter { last.time - $0.time <= window }
        guard recent.count >= 2 else { return 0 }
        let count = Double(recent.count)
        let meanTime = recent.map(\.time).reduce(0, +) / count
        let meanAngle = recent.map(\.angle).reduce(0, +) / count
        var covariance = 0.0
        var variance = 0.0
        for change in recent {
            covariance += (change.time - meanTime) * (change.angle - meanAngle)
            variance += (change.time - meanTime) * (change.time - meanTime)
        }
        return variance > 1e-9 ? covariance / variance : 0
    }

    /// The angle at `time`, or `nil` before the first reading.
    public func angle(at time: Double) -> Double? {
        guard let last = changes.last else { return nil }
        let lead = min(max(time - last.time, 0), maximumLead)
        return last.angle + velocity(at: time) * lead
    }
}
