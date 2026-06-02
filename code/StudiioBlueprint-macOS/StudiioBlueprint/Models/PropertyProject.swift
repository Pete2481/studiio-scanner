import Foundation

// Shared data model — identical to the iOS version.
// Both apps must speak the same format for .studiio bundles.

struct PropertyProject: Codable, Identifiable {
    let id: UUID
    var address: String?
    var capturedAt: Date
    var floors: [Floor]
    var outbuildings: [Outbuilding]
    var outdoorZones: [OutdoorZone]

    init(
        id: UUID = UUID(),
        address: String? = nil,
        capturedAt: Date = Date(),
        floors: [Floor] = [],
        outbuildings: [Outbuilding] = [],
        outdoorZones: [OutdoorZone] = []
    ) {
        self.id = id
        self.address = address
        self.capturedAt = capturedAt
        self.floors = floors
        self.outbuildings = outbuildings
        self.outdoorZones = outdoorZones
    }
}

struct Floor: Codable, Identifiable {
    let id: UUID
    var name: String
    var elevation: Double
    var rooms: [Room]
    var stairConnections: [StairLink]

    init(
        id: UUID = UUID(),
        name: String = "Ground",
        elevation: Double = 0,
        rooms: [Room] = [],
        stairConnections: [StairLink] = []
    ) {
        self.id = id
        self.name = name
        self.elevation = elevation
        self.rooms = rooms
        self.stairConnections = stairConnections
    }
}

struct Room: Identifiable {
    let id: UUID
    var name: String
    var meshUSDZPath: String?
    var objects: [TaggedObject]
    var area: Double
    var photosPaths: [String]
    var verifiedDimensions: [VerifiedDimension]

    // Architectural geometry from MeshObjectDetector
    var walls: [WallSegment]
    var openings: [DetectedOpening]
    var roomWidth: Double?
    var roomDepth: Double?
    var floorLevel: Double
    var ceilingLevel: Double?
    var wallAlignmentAngle: Double
    var floorPolygon: [PointXZ]

    init(
        id: UUID = UUID(),
        name: String = "Room",
        meshUSDZPath: String? = nil,
        objects: [TaggedObject] = [],
        area: Double = 0,
        photosPaths: [String] = [],
        verifiedDimensions: [VerifiedDimension] = [],
        walls: [WallSegment] = [],
        openings: [DetectedOpening] = [],
        roomWidth: Double? = nil,
        roomDepth: Double? = nil,
        floorLevel: Double = 0,
        ceilingLevel: Double? = nil,
        wallAlignmentAngle: Double = 0,
        floorPolygon: [PointXZ] = []
    ) {
        self.id = id
        self.name = name
        self.meshUSDZPath = meshUSDZPath
        self.objects = objects
        self.area = area
        self.photosPaths = photosPaths
        self.verifiedDimensions = verifiedDimensions
        self.walls = walls
        self.openings = openings
        self.roomWidth = roomWidth
        self.roomDepth = roomDepth
        self.floorLevel = floorLevel
        self.ceilingLevel = ceilingLevel
        self.wallAlignmentAngle = wallAlignmentAngle
        self.floorPolygon = floorPolygon
    }
}

// MARK: - Room Codable (backwards compatible — old bundles without wall data still decode)

extension Room: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, meshUSDZPath, objects, area, photosPaths, verifiedDimensions
        case walls, openings, roomWidth, roomDepth, floorLevel, ceilingLevel
        case wallAlignmentAngle, floorPolygon
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        meshUSDZPath = try c.decodeIfPresent(String.self, forKey: .meshUSDZPath)
        objects = try c.decode([TaggedObject].self, forKey: .objects)
        area = try c.decode(Double.self, forKey: .area)
        photosPaths = try c.decode([String].self, forKey: .photosPaths)
        verifiedDimensions = try c.decode([VerifiedDimension].self, forKey: .verifiedDimensions)
        walls = try c.decodeIfPresent([WallSegment].self, forKey: .walls) ?? []
        openings = try c.decodeIfPresent([DetectedOpening].self, forKey: .openings) ?? []
        roomWidth = try c.decodeIfPresent(Double.self, forKey: .roomWidth)
        roomDepth = try c.decodeIfPresent(Double.self, forKey: .roomDepth)
        floorLevel = try c.decodeIfPresent(Double.self, forKey: .floorLevel) ?? 0
        ceilingLevel = try c.decodeIfPresent(Double.self, forKey: .ceilingLevel)
        wallAlignmentAngle = try c.decodeIfPresent(Double.self, forKey: .wallAlignmentAngle) ?? 0
        floorPolygon = try c.decodeIfPresent([PointXZ].self, forKey: .floorPolygon) ?? []
    }
}

// MARK: - Wall Segment

struct WallSegment: Codable, Identifiable {
    let id: UUID
    var startX: Double
    var startZ: Double
    var endX: Double
    var endZ: Double
    var thickness: Double
    var length: Double
    var angle: Double
    var isExterior: Bool

    init(
        id: UUID = UUID(),
        startX: Double, startZ: Double,
        endX: Double, endZ: Double,
        thickness: Double, length: Double,
        angle: Double = 0,
        isExterior: Bool = false
    ) {
        self.id = id
        self.startX = startX
        self.startZ = startZ
        self.endX = endX
        self.endZ = endZ
        self.thickness = thickness
        self.length = length
        self.angle = angle
        self.isExterior = isExterior
    }
}

// MARK: - Detected Opening

struct DetectedOpening: Codable, Identifiable {
    let id: UUID
    var kind: OpeningKind
    var positionX: Double
    var positionZ: Double
    var width: Double
    var height: Double
    var sillHeight: Double
    var wallID: UUID?

    init(
        id: UUID = UUID(),
        kind: OpeningKind,
        positionX: Double, positionZ: Double,
        width: Double, height: Double = 2.04,
        sillHeight: Double = 0,
        wallID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.positionX = positionX
        self.positionZ = positionZ
        self.width = width
        self.height = height
        self.sillHeight = sillHeight
        self.wallID = wallID
    }
}

enum OpeningKind: String, Codable, CaseIterable {
    case standardDoor
    case doubleDoor
    case slidingDoor
    case garageDoor
    case pocketDoor
    case window
    case openingPassthrough
}

// MARK: - 2D Point

struct PointXZ: Codable {
    var x: Double
    var z: Double

    init(x: Double, z: Double) {
        self.x = x
        self.z = z
    }
}

// MARK: - Tagged Object

struct TaggedObject: Codable, Identifiable {
    let id: UUID
    var category: ObjectCategory
    var positionX: Float
    var positionY: Float
    var positionZ: Float
    var dimensionsX: Float
    var dimensionsY: Float
    var dimensionsZ: Float
    var source: TagSource
}

struct VerifiedDimension: Codable, Identifiable {
    let id: UUID
    var wallID: UUID
    var measuredLength: Double
    var originalLength: Double

    init(id: UUID = UUID(), wallID: UUID, measuredLength: Double, originalLength: Double) {
        self.id = id
        self.wallID = wallID
        self.measuredLength = measuredLength
        self.originalLength = originalLength
    }
}

struct StairLink: Codable, Identifiable {
    let id: UUID
    var fromFloorID: UUID
    var toFloorID: UUID
    var direction: StairDirection

    enum StairDirection: String, Codable {
        case up
        case down
    }
}

struct Outbuilding: Codable, Identifiable {
    let id: UUID
    var name: String
    var rooms: [Room]

    init(id: UUID = UUID(), name: String = "Outbuilding", rooms: [Room] = []) {
        self.id = id
        self.name = name
        self.rooms = rooms
    }
}

struct OutdoorZone: Codable, Identifiable {
    let id: UUID
    var name: String
    var type: OutdoorType
    var boundaryPolygonX: [Float]
    var boundaryPolygonY: [Float]
    var connectedFloorID: UUID?
    var elevation: Double

    init(
        id: UUID = UUID(),
        name: String = "",
        type: OutdoorType = .deck,
        boundaryPolygonX: [Float] = [],
        boundaryPolygonY: [Float] = [],
        connectedFloorID: UUID? = nil,
        elevation: Double = 0
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.boundaryPolygonX = boundaryPolygonX
        self.boundaryPolygonY = boundaryPolygonY
        self.connectedFloorID = connectedFloorID
        self.elevation = elevation
    }
}

enum OutdoorType: String, Codable, CaseIterable {
    case deck, balcony, alfresco, verandah, porch, patio, garden, driveway, carport, other
}

enum ObjectCategory: String, Codable, CaseIterable {
    case storage, refrigerator, stove, oven, dishwasher, table, sofa, chair, bed, sink
    case washerDryer, toilet, bathtub, fireplace, television, stairs
    case shower, vanity, kitchenBench, kitchenIsland, pantry, wardrobe, linenCupboard
    case laundryTub, rangehood, splitSystemAC, ceilingFan, pendant, downlight
    case powerPoint, lightSwitch, smokeAlarm, intercom, hotWaterUnit, solarPanel
    case skylight, nicheShelf, wallTV, barbecue, pool, spa, clothesLine, letterbox, custom

    var abbreviation: String {
        switch self {
        case .refrigerator: return "F"
        case .stove, .oven: return "OV"
        case .dishwasher: return "DW"
        case .washerDryer: return "W/D"
        case .toilet: return "WC"
        case .fireplace: return "FP"
        case .pantry: return "P'TRY"
        case .wardrobe: return "BIR"
        case .linenCupboard: return "LINEN"
        case .splitSystemAC: return "A/C"
        case .barbecue: return "BBQ"
        case .hotWaterUnit: return "HWU"
        default: return rawValue.uppercased()
        }
    }
}

enum TagSource: String, Codable {
    case autoRoomPlan, manualTap, voice, ai
}
