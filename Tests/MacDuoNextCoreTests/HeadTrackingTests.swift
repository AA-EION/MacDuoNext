import Foundation
import Testing
@testable import MacDuoNextCore

struct LidGeometryTests {
    private let room = LidGeometry(screenSize: Size2(width: 1512, height: 982), pointsPerMillimetre: 5)

    @Test
    func testLidFrameIsOrthonormalAndOpensUpward() {
        for angle in [0.0, 45, 90, 110, 135] {
            let frame = room.lidFrame(angle: angle)
            #expect(abs(frame.xAxis.length - 1) < 1e-12)
            #expect(abs(frame.yAxis.length - 1) < 1e-12)
            #expect(abs(frame.zAxis.length - 1) < 1e-12)
            #expect(abs(frame.xAxis.dot(frame.yAxis)) < 1e-12)
            #expect(abs(frame.yAxis.dot(frame.zAxis)) < 1e-12)
            #expect((frame.xAxis.cross(frame.yAxis) - frame.zAxis).length < 1e-12)
        }
        // Upright, the glass faces the viewer.
        #expect((room.lidFrame(angle: 90).zAxis - Vector3(0, 0, 1)).length < 1e-12)
        // Shut, it faces the keyboard.
        #expect((room.lidFrame(angle: 0).zAxis - Vector3(0, -1, 0)).length < 1e-12)
    }

    @Test
    func testRecessionOfOneFreezesThePicture() {
        for angle in [90.0, 70, 40, 10] {
            #expect(room.pictureAngle(startAngle: 90, currentAngle: angle, recession: 1) == 90)
        }
        #expect(room.pictureAngle(startAngle: 90, currentAngle: 100, recession: 1) == 100)
        #expect(room.pictureAngle(startAngle: 90, currentAngle: 0, recession: 3) == LidGeometry.maxSeparationDegrees)
    }

    @Test
    func testCameraPointRoundTrips() {
        let point = Vector3(40, -25, 550)
        for angle in [100.0, 75, 30] {
            let world = room.worldPoint(cameraMillimetres: point, angle: angle)
            let back = room.cameraPoint(world: world, angle: angle)
            #expect((back - point).length < 1e-9)
        }
    }

    @Test
    func testAFixedHeadReadsTheSameAtAnyLidAngle() {
        // The camera rides on the lid, so the same head lands at different
        // camera points; converting each with its own angle must agree.
        let head = Vector3(30, 400, 2600)
        let at90 = room.cameraPoint(world: head, angle: 90)
        let at60 = room.cameraPoint(world: head, angle: 60)
        #expect((at90 - at60).length > 1)
        #expect((room.worldPoint(cameraMillimetres: at60, angle: 60) - head).length < 1e-9)
    }

    @Test
    func testCentredEyeIsInFrontOfTheScreenMiddle() {
        let eye = room.centredEye(startAngle: 90, viewingDistance: 3)
        #expect(abs(eye.x) < 1e-12)
        #expect(abs(eye.y - 491) < 1e-9)
        #expect(abs(eye.z - 982 * 3) < 1e-9)
    }

    @Test
    func testWorldToLocalRowsMatchLocal() {
        let frame = room.lidFrame(angle: 72)
        let rows = frame.worldToLocalRows.map(Double.init)
        let point = Vector3(120, 300, 80)
        let expected = frame.local(point)
        for row in 0..<3 {
            let value = rows[row * 4] * point.x + rows[row * 4 + 1] * point.y
                + rows[row * 4 + 2] * point.z + rows[row * 4 + 3]
            #expect(abs(value - expected[row]) < 1e-3)
        }
    }
}

struct GlassSlabMeshTests {
    private let shape = GlassSlabMesh.Shape.macBook(pictureSize: Size2(width: 1512, height: 982), pointsPerMillimetre: 5)

    @Test
    func testMeshIsConsistent() {
        let mesh = GlassSlabMesh(shape: shape)
        #expect(mesh.positions.count == mesh.normals.count)
        #expect(mesh.indices.count % 3 == 0)
        #expect(mesh.triangleCount > 100)
        #expect(mesh.indices.allSatisfy { Int($0) < mesh.vertexCount })
        for index in 0..<mesh.vertexCount {
            let n = Vector3(Double(mesh.normals[index * 3]), Double(mesh.normals[index * 3 + 1]), Double(mesh.normals[index * 3 + 2]))
            #expect(abs(n.length - 1) < 1e-5)
        }
    }

    @Test
    func testMeshStaysInsideTheSlabBounds() {
        let mesh = GlassSlabMesh(shape: shape)
        let bounds = shape.bounds
        for index in 0..<mesh.vertexCount {
            let x = Double(mesh.positions[index * 3])
            let y = Double(mesh.positions[index * 3 + 1])
            let z = Double(mesh.positions[index * 3 + 2])
            #expect(x >= bounds.minX - 1e-3 && x <= bounds.maxX + 1e-3)
            #expect(y >= bounds.minY - 1e-3 && y <= bounds.maxY + 1e-3)
            #expect(z >= -1e-4 && z <= shape.thickness + 1e-3)
        }
    }

    @Test
    func testTrianglesFaceOutward() {
        // Each face's winding normal agrees with its vertex normals.
        let mesh = GlassSlabMesh(shape: shape)
        func position(_ i: UInt32) -> Vector3 {
            let base = Int(i) * 3
            return Vector3(Double(mesh.positions[base]), Double(mesh.positions[base + 1]), Double(mesh.positions[base + 2]))
        }
        func normal(_ i: UInt32) -> Vector3 {
            let base = Int(i) * 3
            return Vector3(Double(mesh.normals[base]), Double(mesh.normals[base + 1]), Double(mesh.normals[base + 2]))
        }
        var disagreements = 0
        for t in 0..<mesh.triangleCount {
            let a = mesh.indices[t * 3], b = mesh.indices[t * 3 + 1], c = mesh.indices[t * 3 + 2]
            let face = (position(b) - position(a)).cross(position(c) - position(a))
            guard face.length > 1e-9 else { continue }
            let average = normal(a) + normal(b) + normal(c)
            if face.dot(average) <= 0 { disagreements += 1 }
        }
        #expect(disagreements == 0)
    }
}

struct EyeEstimatorTests {
    private let estimator = EyeEstimator()

    @Test
    func testPredictedBoxRoundTrips() throws {
        let eye = Vector3(60, -40, 600)
        let box = try #require(estimator.predictedBox(eye: eye, imageWidth: 1280, imageHeight: 720))
        let face = FaceSighting(
            x: box.x, y: box.y, width: box.width, height: box.height,
            imageWidth: 1280, imageHeight: 720, timestamp: 0
        )
        let back = try #require(estimator.eye(for: face))
        #expect((back - eye).length < 1e-6)
    }

    @Test
    func testCroppedFramesAgreeWithWideFrames() throws {
        // The same head, seen in a 4:3 centre crop of the 16:9 sensor.
        let eye = Vector3(0, 0, 700)
        let wide = try #require(estimator.predictedBox(eye: eye, imageWidth: 1280, imageHeight: 720))
        let narrow = try #require(estimator.predictedBox(eye: eye, imageWidth: 640, imageHeight: 480))
        // The crop keeps 75 % of the width, so the face fills more of it.
        #expect(abs(narrow.width * 0.75 - wide.width) < 1e-9)
    }

    @Test
    func testImplausibleBoxesAreRejected() {
        let tiny = FaceSighting(x: 0.5, y: 0.5, width: 0.011, height: 0.02, imageWidth: 640, imageHeight: 480, timestamp: 0)
        #expect(estimator.eye(for: tiny) == nil)
        let huge = FaceSighting(x: 0, y: 0, width: 1, height: 1, imageWidth: 640, imageHeight: 480, timestamp: 0)
        #expect(estimator.eye(for: huge) == nil)
    }

    @Test
    func testExpandedRectStaysInFrame() throws {
        let rect = NormalisedRect(x: 0.9, y: 0.9, width: 0.2, height: 0.2)
        let grown = try #require(rect.expanded(by: 2))
        #expect(grown.x >= 0 && grown.y >= 0)
        #expect(grown.x + grown.width <= 1 + 1e-12)
        #expect(grown.y + grown.height <= 1 + 1e-12)
        #expect(NormalisedRect(x: 3, y: 3, width: 0.1, height: 0.1).expanded(by: 2) == nil)
    }
}

struct LidAngleHistoryTests {
    @Test
    func testInterpolatesBetweenReadings() throws {
        var history = LidAngleHistory()
        history.record(angle: 90, at: 1.0)
        history.record(angle: 80, at: 1.1)
        history.record(angle: 60, at: 1.3)
        #expect(try #require(history.angle(at: 1.05)) == 85)
        #expect(abs(try #require(history.angle(at: 1.2)) - 70) < 1e-9)
        #expect(history.angle(at: 0.5) == 90)
        #expect(history.angle(at: 2) == 60)
    }

    @Test
    func testCapacityDropsOldest() {
        var history = LidAngleHistory(capacity: 3)
        for step in 0..<10 { history.record(angle: Double(step), at: Double(step)) }
        #expect(history.angle(at: 0) == 7)
    }

    @Test
    func testEmptyHistoryHasNoAngle() {
        #expect(LidAngleHistory().angle(at: 1) == nil)
    }
}

struct ViewpointControllerTests {
    private let centre = Vector3(0, 500, 3000)
    private let face = Vector3(200, 450, 2400)

    private func run(
        _ controller: inout ViewpointController,
        from start: Double,
        to end: Double,
        seeing position: Vector3?
    ) {
        var now = start
        var frame = 0
        while now < end {
            // A camera frame every other drawn frame.
            let observed = position.map { ($0, frame % 2 == 0 ? now : now - 1.0 / 60) }
            controller.advance(now: now, dt: 1.0 / 60, observed: observed, centre: centre)
            now += 1.0 / 60
            frame += 1
        }
    }

    @Test
    func testFollowsAFaceAndSettlesOnIt() {
        var controller = ViewpointController(centre: centre)
        run(&controller, from: 0, to: 3, seeing: face)
        #expect(controller.state == .tracking)
        #expect((controller.eye - face).length < 5)
    }

    @Test
    func testHoldsBrieflyThenReturnsSlowly() {
        var controller = ViewpointController(centre: centre)
        run(&controller, from: 0, to: 3, seeing: face)
        run(&controller, from: 3, to: 3.4, seeing: nil)
        #expect(controller.state == .holding)
        #expect((controller.eye - face).length < 10)

        run(&controller, from: 3.4, to: 5, seeing: nil)
        #expect(controller.state == .returning)
        // Slow: well short of the centre after a second and a half.
        let travelled = (controller.eye - face).length / (centre - face).length
        #expect(travelled > 0 && travelled < 0.5)

        run(&controller, from: 5, to: 25, seeing: nil)
        #expect((controller.eye - centre).length < 1)
        #expect(controller.state == .centred)
    }

    @Test
    func testReturnNeverOvershoots() {
        var controller = ViewpointController(centre: centre)
        run(&controller, from: 0, to: 3, seeing: face)
        var now = 3.0
        var previous = (controller.eye - centre).length
        while now < 25 {
            controller.advance(now: now, dt: 1.0 / 60, observed: nil, centre: centre)
            let distance = (controller.eye - centre).length
            #expect(distance <= previous + 1e-6)
            previous = distance
            now += 1.0 / 60
        }
    }

    @Test
    func testDisabledTrackingStaysCentred() {
        var controller = ViewpointController(centre: centre)
        var now = 0.0
        while now < 2 {
            controller.advance(now: now, dt: 1.0 / 60, observed: (face, now), centre: centre, followsFace: false)
            now += 1.0 / 60
        }
        #expect(controller.state == .centred)
        #expect((controller.eye - centre).length < 1e-9)
    }

    @Test
    func testAcquiringGlidesRatherThanJumps() {
        var controller = ViewpointController(centre: centre)
        controller.advance(now: 0, dt: 1.0 / 60, observed: (face, 0), centre: centre)
        #expect(controller.state == .acquiring)
        // One frame in, the eye has barely left the centre.
        #expect((controller.eye - centre).length < (face - centre).length * 0.05)
    }
}

struct CameraScheduleTests {
    private let schedule = CameraSchedule()

    @Test
    func testRunsOnlyWhileTheEffectIsUpAndTheLidIsOpen() {
        #expect(schedule.wantsCamera(isTrackingEnabled: true, isAuthorized: true, isEffectActive: true, isSuspended: false, angle: 60))
        #expect(!schedule.wantsCamera(isTrackingEnabled: true, isAuthorized: true, isEffectActive: false, isSuspended: false, angle: 60))
        #expect(!schedule.wantsCamera(isTrackingEnabled: true, isAuthorized: true, isEffectActive: true, isSuspended: false, angle: 3))
        #expect(!schedule.wantsCamera(isTrackingEnabled: false, isAuthorized: true, isEffectActive: true, isSuspended: false, angle: 60))
        #expect(!schedule.wantsCamera(isTrackingEnabled: true, isAuthorized: false, isEffectActive: true, isSuspended: false, angle: 60))
        #expect(!schedule.wantsCamera(isTrackingEnabled: true, isAuthorized: true, isEffectActive: true, isSuspended: true, angle: 60))
    }
}

struct OneEuroFilterTests {
    @Test
    func testSmoothsJitterButFollowsMotion() {
        var filter = OneEuroFilter(minimumCutoff: 1, beta: 0.02)
        var output = 0.0
        for step in 0..<120 {
            output = filter.filter(step % 2 == 0 ? 1 : -1, at: Double(step) / 30)
        }
        #expect(abs(output) < 0.3)

        filter.reset()
        for step in 0..<60 {
            output = filter.filter(Double(step) * 10, at: Double(step) / 30)
        }
        #expect(abs(output - 590) < 60)
    }
}
