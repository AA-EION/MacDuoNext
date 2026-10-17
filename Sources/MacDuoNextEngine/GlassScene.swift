import Metal
import MacDuoNextCore
import os

/// Engine diagnostics. Read with:
///
///     log show --last 5m --predicate 'subsystem == "com.macduonext.app"'
enum EngineLog {
    static let render = Logger(subsystem: "com.macduonext.app", category: "engine")
}

/// The cover glass on the GPU: its mesh, and an acceleration structure over it
/// when the device can trace rays.
///
/// The slab is built once in its own model space and never moves; the kernel
/// takes each ray into that space instead. Only a new screen size rebuilds it.
final class GlassScene {
    let shape: GlassSlabMesh.Shape
    let normals: MTLBuffer
    let indices: MTLBuffer
    let triangleCount: Int
    /// `nil` on the analytic path.
    let accelerationStructure: MTLAccelerationStructure?

    init?(device: MTLDevice, queue: MTLCommandQueue, shape: GlassSlabMesh.Shape, buildsAccelerationStructure: Bool) {
        let mesh = GlassSlabMesh(shape: shape)
        guard mesh.triangleCount > 0,
              let positions = device.makeBuffer(
                  bytes: mesh.positions,
                  length: mesh.positions.count * MemoryLayout<Float>.stride,
                  options: .storageModeShared
              ),
              let normals = device.makeBuffer(
                  bytes: mesh.normals,
                  length: mesh.normals.count * MemoryLayout<Float>.stride,
                  options: .storageModeShared
              ),
              let indices = device.makeBuffer(
                  bytes: mesh.indices,
                  length: mesh.indices.count * MemoryLayout<UInt32>.stride,
                  options: .storageModeShared
              ) else { return nil }
        self.shape = shape
        self.normals = normals
        self.indices = indices
        triangleCount = mesh.triangleCount

        guard buildsAccelerationStructure else {
            accelerationStructure = nil
            return
        }
        let started = CFAbsoluteTimeGetCurrent()
        let geometry = MTLAccelerationStructureTriangleGeometryDescriptor()
        geometry.vertexBuffer = positions
        geometry.vertexStride = 3 * MemoryLayout<Float>.stride
        geometry.indexBuffer = indices
        geometry.indexType = .uint32
        geometry.triangleCount = mesh.triangleCount
        geometry.opaque = true

        let descriptor = MTLPrimitiveAccelerationStructureDescriptor()
        descriptor.geometryDescriptors = [geometry]
        let sizes = device.accelerationStructureSizes(descriptor: descriptor)
        guard let structure = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
              let scratch = device.makeBuffer(length: max(sizes.buildScratchBufferSize, 16), options: .storageModePrivate),
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeAccelerationStructureCommandEncoder() else { return nil }
        encoder.build(accelerationStructure: structure, descriptor: descriptor, scratchBuffer: scratch, scratchBufferOffset: 0)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else {
            EngineLog.render.error("acceleration structure build failed: \(String(describing: commands.error), privacy: .public)")
            return nil
        }
        accelerationStructure = structure
        EngineLog.render.notice(
            """
            glass acceleration structure: \(mesh.triangleCount) triangles, \
            \(sizes.accelerationStructureSize) bytes, \
            built in \((CFAbsoluteTimeGetCurrent() - started) * 1000, format: .fixed(precision: 1)) ms
            """
        )
    }
}
