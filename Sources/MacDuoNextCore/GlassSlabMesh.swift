import Foundation

/// The cover glass of the held picture, as triangles for the ray tracer.
///
/// Model space, in points: the picture covers `0...width` by `0...height` at
/// `z = 0`, which is also the back face of the glass, bonded to the panel.
/// The front face is at `z = thickness`. In plan the slab is a rounded
/// rectangle a bezel wider than the picture; its front edge rolls over in a
/// quarter circle, the way a real cover glass is polished, and that roll is
/// what catches the light.
public struct GlassSlabMesh {

    public struct Shape: Equatable {
        public var pictureSize: Size2
        /// Glass beyond the picture on the left, right and top.
        public var bezel: Double
        /// Glass beyond the picture below it, down to the hinge side.
        public var bottomBezel: Double
        public var cornerRadius: Double
        public var thickness: Double
        /// Radius of the rolled front edge. Clamped to the thickness and the
        /// corner radius.
        public var edgeRadius: Double
        public var cornerSegments: Int = 12
        public var edgeSegments: Int = 6

        public init(
            pictureSize: Size2,
            bezel: Double,
            bottomBezel: Double,
            cornerRadius: Double,
            thickness: Double,
            edgeRadius: Double
        ) {
            self.pictureSize = pictureSize
            self.bezel = bezel
            self.bottomBezel = bottomBezel
            self.cornerRadius = cornerRadius
            self.thickness = thickness
            self.edgeRadius = edgeRadius
        }

        /// A shape in proportion to a real MacBook display.
        public static func macBook(pictureSize: Size2, pointsPerMillimetre: Double) -> Shape {
            let mm = max(pointsPerMillimetre, 0.1)
            return Shape(
                pictureSize: pictureSize,
                bezel: 5 * mm,
                bottomBezel: 3 * mm,
                cornerRadius: 10 * mm,
                // Exaggerated about threefold over the real glass so the
                // refraction reads at arm's length.
                thickness: 2.2 * mm,
                edgeRadius: 1.6 * mm
            )
        }

        /// Plan-view bounds of the slab: min x, min y, max x, max y.
        public var bounds: (minX: Double, minY: Double, maxX: Double, maxY: Double) {
            (-bezel, -bottomBezel, pictureSize.width + bezel, pictureSize.height + bezel)
        }
    }

    /// Packed x, y, z per vertex.
    public private(set) var positions: [Float] = []
    /// Packed unit normals, matching `positions`.
    public private(set) var normals: [Float] = []
    /// Three per triangle.
    public private(set) var indices: [UInt32] = []

    public var vertexCount: Int { positions.count / 3 }
    public var triangleCount: Int { indices.count / 3 }

    public init(shape: Shape) {
        build(shape)
    }

    // MARK: - Construction

    private mutating func build(_ shape: Shape) {
        let bounds = shape.bounds
        let halfWidth = (bounds.maxX - bounds.minX) / 2
        let halfHeight = (bounds.maxY - bounds.minY) / 2
        let centre = (x: bounds.minX + halfWidth, y: bounds.minY + halfHeight)
        let corner = max(min(shape.cornerRadius, halfWidth, halfHeight), 0.001)
        let thickness = max(shape.thickness, 0.001)
        let edge = max(min(shape.edgeRadius, thickness, corner * 0.999), 0.0005)
        let cornerSegments = max(shape.cornerSegments, 1)
        let edgeSegments = max(shape.edgeSegments, 1)

        // One trip around the outline: per point, the arc centre and the
        // outward direction. Insetting along the direction keeps it a rounded
        // rectangle with a smaller radius.
        var outline: [(cx: Double, cy: Double, dx: Double, dy: Double)] = []
        let arcCentres = [
            (halfWidth - corner, -(halfHeight - corner), -Double.pi / 2),  // bottom right
            (halfWidth - corner, halfHeight - corner, 0.0),                // top right
            (-(halfWidth - corner), halfHeight - corner, Double.pi / 2),   // top left
            (-(halfWidth - corner), -(halfHeight - corner), Double.pi),    // bottom left
        ]
        for (cx, cy, start) in arcCentres {
            for step in 0...cornerSegments {
                let angle = start + Double(step) / Double(cornerSegments) * (Double.pi / 2)
                outline.append((centre.x + cx, centre.y + cy, cos(angle), sin(angle)))
            }
        }
        let ringSize = outline.count

        func ring(inset: Double, z: Double, normalXY: Double, normalZ: Double) -> UInt32 {
            let first = UInt32(vertexCount)
            for point in outline {
                let radius = corner - inset
                append(
                    position: (point.cx + point.dx * radius, point.cy + point.dy * radius, z),
                    normal: (point.dx * normalXY, point.dy * normalXY, normalZ)
                )
            }
            return first
        }

        // The rolled front edge, from the flat top (phi 0) to the side wall
        // (phi pi/2).
        var profileRings: [UInt32] = []
        for step in 0...edgeSegments {
            let phi = Double(step) / Double(edgeSegments) * (Double.pi / 2)
            profileRings.append(ring(
                inset: edge * (1 - sin(phi)),
                z: thickness - edge + edge * cos(phi),
                normalXY: sin(phi),
                normalZ: cos(phi)
            ))
        }
        let wallBottom = ring(inset: 0, z: 0, normalXY: 1, normalZ: 0)
        let frontRing = ring(inset: edge, z: thickness, normalXY: 0, normalZ: 1)
        let backRing = ring(inset: 0, z: 0, normalXY: 0, normalZ: -1)

        let frontCentre = UInt32(vertexCount)
        append(position: (centre.x, centre.y, thickness), normal: (0, 0, 1))
        let backCentre = UInt32(vertexCount)
        append(position: (centre.x, centre.y, 0), normal: (0, 0, -1))

        // Outward winding: counter-clockwise seen from outside.
        func strip(_ upper: UInt32, _ lower: UInt32) {
            for index in 0..<ringSize {
                let next = (index + 1) % ringSize
                let a = upper + UInt32(index), b = upper + UInt32(next)
                let c = lower + UInt32(index), d = lower + UInt32(next)
                indices += [a, c, d, a, d, b]
            }
        }
        for pair in zip(profileRings, profileRings.dropFirst()) {
            strip(pair.0, pair.1)
        }
        if let side = profileRings.last {
            strip(side, wallBottom)
        }
        for index in 0..<ringSize {
            let next = (index + 1) % ringSize
            indices += [frontCentre, frontRing + UInt32(index), frontRing + UInt32(next)]
            indices += [backCentre, backRing + UInt32(next), backRing + UInt32(index)]
        }
    }

    private mutating func append(
        position: (Double, Double, Double),
        normal: (Double, Double, Double)
    ) {
        positions += [Float(position.0), Float(position.1), Float(position.2)]
        let length = (normal.0 * normal.0 + normal.1 * normal.1 + normal.2 * normal.2).squareRoot()
        let scale = length > 0 ? 1 / length : 0
        normals += [Float(normal.0 * scale), Float(normal.1 * scale), Float(normal.2 * scale)]
    }
}
