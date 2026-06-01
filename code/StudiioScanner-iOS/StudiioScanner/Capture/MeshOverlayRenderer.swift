import Foundation
import ARKit
import RealityKit
import SwiftUI

/// Pre-extracted mesh data that's safe to pass between threads.
/// ARMeshAnchor's GPU buffers get recycled, so we must copy data immediately.
struct ExtractedMeshData: Sendable {
    let identifier: UUID
    let transform: simd_float4x4
    let positions: [SIMD3<Float>]
    let normals: [SIMD3<Float>]
    let indices: [UInt32]
    let classifications: [UInt8]    // Phase B: per-face classification (ARMeshClassification raw values)

    /// Extract mesh data from an ARMeshAnchor SYNCHRONOUSLY.
    /// Must be called on the same thread that received the anchor,
    /// before the GPU buffer gets recycled.
    init?(from anchor: ARMeshAnchor) {
        let geometry = anchor.geometry
        let vertexCount = geometry.vertices.count

        guard vertexCount > 0 else { return nil }

        self.identifier = anchor.identifier
        self.transform = anchor.transform

        // Copy vertices
        let vertexBuffer = geometry.vertices.buffer
        let vertexStride = geometry.vertices.stride
        let vertexOffset = geometry.vertices.offset

        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(vertexCount)

        for i in 0..<vertexCount {
            let byteOffset = vertexOffset + (vertexStride * i)
            let pointer = vertexBuffer.contents().advanced(by: byteOffset)
            let vertex = pointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
            positions.append(vertex)
        }
        self.positions = positions

        // Copy normals
        let normalBuffer = geometry.normals.buffer
        let normalStride = geometry.normals.stride
        let normalOffset = geometry.normals.offset

        var normals: [SIMD3<Float>] = []
        normals.reserveCapacity(geometry.normals.count)

        for i in 0..<geometry.normals.count {
            let byteOffset = normalOffset + (normalStride * i)
            let pointer = normalBuffer.contents().advanced(by: byteOffset)
            let normal = pointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
            normals.append(normal)
        }
        self.normals = normals

        // Copy face indices
        let faceCount = geometry.faces.count
        let facesBuffer = geometry.faces.buffer
        let faceBytesPerIndex = geometry.faces.bytesPerIndex
        let indexCountPerPrimitive = geometry.faces.indexCountPerPrimitive

        var indices: [UInt32] = []
        indices.reserveCapacity(faceCount * indexCountPerPrimitive)

        for i in 0..<(faceCount * indexCountPerPrimitive) {
            let byteOffset = faceBytesPerIndex * i
            let pointer = facesBuffer.contents().advanced(by: byteOffset)

            let index: UInt32
            switch faceBytesPerIndex {
            case 2:
                index = UInt32(pointer.assumingMemoryBound(to: UInt16.self).pointee)
            case 4:
                index = pointer.assumingMemoryBound(to: UInt32.self).pointee
            default:
                return nil
            }
            indices.append(index)
        }
        self.indices = indices

        // Phase B: Copy per-face mesh classification if available
        // ARGeometrySource for classification uses componentsPerVector=1, stride, offset like vertices
        if let classificationSource = geometry.classification {
            let classBuffer = classificationSource.buffer
            let classStride = classificationSource.stride
            let classOffset = classificationSource.offset
            let classCount = classificationSource.count
            var classificationValues: [UInt8] = []
            classificationValues.reserveCapacity(classCount)

            for i in 0..<classCount {
                let byteOffset = classOffset + (classStride * i)
                let pointer = classBuffer.contents().advanced(by: byteOffset)
                // Classification is stored as UInt8 (ARMeshClassification raw value)
                let value = pointer.assumingMemoryBound(to: UInt8.self).pointee
                classificationValues.append(value)
            }
            self.classifications = classificationValues
        } else {
            self.classifications = []
        }
    }
}

// MARK: - Detected Plane Anchor Data (Phase B)

/// Captured ARPlaneAnchor data for architectural surface detection
struct ExtractedPlaneData: Sendable {
    let identifier: UUID
    let transform: simd_float4x4
    let alignment: PlaneAlignment
    let classification: PlaneClassification
    let extentX: Float              // width in metres
    let extentZ: Float              // depth in metres
    let centerX: Float
    let centerZ: Float

    enum PlaneAlignment: String, Sendable, Codable {
        case horizontal
        case vertical
    }

    enum PlaneClassification: String, Sendable, Codable {
        case wall
        case floor
        case ceiling
        case table
        case seat
        case door
        case window
        case none
    }

    init(from anchor: ARPlaneAnchor) {
        self.identifier = anchor.identifier
        self.transform = anchor.transform
        self.alignment = anchor.alignment == .vertical ? .vertical : .horizontal
        self.extentX = anchor.planeExtent.width
        self.extentZ = anchor.planeExtent.height
        self.centerX = anchor.center.x
        self.centerZ = anchor.center.z

        switch anchor.classification {
        case .wall: self.classification = .wall
        case .floor: self.classification = .floor
        case .ceiling: self.classification = .ceiling
        case .table: self.classification = .table
        case .seat: self.classification = .seat
        case .door: self.classification = .door
        case .window: self.classification = .window
        default: self.classification = .none
        }
    }
}

/// Renders mesh data as the orange translucent mesh overlay
/// that gives the scanner its signature visual appearance.
@MainActor
final class MeshOverlayRenderer: ObservableObject {

    // MARK: - Properties

    private var meshEntities: [UUID: ModelEntity] = [:]
    private let rootEntity = Entity()

    // Orange mesh material matching our design system
    private var meshMaterial: RealityKit.Material {
        var material = UnlitMaterial()
        material.color = .init(
            tint: UIColor(
                red: 1.0,
                green: 0.55,
                blue: 0.0,
                alpha: 0.45
            )
        )
        material.blending = .transparent(opacity: .init(floatLiteral: 0.45))
        return material
    }

    // MARK: - Root Entity

    var meshRoot: Entity { rootEntity }
    var entityCount: Int { meshEntities.count }

    // MARK: - Mesh Updates (from pre-extracted data)

    func updateMesh(from data: ExtractedMeshData) {
        guard let meshResource = buildMeshResource(from: data) else { return }

        if let existingEntity = meshEntities[data.identifier] {
            existingEntity.model?.mesh = meshResource
            existingEntity.transform = Transform(matrix: data.transform)
        } else {
            let entity = ModelEntity(mesh: meshResource, materials: [meshMaterial])
            entity.transform = Transform(matrix: data.transform)
            meshEntities[data.identifier] = entity
            rootEntity.addChild(entity)
        }
    }

    func removeMesh(identifier: UUID) {
        guard let entity = meshEntities.removeValue(forKey: identifier) else { return }
        entity.removeFromParent()
    }

    func clearAllMeshes() {
        for (_, entity) in meshEntities {
            entity.removeFromParent()
        }
        meshEntities.removeAll()
    }

    // MARK: - Mesh Resource Builder (from safe copied data)

    private func buildMeshResource(from data: ExtractedMeshData) -> MeshResource? {
        var descriptor = MeshDescriptor(name: "ARMesh")
        descriptor.positions = MeshBuffer(data.positions)
        descriptor.normals = MeshBuffer(data.normals)
        descriptor.primitives = .triangles(data.indices)

        do {
            return try MeshResource.generate(from: [descriptor])
        } catch {
            return nil
        }
    }
}
