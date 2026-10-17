import Foundation

/// The room the effect happens in.
///
/// World axes, in screen points: the hinge runs along x through the origin,
/// y points up, and z points from the hinge towards the person at the
/// keyboard. The lid opens by `angle` degrees from the base: 0 is shut, 90 is
/// upright, a typical working angle is about 110.
///
/// Every lid pose is a `Frame3` whose x and y axes run along the screen
/// (x right, y up, both in points from the bottom-left pixel) and whose z axis
/// leaves the glass towards the viewer.
public struct LidGeometry: Equatable {

    /// The screen in points.
    public var screenSize: Size2
    /// Physical scale, from `CGDisplayScreenSize`. Points per millimetre.
    public var pointsPerMillimetre: Double

    /// The camera sits centred above the top row of pixels, this far up.
    public var cameraAboveScreenMillimetres: Double = 4.5

    /// Beyond this the picture would turn its face away from the glass.
    public static let maxSeparationDegrees: Double = 88

    public init(screenSize: Size2, pointsPerMillimetre: Double) {
        self.screenSize = screenSize
        self.pointsPerMillimetre = pointsPerMillimetre
    }

    /// The pose of the screen when the lid is open `angle` degrees.
    public func lidFrame(angle: Double) -> Frame3 {
        let radians = angle * .pi / 180
        return Frame3(
            origin: Vector3(-screenSize.width / 2, 0, 0),
            xAxis: Vector3(1, 0, 0),
            yAxis: Vector3(0, sin(radians), cos(radians)),
            zAxis: Vector3(0, -cos(radians), sin(radians))
        )
    }

    /// The angle the held picture stands at while the lid is at
    /// `currentAngle`.
    ///
    /// The picture is a sheet hinged at the bottom of the screen that turns
    /// back by `recession` degrees for each degree the lid has closed past
    /// `startAngle`. A recession of 1 leaves it exactly where the screen was
    /// at the start angle: frozen in the room.
    public func pictureAngle(startAngle: Double, currentAngle: Double, recession: Double) -> Double {
        let travel = max(startAngle - currentAngle, 0)
        let separation = min(recession * travel, Self.maxSeparationDegrees)
        return currentAngle + separation
    }

    /// Where the eye is assumed to be without head tracking: straight out from
    /// the middle of the screen as it stood at `startAngle`,
    /// `viewingDistance` screen heights away, at the height of that middle.
    public func centredEye(startAngle: Double, viewingDistance: Double) -> Vector3 {
        let radians = startAngle * .pi / 180
        let height = screenSize.height
        return Vector3(
            0,
            height / 2 * sin(radians),
            height / 2 * cos(radians) + height * viewingDistance
        )
    }

    /// The camera's optical centre at the given lid angle.
    public func cameraPosition(angle: Double) -> Vector3 {
        lidFrame(angle: angle).world(Vector3(
            screenSize.width / 2,
            screenSize.height + cameraAboveScreenMillimetres * pointsPerMillimetre,
            0
        ))
    }

    /// A camera-space position, in millimetres, as a world point.
    ///
    /// Camera space: `x` towards the right of the camera's own picture, `y`
    /// up the picture, `z` along the optical axis away from the lid. Facing
    /// the person, the camera's right is the screen's left, so x flips. The
    /// frames come unmirrored (`FaceTracker` turns mirroring off).
    public func worldPoint(cameraMillimetres point: Vector3, angle: Double) -> Vector3 {
        let lid = lidFrame(angle: angle)
        let scale = pointsPerMillimetre
        return cameraPosition(angle: angle)
            - lid.xAxis * (point.x * scale)
            + lid.yAxis * (point.y * scale)
            + lid.zAxis * (point.z * scale)
    }

    /// The inverse of `worldPoint(cameraMillimetres:angle:)`: where a world
    /// point sits in front of the camera with the lid at `angle`.
    public func cameraPoint(world point: Vector3, angle: Double) -> Vector3 {
        let lid = lidFrame(angle: angle)
        let offset = (point - cameraPosition(angle: angle)) / pointsPerMillimetre
        return Vector3(-offset.dot(lid.xAxis), offset.dot(lid.yAxis), offset.dot(lid.zAxis))
    }
}

/// A width and height, without CoreGraphics.
public struct Size2: Equatable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}
