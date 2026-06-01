import Foundation
import simd

// MARK: - Core Data Model
// This is the schema that everything downstream depends on.
// Both the iPhone scanner and Mac blueprint renderer speak this format.

struct PropertyProject: Codable, Identifiable {
    let id: UUID
    var address: String?
    var heroImagePath: String?
    var capturedAt: Date
    var floors: [Floor]
    var outbuildings: [Outbuilding]
    var outdoorZones: [OutdoorZone]

    init(
        id: UUID = UUID(),
        address: String? = nil,
        heroImagePath: String? = nil,
        capturedAt: Date = Date(),
        floors: [Floor] = [],
        outbuildings: [Outbuilding] = [],
        outdoorZones: [OutdoorZone] = []
    ) {
        self.id = id
        self.address = address
        self.heroImagePath = heroImagePath
        self.capturedAt = capturedAt
        self.floors = floors
        self.outbuildings = outbuildings
        self.outdoorZones = outdoorZones
    }
}

// MARK: - Floor

struct Floor: Codable, Identifiable {
    let id: UUID
    var name: String
    var elevation: Double           // metres above ground floor
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

// MARK: - Room

struct Room: Codable, Identifiable {
    let id: UUID
    var name: String
    var meshUSDZPath: String?       // relative path within .studiio bundle
    var objects: [TaggedObject]
    var area: Double                // m2
    var photosPaths: [String]       // relative paths
    var verifiedDimensions: [VerifiedDimension]

    // Phase A: Architectural geometry (walls, openings, dimensions)
    var walls: [WallSegment]
    var openings: [DetectedOpening]
    var roomWidth: Double?          // metres, from wall fitting
    var roomDepth: Double?          // metres, from wall fitting
    var floorLevel: Double          // metres, Y position of detected floor
    var ceilingLevel: Double?       // metres, Y position of detected ceiling
    var wallAlignmentAngle: Double  // radians, rotation applied to align walls to axes
    var floorPolygon: [PointXZ]     // 2D boundary polygon (X,Z coords in metres)

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

// MARK: - Wall Segment

struct WallSegment: Codable, Identifiable {
    let id: UUID
    var startX: Double
    var startZ: Double
    var endX: Double
    var endZ: Double
    var thickness: Double           // metres, detected from mesh
    var length: Double              // metres
    var angle: Double               // radians, orientation of wall
    var isExterior: Bool            // true if likely external wall (thicker)

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

// MARK: - Detected Opening (door, window, etc.)

struct DetectedOpening: Codable, Identifiable {
    let id: UUID
    var kind: OpeningKind
    var positionX: Double
    var positionZ: Double
    var width: Double               // metres
    var height: Double              // metres (estimated from mesh gap)
    var sillHeight: Double          // metres above floor (0 for doors, >0 for windows)
    var wallID: UUID?               // reference to parent wall

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
    case standardDoor       // 700-1000mm
    case doubleDoor         // 1200-1800mm
    case slidingDoor        // 1500-2400mm
    case garageDoor         // 2400mm+
    case pocketDoor         // standard width + wall cavity detected
    case window             // has sill
    case openingPassthrough // no door frame detected
}

// MARK: - 2D Point (floor plan coordinates)

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

    var position: SIMD3<Float> {
        get { SIMD3(positionX, positionY, positionZ) }
        set { positionX = newValue.x; positionY = newValue.y; positionZ = newValue.z }
    }

    var dimensions: SIMD3<Float> {
        get { SIMD3(dimensionsX, dimensionsY, dimensionsZ) }
        set { dimensionsX = newValue.x; dimensionsY = newValue.y; dimensionsZ = newValue.z }
    }
}

// MARK: - Verified Dimension

struct VerifiedDimension: Codable, Identifiable {
    let id: UUID
    var wallID: UUID
    var measuredLength: Double      // metres, from tape measure
    var originalLength: Double      // metres, from scan

    init(id: UUID = UUID(), wallID: UUID, measuredLength: Double, originalLength: Double) {
        self.id = id
        self.wallID = wallID
        self.measuredLength = measuredLength
        self.originalLength = originalLength
    }
}

// MARK: - Stair Link

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

// MARK: - Outbuilding

struct Outbuilding: Codable, Identifiable {
    let id: UUID
    var name: String                // "Garage", "Granny Flat", "Shed"
    var rooms: [Room]

    init(id: UUID = UUID(), name: String = "Outbuilding", rooms: [Room] = []) {
        self.id = id
        self.name = name
        self.rooms = rooms
    }
}

// MARK: - Outdoor Zone

struct OutdoorZone: Codable, Identifiable {
    let id: UUID
    var name: String
    var type: OutdoorType
    var boundaryPolygonX: [Float]   // paired with Y for 2D polygon
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

// MARK: - Enums

enum OutdoorType: String, Codable, CaseIterable {
    case deck
    case balcony
    case alfresco
    case verandah
    case porch
    case patio
    case garden
    case driveway
    case carport
    case other
}

enum ObjectCategory: String, Codable, CaseIterable {
    // RoomPlan auto-detected (16)
    case storage
    case refrigerator
    case stove
    case oven
    case dishwasher
    case table
    case sofa
    case chair
    case bed
    case sink
    case washerDryer
    case toilet
    case bathtub
    case fireplace
    case television
    case stairs

    // Studiio additions for AUS real estate
    case shower
    case vanity
    case kitchenBench
    case kitchenIsland
    case pantry
    case wardrobe
    case linenCupboard
    case laundryTub
    case rangehood
    case splitSystemAC
    case ceilingFan
    case pendant
    case downlight
    case powerPoint
    case lightSwitch
    case smokeAlarm
    case intercom
    case hotWaterUnit
    case solarPanel
    case skylight
    case nicheShelf
    case wallTV
    case barbecue
    case pool
    case spa
    case clothesLine
    case letterbox
    case custom

    var abbreviation: String {
        switch self {
        case .storage: return "STOR"
        case .refrigerator: return "F"
        case .stove: return "OV"
        case .oven: return "OV"
        case .dishwasher: return "DW"
        case .washerDryer: return "W/D"
        case .toilet: return "WC"
        case .bathtub: return "BATH"
        case .fireplace: return "FP"
        case .television: return "TV"
        case .stairs: return "STAIRS"
        case .shower: return "SHR"
        case .vanity: return "VAN"
        case .kitchenBench: return "BENCH"
        case .kitchenIsland: return "ISLAND"
        case .pantry: return "P'TRY"
        case .wardrobe: return "BIR"
        case .linenCupboard: return "LINEN"
        case .laundryTub: return "TUB"
        case .rangehood: return "RH"
        case .splitSystemAC: return "A/C"
        case .ceilingFan: return "FAN"
        case .hotWaterUnit: return "HWU"
        case .barbecue: return "BBQ"
        case .pool: return "POOL"
        default: return rawValue.uppercased()
        }
    }
}

enum TagSource: String, Codable {
    case autoRoomPlan
    case manualTap
    case voice
    case ai
}
