import Foundation

/// A point or direction in world or model space, in screen points.
///
/// The standard library's `SIMD3` keeps this module free of Apple-only
/// frameworks, so the geometry is testable anywhere. The helpers are methods
/// rather than free functions, so they never collide with the `simd` module's
/// own `dot`, `cross` and `normalize` in files that import both.
public typealias Vector3 = SIMD3<Double>

public extension SIMD3 where Scalar == Double {
    func dot(_ other: Vector3) -> Double {
        x * other.x + y * other.y + z * other.z
    }

    func cross(_ other: Vector3) -> Vector3 {
        Vector3(
            y * other.z - z * other.y,
            z * other.x - x * other.z,
            x * other.y - y * other.x
        )
    }

    var length: Double { dot(self).squareRoot() }

    /// The zero vector stays zero.
    var normalized: Vector3 {
        let size = length
        return size > 0 ? self / size : self
    }
}

/// A rigid frame: an origin and three orthonormal axes.
public struct Frame3: Equatable {
    public var origin: Vector3
    public var xAxis: Vector3
    public var yAxis: Vector3
    public var zAxis: Vector3

    public init(origin: Vector3, xAxis: Vector3, yAxis: Vector3, zAxis: Vector3) {
        self.origin = origin
        self.xAxis = xAxis
        self.yAxis = yAxis
        self.zAxis = zAxis
    }

    /// A world point in this frame's coordinates.
    public func local(_ point: Vector3) -> Vector3 {
        let offset = point - origin
        return Vector3(offset.dot(xAxis), offset.dot(yAxis), offset.dot(zAxis))
    }

    /// A world direction in this frame's coordinates.
    public func localDirection(_ direction: Vector3) -> Vector3 {
        Vector3(direction.dot(xAxis), direction.dot(yAxis), direction.dot(zAxis))
    }

    /// A point in this frame's coordinates, back in world space.
    public func world(_ point: Vector3) -> Vector3 {
        origin + xAxis * point.x + yAxis * point.y + zAxis * point.z
    }

    /// The world-to-local transform as twelve floats, three rows of a 3x4
    /// matrix, so `local = rows * (world, 1)`. The renderer uploads these.
    public var worldToLocalRows: [Float] {
        let translation = Vector3(-origin.dot(xAxis), -origin.dot(yAxis), -origin.dot(zAxis))
        return [
            Float(xAxis.x), Float(xAxis.y), Float(xAxis.z), Float(translation.x),
            Float(yAxis.x), Float(yAxis.y), Float(yAxis.z), Float(translation.y),
            Float(zAxis.x), Float(zAxis.y), Float(zAxis.z), Float(translation.z),
        ]
    }
}
