#!/usr/bin/env swift
//
// calibrate.swift
// Compares a .studiio scan against ground truth for 3 Fagan Place Cumbalum.
// Auto-detects which room was scanned based on dimensions, then compares
// every feature (walls, doors, windows, objects) against the real plan.
//
// Usage: swift calibrate.swift /path/to/scan.studiio [room_name]
//        swift calibrate.swift /path/to/scan.studiio living+family+dining+entry
//        Room name is optional — auto-detected from dimensions if omitted.
//        Use + to combine multiple rooms for multi-room scans.
//

import Foundation
import simd

// ============================================================================
// MARK: - Ground Truth (loaded from JSON)
// ============================================================================

struct RoomGT {
    var name: String
    var width_mm: Float
    var depth_mm: Float
    var area_m2: Float
    var doors: [(name: String, width_mm: Float, type: String)]
    var windows: [(name: String, width_mm: Float, type: String, label: String)]
    var openings: [(name: String, width_mm: Float)]
    var fixtures: [(name: String, category: String, width_mm: Float, depth_mm: Float)]
}

func loadGroundTruth() -> [String: RoomGT] {
    let toolsDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    let gtURL = toolsDir.appendingPathComponent("ground-truth.json")

    guard let data = try? Data(contentsOf: gtURL),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rooms = json["rooms"] as? [String: Any] else {
        print("WARNING: Could not load ground-truth.json from \(gtURL.path)")
        return [:]
    }

    var result: [String: RoomGT] = [:]

    for (key, val) in rooms {
        guard let room = val as? [String: Any] else { continue }
        let name = room["name"] as? String ?? key
        let width = (room["width_mm"] as? NSNumber)?.floatValue ?? 0
        let depth = (room["depth_mm"] as? NSNumber)?.floatValue ?? 0
        let area = (room["area_m2"] as? NSNumber)?.floatValue ?? 0

        var doors: [(String, Float, String)] = []
        if let dd = room["doors"] as? [[String: Any]] {
            for d in dd {
                doors.append((
                    d["name"] as? String ?? "",
                    (d["width_mm"] as? NSNumber)?.floatValue ?? 0,
                    d["type"] as? String ?? "standard"
                ))
            }
        }

        var windows: [(String, Float, String, String)] = []
        if let ww = room["windows"] as? [[String: Any]] {
            for w in ww {
                windows.append((
                    w["name"] as? String ?? "",
                    (w["width_mm"] as? NSNumber)?.floatValue ?? 0,
                    w["type"] as? String ?? "",
                    w["label"] as? String ?? ""
                ))
            }
        }

        var openings: [(String, Float)] = []
        if let oo = room["openings"] as? [[String: Any]] {
            for o in oo {
                openings.append((
                    o["name"] as? String ?? "",
                    (o["width_mm"] as? NSNumber)?.floatValue ?? 0
                ))
            }
        }

        var fixtures: [(String, String, Float, Float)] = []
        if let ff = room["fixtures"] as? [[String: Any]] {
            for f in ff {
                fixtures.append((
                    f["name"] as? String ?? "",
                    f["category"] as? String ?? "",
                    (f["width_mm"] as? NSNumber)?.floatValue ?? 0,
                    (f["depth_mm"] as? NSNumber)?.floatValue ?? 0
                ))
            }
        }

        result[key] = RoomGT(name: name, width_mm: width, depth_mm: depth, area_m2: area,
                             doors: doors, windows: windows, openings: openings, fixtures: fixtures)
    }

    return result
}

/// Find best matching room by comparing measured dimensions
func identifyRoom(measuredWidth: Float, measuredDepth: Float, rooms: [String: RoomGT]) -> (String, RoomGT)? {
    var bestMatch: (String, RoomGT)?
    var bestScore: Float = .greatestFiniteMagnitude

    for (key, room) in rooms {
        // Try both orientations (width/depth might be swapped)
        let score1 = abs(measuredWidth - room.width_mm) + abs(measuredDepth - room.depth_mm)
        let score2 = abs(measuredWidth - room.depth_mm) + abs(measuredDepth - room.width_mm)
        let score = min(score1, score2)

        if score < bestScore {
            bestScore = score
            bestMatch = (key, room)
        }
    }

    // Only match if within 500mm total error
    if bestScore < 500 {
        return bestMatch
    }
    return nil
}

/// Combine multiple rooms into a single ground truth for multi-room scans.
/// Areas are summed, feature lists are concatenated, and dimensions are skipped
/// (bounding box from the scan is used instead of individual room dims).
func combineRooms(keys: [String], rooms: [String: RoomGT]) -> RoomGT? {
    var combined = RoomGT(name: "", width_mm: 0, depth_mm: 0, area_m2: 0,
                          doors: [], windows: [], openings: [], fixtures: [])
    var names: [String] = []

    for key in keys {
        guard let room = rooms[key] else {
            print("ERROR: Unknown room '\(key)'. Available: \(rooms.keys.sorted().joined(separator: ", "))")
            return nil
        }
        names.append(room.name)
        combined.area_m2 += room.area_m2
        combined.doors += room.doors
        combined.windows += room.windows
        combined.openings += room.openings
        combined.fixtures += room.fixtures
    }

    combined.name = names.joined(separator: " + ")
    // width/depth left at 0 — multi-room uses bounding box from scan, not GT dims
    return combined
}

// ============================================================================
// MARK: - Mesh Reader
// ============================================================================

struct MeshAnchor {
    let transform: simd_float4x4
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var indices: [UInt32]
}

func readMeshBinary(from url: URL) -> MeshAnchor? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return data.withUnsafeBytes { raw -> MeshAnchor? in
        guard let base = raw.baseAddress else { return nil }
        var off = 0
        func rf() -> Float { var f: Float = 0; memcpy(&f, base.advanced(by: off), 4); off += 4; return f }
        func ru() -> UInt32 { var u: UInt32 = 0; memcpy(&u, base.advanced(by: off), 4); off += 4; return u }
        var fl: [Float] = []; for _ in 0..<16 { fl.append(rf()) }
        let t = simd_float4x4(
            SIMD4<Float>(fl[0],fl[1],fl[2],fl[3]), SIMD4<Float>(fl[4],fl[5],fl[6],fl[7]),
            SIMD4<Float>(fl[8],fl[9],fl[10],fl[11]), SIMD4<Float>(fl[12],fl[13],fl[14],fl[15]))
        let vc = Int(ru()); guard off + vc * 16 <= data.count else { return nil }
        var pos: [SIMD3<Float>] = []; for _ in 0..<vc { let x=rf(),y=rf(),z=rf(); _=rf(); pos.append(SIMD3(x,y,z)) }
        let nc = Int(ru()); guard off + nc * 16 <= data.count else { return nil }
        var nrm: [SIMD3<Float>] = []; for _ in 0..<nc { let x=rf(),y=rf(),z=rf(); _=rf(); nrm.append(SIMD3(x,y,z)) }
        let ic = Int(ru()); guard off + ic * 4 <= data.count else { return nil }
        var idx: [UInt32] = []; for _ in 0..<ic { idx.append(ru()) }
        return MeshAnchor(transform: t, positions: pos, normals: nrm, indices: idx)
    }
}

// ============================================================================
// MARK: - Scan Processing
// ============================================================================

struct ScanMeasurements {
    var vertices: Int = 0
    var anchors: Int = 0
    var floorY: Float = 0
    var ceilingY: Float = 0
    var measuredWidth_mm: Float = 0
    var measuredDepth_mm: Float = 0
    var wallCount: Int = 0
    var openings: [(kind: String, width_mm: Float)] = []
    var objects: [(category: String, width_mm: Float, depth_mm: Float, height_mm: Float)] = []
    var floorCoverage: Float = 0
}

func processScan(meshDir: URL) -> ScanMeasurements {
    var m = ScanMeasurements()

    let indexURL = meshDir.appendingPathComponent("index.json")
    guard let indexData = try? Data(contentsOf: indexURL),
          let indexJSON = try? JSONSerialization.jsonObject(with: indexData) as? [String: Any],
          let anchors = indexJSON["anchors"] as? [[String: Any]] else { return m }

    m.anchors = anchors.count
    var allVerts: [(pos: SIMD3<Float>, normal: SIMD3<Float>)] = []

    for info in anchors {
        guard let fn = info["file"] as? String,
              let anchor = readMeshBinary(from: meshDir.appendingPathComponent(fn)) else { continue }
        let t = anchor.transform
        for i in 0..<min(anchor.positions.count, anchor.normals.count) {
            let p = anchor.positions[i]
            let wp = t * SIMD4<Float>(p.x, p.y, p.z, 1.0)
            let n = anchor.normals[i]
            let wn = t * SIMD4<Float>(n.x, n.y, n.z, 0.0)
            allVerts.append((pos: SIMD3(wp.x, wp.y, wp.z), normal: normalize(SIMD3(wn.x, wn.y, wn.z))))
        }
    }
    m.vertices = allVerts.count

    // Floor / ceiling
    var floorC: [Float] = []
    for v in allVerts where v.normal.y > 0.8 { floorC.append(v.pos.y) }
    floorC.sort()
    m.floorY = floorC.count > 100 ? floorC[floorC.count / 10] : (floorC.first ?? 0)

    var ceilC: [Float] = []
    for v in allVerts where v.normal.y < -0.8 && v.pos.y > m.floorY + 1.5 { ceilC.append(v.pos.y) }
    ceilC.sort()
    m.ceilingY = ceilC.count > 50 ? ceilC[ceilC.count * 9 / 10] : m.floorY + 2.4

    // Dominant angle + rotation
    var wallNorms: [(nx: Float, nz: Float)] = []
    for v in allVerts where abs(v.normal.y) < 0.3 && v.pos.y >= m.floorY + 0.5 && v.pos.y <= m.floorY + 1.5 {
        wallNorms.append((nx: v.normal.x, nz: v.normal.z))
    }
    let binCount = 180
    var hist = Array(repeating: 0, count: binCount)
    for n in wallNorms {
        var a = atan2(n.nz, n.nx); if a < 0 { a += .pi }
        hist[min(Int(a / .pi * Float(binCount)), binCount - 1)] += 1
    }
    var sm = Array(repeating: 0, count: binCount)
    for i in 0..<binCount { var s = 0; for d in -3...3 { s += hist[(i+d+binCount)%binCount] }; sm[i] = s }
    let peak = sm.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
    let rotAngle = -(Float(peak) / Float(binCount) * .pi - .pi / 2)
    let cosA = cos(rotAngle), sinA = sin(rotAngle)

    let rotVerts = allVerts.map { v -> (pos: SIMD3<Float>, normal: SIMD3<Float>) in
        (pos: SIMD3(v.pos.x * cosA - v.pos.z * sinA, v.pos.y, v.pos.x * sinA + v.pos.z * cosA),
         normal: SIMD3(v.normal.x * cosA - v.normal.z * sinA, v.normal.y, v.normal.x * sinA + v.normal.z * cosA))
    }

    // Wall RANSAC
    var wallPts: [(x: Float, z: Float)] = []
    for v in rotVerts where abs(v.normal.y) < 0.3 && v.pos.y >= m.floorY + 0.5 && v.pos.y <= m.floorY + 1.5 {
        wallPts.append((x: v.pos.x, z: v.pos.z))
    }

    var remaining = wallPts
    var walls: [(x1: Float, z1: Float, x2: Float, z2: Float, thick: Float, inliers: Int)] = []
    let minInliers = max(20, wallPts.count / 50)

    for _ in 0..<15 {
        guard remaining.count >= minInliers else { break }
        var bestIn: [(x: Float, z: Float)] = [], bestOut: [(x: Float, z: Float)] = []
        var bestW: (x1: Float, z1: Float, x2: Float, z2: Float, thick: Float, inliers: Int)?

        for _ in 0..<400 {
            let i1 = Int.random(in: 0..<remaining.count)
            var i2 = Int.random(in: 0..<remaining.count); while i2 == i1 { i2 = Int.random(in: 0..<remaining.count) }
            let p1 = remaining[i1], p2 = remaining[i2]
            let dx = p2.x-p1.x, dz = p2.z-p1.z, len = sqrt(dx*dx+dz*dz)
            guard len > 0.1 else { continue }
            let nx = -dz/len, nz = dx/len
            var ins: [(x: Float, z: Float)] = [], outs: [(x: Float, z: Float)] = []
            for p in remaining { if abs((p.x-p1.x)*nx+(p.z-p1.z)*nz) < 0.04 { ins.append(p) } else { outs.append(p) } }
            if ins.count > bestIn.count {
                var minT: Float = .greatestFiniteMagnitude, maxT: Float = -.greatestFiniteMagnitude
                var perps: [Float] = []
                for p in ins {
                    let t = (p.x-p1.x)*(dx/len)+(p.z-p1.z)*(dz/len); minT = min(minT,t); maxT = max(maxT,t)
                    perps.append((p.x-p1.x)*nx+(p.z-p1.z)*nz)
                }
                perps.sort()
                let thick = perps.count > 10 ? perps[perps.count*9/10]-perps[perps.count/10] : 0.07
                if maxT-minT > 0.3 {
                    bestIn = ins; bestOut = outs
                    bestW = (p1.x+(dx/len)*minT, p1.z+(dz/len)*minT, p1.x+(dx/len)*maxT, p1.z+(dz/len)*maxT, thick, ins.count)
                }
            }
        }
        guard let w = bestW, bestIn.count >= minInliers else { break }
        walls.append(w); remaining = bestOut
    }
    m.wallCount = walls.count

    // Measure room
    let hWalls = walls.filter { (w) -> Bool in
        let a = abs(atan2(w.z2 - w.z1, w.x2 - w.x1))
        return a < 0.26 || abs(a - Float.pi) < 0.26
    }.sorted { (a, b) -> Bool in (a.z1 + a.z2) < (b.z1 + b.z2) }

    let vWalls = walls.filter { (w) -> Bool in
        let a = abs(atan2(w.z2 - w.z1, w.x2 - w.x1))
        return abs(abs(a) - Float.pi / 2) < 0.26
    }.sorted { (a, b) -> Bool in (a.x1 + a.x2) < (b.x1 + b.x2) }

    if hWalls.count >= 2 {
        let n = hWalls.first!, f = hWalls.last!
        let centerN: Float = (n.z1 + n.z2) / 2
        let centerF: Float = (f.z1 + f.z2) / 2
        let gap: Float = abs(centerF - centerN)
        let thickAvg: Float = (n.thick + f.thick) / 2
        m.measuredDepth_mm = (gap - thickAvg) * 1000
    }
    if vWalls.count >= 2 {
        let l = vWalls.first!, r = vWalls.last!
        let centerL: Float = (l.x1 + l.x2) / 2
        let centerR: Float = (r.x1 + r.x2) / 2
        let gap: Float = abs(centerR - centerL)
        let thickAvg: Float = (l.thick + r.thick) / 2
        m.measuredWidth_mm = (gap - thickAvg) * 1000
    }

    // Opening detection
    for w in walls {
        let dx = w.x2-w.x1, dz = w.z2-w.z1, len = sqrt(dx*dx+dz*dz)
        guard len > 1.0 else { continue }
        let nx = -dz/len, nz = dx/len
        let ss: Float = 0.1; let sc = Int(len/ss); guard sc > 3 else { continue }
        var dLow = Array(repeating: 0, count: sc), dMid = Array(repeating: 0, count: sc)
        for v in rotVerts {
            let pd = abs((v.pos.x-w.x1)*nx+(v.pos.z-w.z1)*nz)
            guard pd < 0.15 && abs(v.normal.y) < 0.3 else { continue }
            let t = (v.pos.x-w.x1)*(dx/len)+(v.pos.z-w.z1)*(dz/len)
            let seg = Int(t/ss); guard seg >= 0 && seg < sc else { continue }
            let h = v.pos.y - m.floorY
            if h >= 0 && h < 0.5 { dLow[seg] += 1 } else if h >= 0.5 && h < 2.0 { dMid[seg] += 1 }
        }
        let avg = dMid.reduce(0,+)/max(1,sc); let thresh = max(2, avg/4)
        var inGap = false, gs = 0
        for seg in 0..<sc {
            if dMid[seg] < thresh && !inGap { inGap = true; gs = seg }
            else if dMid[seg] >= thresh && inGap {
                inGap = false; let gw = Float(seg-gs)*ss
                if gw >= 0.4 && gw <= 6.0 {
                    let lowD = (gs..<seg).map { dLow[$0] }.reduce(0,+)
                    let hasSill = lowD > (seg-gs)*2
                    let kind: String
                    if hasSill { kind = "window" }
                    else if gw >= 2.4 { kind = "garage_door" }
                    else if gw >= 1.5 { kind = "sliding_door" }
                    else if gw >= 1.2 { kind = "double_door" }
                    else { kind = "door" }
                    m.openings.append((kind: kind, width_mm: gw * 1000))
                }
            }
        }
    }

    // Object detection
    let bands: [(min: Float, max: Float, name: String)] = [
        (0.35, 0.55, "low"), (0.70, 0.82, "mid"), (0.82, 0.98, "counter")
    ]
    for band in bands {
        var pts: [SIMD3<Float>] = []
        for v in rotVerts where v.normal.y > 0.6 && v.pos.y >= m.floorY+band.min && v.pos.y <= m.floorY+band.max {
            pts.append(v.pos)
        }
        guard pts.count > 20 else { continue }
        let cs: Float = 0.3
        var grid: [String: [SIMD3<Float>]] = [:]
        for p in pts { grid["\(Int(p.x/cs)),\(Int(p.z/cs))", default: []].append(p) }
        var vis = Set<String>()
        for key in grid.keys {
            guard !vis.contains(key) else { continue }
            var cluster: [SIMD3<Float>] = []; var q = [key]
            while !q.isEmpty {
                let c = q.removeFirst(); guard !vis.contains(c) else { continue }; vis.insert(c)
                if let p = grid[c] { cluster.append(contentsOf: p) }
                let parts = c.split(separator: ",")
                guard parts.count == 2, let cx = Int(parts[0]), let cz = Int(parts[1]) else { continue }
                for dx in -1...1 { for dz in -1...1 {
                    if dx == 0 && dz == 0 { continue }
                    let nb = "\(cx+dx),\(cz+dz)"; if grid[nb] != nil && !vis.contains(nb) { q.append(nb) }
                }}
            }
            guard cluster.count >= 10 else { continue }
            let w = cluster.map(\.x).max()! - cluster.map(\.x).min()!
            let d = cluster.map(\.z).max()! - cluster.map(\.z).min()!
            let h = (cluster.map(\.y).reduce(0,+)/Float(cluster.count)) - m.floorY
            guard w > 0.25 && d > 0.2 && w < 5.0 && d < 3.0 else { continue }
            let cat: String
            if band.name == "counter" { cat = (w > 1.0 || d > 1.0) ? "bench" : "vanity" }
            else if band.name == "low" {
                let ls = max(w,d), ss = min(w,d)
                if ss > 0.25 && ss < 0.6 && ls > 0.35 && ls < 0.85 { cat = "toilet" }
                else if ls > 1.2 && ss > 0.5 { cat = "bath" }
                else { cat = "table" }
            } else { cat = (w > 1.5 && d > 0.8) ? "bed" : "table" }
            m.objects.append((category: cat, width_mm: w*1000, depth_mm: d*1000, height_mm: h*1000))
        }
    }

    // Floor coverage
    let floorPts = rotVerts.filter { $0.normal.y > 0.5 && $0.pos.y >= m.floorY-0.1 && $0.pos.y <= m.floorY+0.3 }
    let cellSz: Float = 0.2
    var floorCells = Set<String>()
    for p in floorPts { floorCells.insert("\(Int(p.pos.x/cellSz)),\(Int(p.pos.z/cellSz))") }
    let expectedCells = max(1, Int((m.measuredWidth_mm/1000/cellSz) * (m.measuredDepth_mm/1000/cellSz)))
    m.floorCoverage = Float(floorCells.count) / Float(expectedCells) * 100

    return m
}

// ============================================================================
// MARK: - Comparison & Report
// ============================================================================

func compare(scan: ScanMeasurements, gt: RoomGT, roomKey: String, isMultiRoom: Bool = false) -> String {
    let line = String(repeating: "═", count: 72)
    let thin = String(repeating: "─", count: 72)
    var r = ""

    r += "\n\(line)\n"
    r += "  STUDIIO CALIBRATION REPORT\n"
    r += "  3 Fagan Place Cumbalum — \(gt.name)\n"
    if isMultiRoom { r += "  Mode: MULTI-ROOM COMBINED\n" }
    r += "  \(ISO8601DateFormatter().string(from: Date()))\n"
    r += "\(line)\n\n"

    // Stats
    r += "  SCAN QUALITY\n  \(thin)\n"
    r += "  Mesh anchors:    \(scan.anchors)\n"
    r += "  Vertices:         \(scan.vertices)\n"
    r += "  Room height:      \(String(format: "%.2f", scan.ceilingY - scan.floorY))m\n"
    r += "  Floor coverage:   \(String(format: "%.0f", scan.floorCoverage))%%\n\n"

    if isMultiRoom {
        // Multi-room: show bounding box dimensions and combined area, skip accuracy grading
        let measArea = scan.measuredWidth_mm * scan.measuredDepth_mm / 1_000_000
        r += "  BOUNDING BOX (multi-room)\n  \(thin)\n"
        r += "  Measured width:   \(pad(Int(scan.measuredWidth_mm)))mm\n"
        r += "  Measured depth:   \(pad(Int(scan.measuredDepth_mm)))mm\n"
        r += "  Bounding area:    \(String(format: "%.1f", measArea))m²\n"
        r += "  Combined GT area: \(String(format: "%.1f", gt.area_m2))m²\n"
        r += "  (Dimension accuracy grading skipped for multi-room scans)\n\n"
    } else {
        // Single-room: full dimension comparison with grading
        let err1W = scan.measuredWidth_mm - gt.width_mm
        let err1D = scan.measuredDepth_mm - gt.depth_mm
        let err2W = scan.measuredWidth_mm - gt.depth_mm
        let err2D = scan.measuredDepth_mm - gt.width_mm
        let score1 = abs(err1W) + abs(err1D)
        let score2 = abs(err2W) + abs(err2D)

        let (refW, refD, errW, errD): (Float, Float, Float, Float)
        if score1 <= score2 {
            refW = gt.width_mm; refD = gt.depth_mm; errW = err1W; errD = err1D
        } else {
            refW = gt.depth_mm; refD = gt.width_mm; errW = err2W; errD = err2D
        }

        let wPct = refW > 0 ? abs(errW / refW) * 100 : 0
        let dPct = refD > 0 ? abs(errD / refD) * 100 : 0
        let avgPct = (wPct + dPct) / 2

        r += "  ROOM DIMENSIONS\n  \(thin)\n"
        r += "                    Reference     Measured      Error        %%\n"
        r += "  Width:            \(pad(Int(refW)))mm     \(pad(Int(scan.measuredWidth_mm)))mm     \(errW > 0 ? "+" : "")\(pad(Int(errW)))mm    \(String(format: "%5.1f", wPct))%%\n"
        r += "  Depth:            \(pad(Int(refD)))mm     \(pad(Int(scan.measuredDepth_mm)))mm     \(errD > 0 ? "+" : "")\(pad(Int(errD)))mm    \(String(format: "%5.1f", dPct))%%\n"

        let refArea = refW * refD / 1_000_000
        let measArea = scan.measuredWidth_mm * scan.measuredDepth_mm / 1_000_000
        r += "  Area:             \(String(format: "%.1f", refArea))m²       \(String(format: "%.1f", measArea))m²\n\n"

        // Grade
        let grade: String
        if avgPct < 0.5 { grade = "A+  EXCEPTIONAL  (<0.5%%)" }
        else if avgPct < 1.0 { grade = "A+  EXCELLENT   (<1%%)" }
        else if avgPct < 2.0 { grade = "A   VERY GOOD   (<2%%)" }
        else if avgPct < 3.0 { grade = "B   GOOD        (<3%%)" }
        else if avgPct < 5.0 { grade = "C   FAIR        (<5%%)" }
        else { grade = "D   NEEDS WORK  (>5%%)" }
        r += "  ┌─────────────────────────────────────┐\n"
        r += "  │  ACCURACY GRADE:  \(grade)  │\n"
        r += "  └─────────────────────────────────────┘\n\n"
    }

    // Door comparison
    r += "  DOORS  (expected: \(gt.doors.count))\n  \(thin)\n"
    let detectedDoors = scan.openings.filter { $0.kind == "door" || $0.kind == "double_door" }

    for gtDoor in gt.doors {
        // Find closest detected door by width
        let match = detectedDoors.min(by: { abs($0.width_mm - gtDoor.width_mm) < abs($1.width_mm - gtDoor.width_mm) })
        if let m = match, abs(m.width_mm - gtDoor.width_mm) < 400 {
            let err = m.width_mm - gtDoor.width_mm
            r += "  ✓ \(gtDoor.name) (\(Int(gtDoor.width_mm))mm \(gtDoor.type))\n"
            r += "    Detected: \(m.kind) \(Int(m.width_mm))mm  [error: \(err > 0 ? "+" : "")\(Int(err))mm]\n"
        } else {
            r += "  ✗ \(gtDoor.name) (\(Int(gtDoor.width_mm))mm \(gtDoor.type)) — NOT DETECTED\n"
        }
    }

    let unmatched = detectedDoors.count - gt.doors.count
    if unmatched > 0 {
        r += "  ? \(unmatched) extra door(s) detected (possible false positives)\n"
    }
    r += "\n"

    // Window comparison
    r += "  WINDOWS  (expected: \(gt.windows.count))\n  \(thin)\n"
    let detectedWindows = scan.openings.filter { $0.kind == "window" }

    for gtWin in gt.windows {
        let match = detectedWindows.min(by: { abs($0.width_mm - gtWin.width_mm) < abs($1.width_mm - gtWin.width_mm) })
        if let m = match, abs(m.width_mm - gtWin.width_mm) < 600 {
            let err = m.width_mm - gtWin.width_mm
            r += "  ✓ \(gtWin.name) (\(gtWin.label) \(Int(gtWin.width_mm))mm)\n"
            r += "    Detected: window \(Int(m.width_mm))mm  [error: \(err > 0 ? "+" : "")\(Int(err))mm]\n"
        } else {
            r += "  ✗ \(gtWin.name) (\(gtWin.label) \(Int(gtWin.width_mm))mm) — NOT DETECTED\n"
        }
    }
    r += "\n"

    // Opening comparison
    r += "  OPENINGS  (expected: \(gt.openings.count))\n  \(thin)\n"
    let detectedOpenings = scan.openings.filter { ["sliding_door", "garage_door"].contains($0.kind) }

    for gtO in gt.openings {
        let match = detectedOpenings.min(by: { abs($0.width_mm - gtO.width_mm) < abs($1.width_mm - gtO.width_mm) })
        if let m = match, abs(m.width_mm - gtO.width_mm) < 800 {
            let err = m.width_mm - gtO.width_mm
            r += "  ✓ \(gtO.name) (\(Int(gtO.width_mm))mm)\n"
            r += "    Detected: \(m.kind) \(Int(m.width_mm))mm  [error: \(err > 0 ? "+" : "")\(Int(err))mm]\n"
        } else {
            r += "  ✗ \(gtO.name) (\(Int(gtO.width_mm))mm) — NOT DETECTED\n"
        }
    }
    r += "\n"

    // Fixture comparison
    r += "  FIXTURES  (expected: \(gt.fixtures.count))\n  \(thin)\n"
    for gtF in gt.fixtures {
        let match = scan.objects.first { $0.category == gtF.category ||
            (gtF.category == "kitchen_bench" && $0.category == "bench") ||
            (gtF.category == "kitchen_island" && $0.category == "bench") }
        if let m = match {
            r += "  ✓ \(gtF.name) (\(gtF.category))\n"
            r += "    Detected: \(m.category) \(Int(m.width_mm))×\(Int(m.depth_mm))mm at \(Int(m.height_mm))mm height\n"
            if gtF.width_mm > 0 {
                r += "    Size error: width \(Int(m.width_mm - gtF.width_mm))mm, depth \(Int(m.depth_mm - gtF.depth_mm))mm\n"
            }
        } else {
            r += "  ✗ \(gtF.name) (\(gtF.category)) — NOT DETECTED\n"
        }
    }

    // False positives
    let knownCategories = Set(gt.fixtures.map { $0.category } + ["kitchen_bench", "kitchen_island"])
    let fps = scan.objects.filter { !knownCategories.contains($0.category) && $0.category != "table" }
    if !fps.isEmpty {
        r += "\n  ? FALSE POSITIVES:\n"
        for fp in fps {
            r += "    ? \(fp.category) \(Int(fp.width_mm))×\(Int(fp.depth_mm))mm at \(Int(fp.height_mm))mm\n"
        }
    }
    r += "\n"

    // Summary scorecard
    let totalExpected = gt.doors.count + gt.windows.count + gt.openings.count + gt.fixtures.count
    let doorsMatched = gt.doors.filter { d in
        detectedDoors.contains { abs($0.width_mm - d.width_mm) < 400 }
    }.count
    let windowsMatched = gt.windows.filter { w in
        detectedWindows.contains { abs($0.width_mm - w.width_mm) < 600 }
    }.count
    let openingsMatched = gt.openings.filter { o in
        detectedOpenings.contains { abs($0.width_mm - o.width_mm) < 800 }
    }.count
    let fixturesMatched = gt.fixtures.filter { f in
        scan.objects.contains { $0.category == f.category || (f.category == "kitchen_bench" && $0.category == "bench") || (f.category == "kitchen_island" && $0.category == "bench") }
    }.count
    let totalMatched = doorsMatched + windowsMatched + openingsMatched + fixturesMatched

    r += "  SCORECARD\n  \(thin)\n"
    r += "  Doors:     \(doorsMatched)/\(gt.doors.count)\n"
    r += "  Windows:   \(windowsMatched)/\(gt.windows.count)\n"
    r += "  Openings:  \(openingsMatched)/\(gt.openings.count)\n"
    r += "  Fixtures:  \(fixturesMatched)/\(gt.fixtures.count)\n"
    r += "  ─────────────────\n"
    r += "  TOTAL:     \(totalMatched)/\(totalExpected) features (\(totalExpected > 0 ? Int(Float(totalMatched)/Float(totalExpected)*100) : 0)%%)\n"
    r += "\n\(line)\n"

    return r
}

func pad(_ n: Int) -> String {
    let s = "\(n)"
    return String(repeating: " ", count: max(0, 5 - s.count)) + s
}

// ============================================================================
// MARK: - Main
// ============================================================================

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Usage: swift calibrate.swift /path/to/scan.studiio [room_name]")
    print("       swift calibrate.swift /path/to/scan.studiio living+family+dining+entry")
    print("Room names: rumpus, bed5, bed6, ensuite2, living, family, dining, garage, entry, laundry, outdoor_living")
    print("Use + to combine multiple rooms for multi-room scans.")
    exit(1)
}

let bundlePath = args[1]
let meshDir = URL(fileURLWithPath: bundlePath).appendingPathComponent("mesh")
guard FileManager.default.fileExists(atPath: meshDir.path) else {
    print("ERROR: No mesh/ directory in \(bundlePath)"); exit(1)
}

let rooms = loadGroundTruth()
guard !rooms.isEmpty else {
    print("ERROR: Could not load ground-truth.json"); exit(1)
}

print("Processing scan...")
let scan = processScan(meshDir: meshDir)

// Identify or use specified room(s)
let roomKey: String
let gt: RoomGT
let isMultiRoom: Bool

if args.count >= 3 {
    let roomArg = args[2].lowercased()
    let roomKeys = roomArg.split(separator: "+").map { String($0) }

    if roomKeys.count > 1 {
        // Multi-room mode
        isMultiRoom = true
        roomKey = roomKeys.joined(separator: "+")
        guard let combined = combineRooms(keys: roomKeys, rooms: rooms) else {
            exit(1)
        }
        gt = combined
        print("Multi-room mode: \(gt.name)")
        print("Combined ground truth: \(gt.doors.count) doors, \(gt.windows.count) windows, \(gt.openings.count) openings, \(gt.fixtures.count) fixtures")
        print("Combined area: \(String(format: "%.1f", gt.area_m2))m²")
    } else {
        // Single room mode
        isMultiRoom = false
        roomKey = roomArg
        guard let r = rooms[roomKey] else {
            print("ERROR: Unknown room '\(roomKey)'. Available: \(rooms.keys.sorted().joined(separator: ", "))")
            exit(1)
        }
        gt = r
    }
} else {
    isMultiRoom = false
    if let match = identifyRoom(measuredWidth: scan.measuredWidth_mm, measuredDepth: scan.measuredDepth_mm, rooms: rooms) {
        roomKey = match.0
        gt = match.1
        print("Auto-detected room: \(gt.name) (measured \(Int(scan.measuredWidth_mm))×\(Int(scan.measuredDepth_mm))mm)")
    } else {
        print("Could not auto-detect room from dimensions \(Int(scan.measuredWidth_mm))×\(Int(scan.measuredDepth_mm))mm")
        print("Available rooms: \(rooms.keys.sorted().joined(separator: ", "))")
        print("Specify room: swift calibrate.swift \(bundlePath) rumpus")
        exit(1)
    }
}

let report = compare(scan: scan, gt: gt, roomKey: roomKey, isMultiRoom: isMultiRoom)
print(report)

// Save reports
let dir = URL(fileURLWithPath: bundlePath).deletingLastPathComponent()
try? report.write(toFile: dir.appendingPathComponent("calibration-report.txt").path, atomically: true, encoding: .utf8)

let jsonReport: [String: Any] = [
    "room": roomKey,
    "room_name": gt.name,
    "multi_room": isMultiRoom,
    "timestamp": ISO8601DateFormatter().string(from: Date()),
    "vertices": scan.vertices,
    "ref_width_mm": gt.width_mm,
    "ref_depth_mm": gt.depth_mm,
    "ref_area_m2": gt.area_m2,
    "measured_width_mm": scan.measuredWidth_mm,
    "measured_depth_mm": scan.measuredDepth_mm,
    "walls": scan.wallCount,
    "openings_detected": scan.openings.count,
    "objects_detected": scan.objects.count,
    "floor_coverage_pct": scan.floorCoverage,
    "expected_doors": gt.doors.count,
    "expected_windows": gt.windows.count,
    "expected_openings": gt.openings.count,
    "expected_fixtures": gt.fixtures.count,
]
if let jd = try? JSONSerialization.data(withJSONObject: jsonReport, options: [.prettyPrinted, .sortedKeys]) {
    try? jd.write(to: dir.appendingPathComponent("calibration-report.json"))
}
print("Reports saved.")
