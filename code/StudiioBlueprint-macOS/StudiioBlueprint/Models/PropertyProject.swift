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

struct Room: Codable, Identifiable {
    let id: UUID
    var name: String
    var meshUSDZPath: String?
    var objects: [TaggedObject]
    var area: Double
    var photosPaths: [String]
    var verifiedDimensions: [VerifiedDimension]

    init(
        id: UUID = UUID(),
        name: String = "Room",
        meshUSDZPath: String? = nil,
        objects: [TaggedObject] = [],
        area: Double = 0,
        photosPaths: [String] = [],
        verifiedDimensions: [VerifiedDimension] = []
    ) {
        self.id = id
        self.name = name
        self.meshUSDZPath = meshUSDZPath
        self.objects = objects
        self.area = area
        self.photosPaths = photosPaths
        self.verifiedDimensions = verifiedDimensions
    }
}

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
