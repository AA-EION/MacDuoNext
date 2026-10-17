import Foundation

/// Turns the sensor's 10 Hz steps into a value that changes smoothly at the
/// display refresh rate.
///
/// Semi-implicit Euler stays stable while `frequency * dt` is below 2. The
/// caller clamps `dt`.
public struct CriticallyDampedSpring {
    public var value: Double
    public var velocity: Double = 0

    /// Radians per second. Higher follows the target faster and smooths less.
    public var frequency: Double = 16

    public init(value: Double = 0, frequency: Double = 16) {
        self.frequency = frequency
        self.value = value
    }

    public mutating func advance(to target: Double, dt: Double) {
        let acceleration = frequency * frequency * (target - value) - 2 * frequency * velocity
        velocity += acceleration * dt
        value += velocity * dt
    }

    public mutating func reset(to newValue: Double) {
        value = newValue
        velocity = 0
    }
}
