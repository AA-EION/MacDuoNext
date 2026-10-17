import Foundation

/// The 1€ filter (Casiez, Roussel, Vogel, CHI 2012).
///
/// A low-pass filter whose cutoff rises with speed: a head held still is
/// smoothed hard, so detector jitter disappears, while a head that moves is
/// followed with little lag. One multiply-add per sample.
public struct OneEuroFilter {
    /// Cutoff while still, in hertz. Lower smooths more.
    public var minimumCutoff: Double
    /// How fast the cutoff rises with speed. Higher lags less.
    public var beta: Double
    /// Cutoff for the speed estimate itself, in hertz.
    public var derivativeCutoff: Double

    private var value: Double?
    private var derivative: Double = 0
    private var lastTime: Double?

    public init(minimumCutoff: Double = 1.0, beta: Double = 0.02, derivativeCutoff: Double = 1.0) {
        self.minimumCutoff = minimumCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    public var current: Double? { value }

    public mutating func filter(_ sample: Double, at time: Double) -> Double {
        guard let previous = value, let lastTime, time > lastTime else {
            value = sample
            self.lastTime = time
            return sample
        }
        let dt = time - lastTime
        self.lastTime = time
        let rawDerivative = (sample - previous) / dt
        derivative += Self.alpha(cutoff: derivativeCutoff, dt: dt) * (rawDerivative - derivative)
        let cutoff = minimumCutoff + beta * abs(derivative)
        let filtered = previous + Self.alpha(cutoff: cutoff, dt: dt) * (sample - previous)
        value = filtered
        return filtered
    }

    public mutating func reset() {
        value = nil
        derivative = 0
        lastTime = nil
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}

/// Three 1€ filters, one per axis.
public struct OneEuroFilter3 {
    private var axes: [OneEuroFilter]

    public init(minimumCutoff: Double, beta: Double, derivativeCutoff: Double = 1.0) {
        axes = Array(
            repeating: OneEuroFilter(minimumCutoff: minimumCutoff, beta: beta, derivativeCutoff: derivativeCutoff),
            count: 3
        )
    }

    public mutating func filter(_ sample: Vector3, at time: Double) -> Vector3 {
        Vector3(
            axes[0].filter(sample.x, at: time),
            axes[1].filter(sample.y, at: time),
            axes[2].filter(sample.z, at: time)
        )
    }

    public mutating func reset() {
        for index in axes.indices { axes[index].reset() }
    }
}
