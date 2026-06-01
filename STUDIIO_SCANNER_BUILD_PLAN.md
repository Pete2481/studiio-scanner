# Studiio Scanner — Master Build Plan (v2)

*Pete's personal-use property scanner. iPhone scans entire houses continuously, Mac produces A3 metric blueprint PDF matching Roomio output quality. Replaces paid services for Australian real estate sales + rental property management.*

*Updated 2026-05-18 after Q&A session. All decisions locked.*

---

## Architectural decisions locked

| # | Decision | Choice |
|---|---|---|
| 1 | App count | **Two apps** — iPhone scanner + Mac blueprint renderer |
| 2 | Object detection | **All three approaches** — manual tap-tag (v1), voice tag (v2), custom AI (v3). Data model supports all from day one. |
| 3 | Outdoor scanning | **Core from day one** — balconies and decks are essential. App auto-detects indoor/outdoor and switches sensing strategy. |
| 4 | Dev environment | **VS Code with Swift extension** (editing) + **Xcode** (compile + install on device) |
| 5 | Primary use case | Real estate listings + rental property management |
| 6 | iPhone to Mac sync | **All three accepted** — iCloud Drive, AirDrop, Local WiFi. Mac app reads any of them. |
| 7 | Blueprint output | **A3 landscape, 1:100 metric** (Australian standard). Multi-page when multi-floor. |
| 8 | Multi-floor | **First-class from day one** — auto stair detection, floor splits. Even ~3 stairs to a sunken zone tracked. |
| 9 | Design system | **Dark UI + orange/amber accent** across BOTH apps. Custom orange mesh overlay during scanning. Mac app has HUD-inspired technical aesthetic. |
| 10 | Visual target | **Match Roomio output exactly**, beat on speed (instant vs 12-24h) and accuracy (verified dimensions). |
| 11 | Wall thickness | **Auto-detected from LiDAR** — no user input needed. |
| 12 | Verified dimensions | **v1 feature** — tape-measure override for key walls after scanning. |
| 13 | Disclaimer | **Auto-generated Australian disclaimer** on every PDF. |
| 14 | Scanning approach | **Continuous whole-house scanning** from day one. No single-room-only phase. |

**Devices:**
- iPhone 12 Pro or later (Pro models only — needs LiDAR)
- iPad Pro 2020 or later (optional, same app runs on it)
- Mac running macOS 14 Sonoma or later (for the companion app)

**Target iOS / macOS:**
- iOS 17.0+ on iPhone (gets us MultiRoom, curved walls, custom ARSession)
- macOS 14.0+ on Mac

---

## Design System

### Colour Palette
- **Background:** near-black (`#0D0D0D` to `#1A1A1A`)
- **Surface/cards:** dark grey (`#1E1E1E` to `#2A2A2A`)
- **Primary accent:** orange/amber (`#FF8C00` range — exact to be tuned)
- **Secondary text:** light grey (`#B0B0B0`)
- **Primary text:** white (`#FFFFFF`)
- **Scan mesh overlay:** orange (custom Metal/RealityKit shader replacing RoomPlan purple)
- **Scan mesh wireframe:** white with reduced opacity

### Blueprint PDF Style (Roomio-match)
- White background, black filled walls (exterior thicker)
- Bathrooms/ensuites/WC: light blue fill
- Outdoor roofed areas: diagonal hatching
- Room labels: name in caps + "W x H m" centred
- Standard AU abbreviations: BIR, WIR, WIL, ENS, WC, DW, OV, F, P, WM, DR, FP, CUP'D, P'TRY, WIP, BBQ, A/C
- Multi-floor side by side on one page
- Detached structures: "(NOT IN POSITION)"
- Bottom-left: address + "TOTAL APPROX. FLOOR AREA XXX SQ.M" + disclaimer
- Top-right: north arrow

---

## Tech stack reference

| Layer | Framework / tool | What it does |
|---|---|---|
| Scanning | **RoomPlan** | Apple's high-level room scanner. Outputs walls, doors, windows, openings, 16 furniture types as parametric 3D. |
| Mesh overlay | **ARKit Scene Reconstruction** (`ARMeshAnchor`) | The mesh wrap visual. Captures every surface as raw mesh. |
| Tracking | **ARKit World Tracking** (`ARWorldTrackingConfiguration`) | Phone position in 3D space, including height for stair/floor detection. |
| 3D rendering | **RealityKit** | Renders the live mesh + parametric model in the camera view. |
| Custom shader | **Metal / RealityKit materials** | Orange mesh overlay replacing RoomPlan default purple. |
| 2D rendering | **SwiftUI Canvas** + **Core Graphics** | Draws the blueprint on Mac. |
| PDF export | **PDFKit** + **ImageRenderer** | A3 PDF generation. |
| File format | **USDZ** + custom JSON | Standard 3D + our own project bundle. |
| Storage | **FileManager** + **iCloud Drive** | Project files on disk. |
| Sync | **CloudKit** OR plain iCloud Drive files OR **Network.framework** for local WiFi | Phone to Mac transfer. |
| Persistence | **SwiftData** | Project list, metadata. |
| AI (future) | **Core ML** + **Vision** | Custom object detection. |
| Voice (future) | **Speech** framework | Speech-to-text for voice tagging. |

---

## File layout

```
~/studiio scanner/
├── STUDIIO_SCANNER_BUILD_PLAN.md       <- this document
├── STUDIIO_SCANNER_DOSSIER.md          <- research
├── Screens/                            <- Roomio scanning screenshots
├── Design UX/                          <- UI reference images
├── Floor plan Examples/                <- 6 Roomio PDF/JPG samples
└── code/
    ├── StudiioScanner-iOS/             <- iPhone/iPad scanner app
    │   ├── StudiioScanner.xcodeproj
    │   ├── App/
    │   ├── Capture/                    <- scanning, mesh, RoomPlan, outdoor detection
    │   ├── Models/                     <- data structures
    │   ├── ProjectStore/               <- saving/loading
    │   ├── Sync/                       <- iCloud / AirDrop / WiFi
    │   ├── Tagging/                    <- manual tap-tag UI
    │   ├── Theme/                      <- dark + orange design system
    │   └── Resources/
    └── StudiioBlueprint-macOS/         <- Mac blueprint renderer
        ├── StudiioBlueprint.xcodeproj
        ├── App/
        ├── Import/                     <- reads project files from any sync source
        ├── Models/
        ├── Renderer/                   <- walls to 2D pipeline
        ├── Symbols/                    <- architectural symbol library
        ├── PDF/                        <- PDFKit output
        ├── Editor/                     <- manual touch-up + verified dimensions
        ├── Theme/                      <- dark + orange HUD design system
        └── Resources/
```

---

# THE PHASES

10 phases total. Restructured from original 13 to reflect merged decisions.

- **Phase 0** — Setup & tooling
- **Phases 1-4** — iPhone scanner app (whole-house capture, outdoor, tagging, export)
- **Phases 5-8** — Mac blueprint renderer (import, 2D render, PDF, editor)
- **Phase 9** — Testing & real-world validation

---

## Phase 0 — Foundations & Setup

**Goal:** working dev environment, both Xcode projects created, hello-world running on your iPhone.

**Effort:** 1 evening (~3 hours)

### 0.1 Install tools
- Xcode (free, Mac App Store, ~15 GB) — required for iOS builds
- VS Code (or Cursor) + Swift extension — your daily editor
- iCloud Drive enabled on Mac and iPhone (same Apple ID)

### 0.2 Apple ID for development
- Use your existing Apple ID
- In Xcode > Settings > Accounts > add your Apple ID as a "Personal Team"
- No US$99/year developer account needed for personal use — Personal Team lets you install on your own devices with 7-day rolling provisioning

### 0.3 Create the two empty projects
- **StudiioScanner** — iOS app, SwiftUI lifecycle, min iOS 17.0, universal (iPhone + iPad)
- **StudiioBlueprint** — macOS app, SwiftUI lifecycle, min macOS 14.0

### 0.4 Set up entitlements
iPhone scanner needs:
- `NSCameraUsageDescription` ("Studiio Scanner needs the camera to scan rooms")
- `NSMicrophoneUsageDescription` ("...for voice tagging features" — pre-add even though v2 feature)
- ARKit capability
- iCloud Documents capability (for sync later)

Mac app needs:
- iCloud Documents capability (read scans from iCloud)
- Network access capability (for local WiFi sync)
- File access (for AirDrop drop-zone)

### 0.5 Design system foundation
- Create `Theme/` folders in both projects
- Define shared colour constants (dark backgrounds, orange accent, text colours)
- Create reusable button styles, card styles matching the dark + orange aesthetic

### 0.6 Verify on-device
Build the empty scanner app, plug in your iPhone, run from Xcode. You should see a dark-themed blank app on the phone. This proves your provisioning works.

### Definition of done
- Both empty projects compile
- Scanner app runs on your phone (dark theme splash screen)
- Mac app runs on your Mac (dark theme empty window)
- VS Code opens the project folder and shows Swift syntax highlighting
- Theme colours defined in both projects

---

## Phase 1 — Scanner: Whole-House Continuous Capture

**Goal:** open the app, start scanning, walk through every room in the house continuously, app captures everything. Orange mesh overlay. Stair detection prompts for floor splits. Tap Complete, see a 3D preview of the whole house.

**Effort:** 3 weeks (~45-60 hours) — this merges the original Phases 1 + 2.

### 1.1 The scan screen
Built in SwiftUI wrapping `RoomCaptureView` via `UIViewRepresentable`. Using `RoomCaptureSession` with `customARSession` (iOS 17+) so we control the AR session and can layer our own mesh rendering on top.

### 1.2 The orange mesh overlay
Two layers running together:
1. `RoomCaptureSession` with `customARSession` — RoomPlan running silently, capturing structural geometry
2. `ARWorldTrackingConfiguration.sceneReconstruction = .meshWithClassification` on the SAME custom AR session — gives us `ARMeshAnchor` updates every frame

Custom Metal/RealityKit material for the mesh:
- Base fill: orange with ~45% opacity (exact colour from our design system)
- Wireframe: white with ~60% opacity, thin lines following mesh triangulation
- Ceilings: full mesh visible (raw `ARMeshAnchor`)
- Walls: orange fill from RoomPlan surface + wireframe overlay

### 1.3 Chrome UI
- Top: red dot + "Scanning..." + X (cancel) — all in our dark theme
- Bottom: large pill button "Complete scan" (orange accent)
- Room count indicator showing how many rooms captured so far
- Cancel goes to confirmation alert
- Subtle haptic feedback when new surface detected

### 1.4 Multi-room continuous flow
Standard RoomPlan multi-room flow (iOS 17+):
- User walks through the house continuously — through doorways, between rooms
- RoomPlan detects room transitions automatically
- Room counter increments as new rooms detected
- At the end, `StructureBuilder.capturedStructure(from: [CapturedRoom])` merges everything

### 1.5 Stair detection
ARKit gives us `ARFrame.camera.transform` every frame — including world Y (height). We track elevation continuously:
- **Baseline:** scan start = "floor 0 height"
- **Watcher:** sliding window of last 5 seconds of Y values
- **Trigger:** Y moved >0.4m up/down in 5 seconds AND user is moving
- **Confirmation:** check for `.stairs` in RoomPlan data near current position
- **Action:** modal: "Looks like you've changed levels. Start a new floor?" with "Yes, upstairs" / "Yes, downstairs" / "No, same floor"
- Handles 3-step sunken zones (~50cm drop) — user decides if it's a new floor or same-floor level change

### 1.6 Floor tagging
When user confirms a floor transition, project tree updates:
```
Property: "23 Smith St"
├── Floor: Ground
│   ├── Living
│   ├── Kitchen
│   └── Hallway
└── Floor: Upstairs
    ├── Master
    └── Bath
```

### 1.7 Permissions flow
First launch onboarding:
1. "Studiio needs the camera to scan rooms" — Allow
2. "...and the microphone for voice tagging features" — Allow
3. Done. App opens to project list (dark theme, empty).

### 1.8 Saving the raw capture
When user taps Complete:
- RoomPlan delivers `CapturedRoom` / `CapturedStructure`
- ARKit gives accumulated `ARMeshAnchor` data
- Auto-captured photos (1 every 2 seconds via `ARFrame.capturedImage`)
- All bundled into `<timestamp>.studiio-scan` (zipped: `room.json`, `mesh.usdz`, `frames/`, `metadata.json`)

### 1.9 Post-scan 3D preview
RealityKit scene showing the captured house with the orange mesh material. Pinch-zoom, rotate. Buttons: "Save & finish" or continue to tagging (Phase 3).

### 1.10 Data model
```swift
struct Property: Codable, Identifiable {
    let id: UUID
    var address: String?
    var capturedAt: Date
    var floors: [Floor]
    var outbuildings: [Outbuilding]
    var outdoorZones: [OutdoorZone]
}

struct Floor: Codable, Identifiable {
    let id: UUID
    var name: String                  // "Ground", "Upstairs", "Basement"
    var elevation: Double             // metres above ground floor
    var rooms: [Room]
    var stairConnections: [StairLink]
}

struct Room: Codable, Identifiable {
    let id: UUID
    var name: String
    var capturedRoom: CapturedRoom
    var meshUSDZ: URL
    var objects: [TaggedObject]
    var area: Double                  // m2
    var photos: [URL]
    var verifiedDimensions: [VerifiedDimension]  // tape-measure overrides
}

struct TaggedObject: Codable, Identifiable {
    let id: UUID
    var category: ObjectCategory
    var position: simd_float3
    var dimensions: simd_float3
    var source: TagSource            // .autoRoomPlan / .manualTap / .voice / .ai
}

struct VerifiedDimension: Codable, Identifiable {
    let id: UUID
    var wallID: UUID                 // which wall this overrides
    var measuredLength: Double       // metres, from tape measure
    var originalLength: Double       // metres, from scan
}

struct OutdoorZone: Codable, Identifiable {
    let id: UUID
    var name: String
    var type: OutdoorType            // .deck, .balcony, .alfresco, .verandah, .porch, .patio
    var boundaryPolygon: [simd_float2]
    var connectedFloorID: UUID
    var elevation: Double
}
```

### Definition of done
- App launches, shows dark-themed project list
- Tap "+" > scan screen with orange mesh overlay
- Walk through entire house — all rooms captured continuously
- Stairs trigger floor-split prompt
- Tap Complete > 3D preview of whole house
- Save > project list shows the property with floor count

---

## Phase 2 — Scanner: Outdoor Capture (Decks, Balconies, Alfresco)

**Goal:** walk outside onto the deck/balcony mid-scan and the app keeps capturing. Outdoor zones appear in the project as their own entities.

**Effort:** 2 weeks (~25-35 hours)

### 2.1 Indoor/outdoor detection
Multiple signals fused:
1. **Light level** (`ARFrame.lightEstimate.ambientIntensity`) — outdoor >2000 lux, indoor <500
2. **LiDAR coverage** — outdoor has low mesh density (no nearby surfaces in 360)
3. **Sky detection** — Vision framework segmentation on camera frame
4. **Door/opening transit** — RoomPlan flagged an opening/door 3 seconds ago and user moved through it

When 3 of 4 signals agree > mode switch.

### 2.2 Mode switch behaviour
- **Indoor mode:** RoomPlan active, walls snapped, parametric output
- **Outdoor mode:** RoomPlan paused, raw `ARMeshAnchor` capture only, freeform geometry
- **Transition:** small orange banner: "Outside detected — scanning deck". Tap to override.

### 2.3 Outdoor zone types
Post-scan, user tags each outdoor capture as: Deck, Balcony, Alfresco, Verandah, Porch, Patio, Garden, Driveway, Carport, Other/custom.

### 2.4 Outdoor mesh post-processing
- Plane segmentation — find dominant horizontal plane (deck surface) + boundary edge polygon
- Boundary smoothing — Douglas-Peucker simplification
- Height detection — deck level relative to ground floor

### 2.5 Garages and outbuildings
Garages scanned in indoor mode but registered as `Outbuilding`. Same for granny flats, sheds, pool houses.

### 2.6 Edge cases
- Sunlight whites out tracking > fall back to ARMesh
- Glass sliding doors > manual flag from touch-up screen
- Carport (no walls) > outdoor with roof tag
- Pool > outdoor with "water feature" tag

### Definition of done
- Mid-scan transition from kitchen > deck works without user input
- Deck mesh captured with boundary polygon
- Garage scanned as Outbuilding
- Project tree shows Floors AND Outbuildings AND Outdoor Zones

---

## Phase 3 — Scanner: Object Tagging

**Goal:** after a scan, tap on the 3D model and label anything RoomPlan missed — showers, kitchen benches, vanities, wardrobes, fixtures.

**Effort:** 1 week (~15 hours)

### 3.1 Object categories
Auto-detected by RoomPlan (16):
`storage`, `refrigerator`, `stove`, `oven`, `dishwasher`, `table`, `sofa`, `chair`, `bed`, `sink`, `washerDryer`, `toilet`, `bathtub`, `fireplace`, `television`, `stairs`

Manually taggable (Studiio additions for AUS real estate):
`shower`, `vanity`, `kitchenBench`, `kitchenIsland`, `pantry`, `wardrobe`, `linenCupboard`, `laundryTub`, `rangehood`, `splitSystemAC`, `ceilingFan`, `pendant`, `downlight`, `powerPoint`, `lightSwitch`, `smokeAlarm`, `intercom`, `hotWaterUnit`, `solarPanel`, `skylight`, `nicheShelf`, `wallTV`, `barbecue`, `pool`, `spa`, `clothesLine`, `letterbox`, `custom`

### 3.2 Tagging UX
Post-scan 3D preview (dark theme):
- 3D model with detected objects shown as labelled orange pills
- Tap empty space > category picker > pill placed at tap location
- Tap existing pill > edit / delete / rename
- "Done tagging" > save & finalize

### 3.3 Tag source tracking
Every tag stored with `.source`: `.autoRoomPlan`, `.manualTap`, `.voice` (v2), `.ai` (v3). No migration needed when we add voice/AI later.

### 3.4 Voice tagging (architected, deferred to v2)
`Speech` framework + `SFSpeechRecognizer` wired in, gated behind feature flag. Mic icon at top-right during scan. "This is a shower" > tag placed at current camera position.

### 3.5 Custom AI (architected, deferred to v3)
`CoreMLObjectDetector` protocol wired in. v1 ships with stub. v3 slots in real model.

### Definition of done
- Post-scan screen lets you tap-tag any object
- All AUS-relevant categories selectable
- Free-text "Custom" option
- Tags saved with source tracking
- Voice + AI hooks compile but disabled

---

## Phase 4 — Scanner: Project Management & Sync

**Goal:** scans listed cleanly, export the project bundle to Mac via any sync path.

**Effort:** 1 week (~12 hours)

### 4.1 Project list screen (dark + orange theme)
- Grid of past scans on dark background
- Each tile: property address, scan date, preview thumbnail, floor count
- Orange accent on selected/active items
- Long-press: rename / duplicate / delete
- "+" button (orange) to start new scan

### 4.2 Project detail screen
- Big 3D preview at top
- Floor selector
- Room list under each floor
- Edit address, notes
- Tag count / object count
- "Export" button (orange accent)

### 4.3 Project file format — `.studiio` bundle
```
23-smith-st-2026-05-18.studiio/
├── metadata.json
├── floors/
│   ├── ground/
│   │   ├── room-001.json
│   │   ├── room-001.usdz
│   │   └── ...
│   └── upstairs/
├── outbuildings/
├── outdoor-zones/
├── photos/
└── thumbnail.png
```

### 4.4 Sync — three modes
**Mode A: iCloud Drive** — auto-saves to `iCloud Drive/Studiio Scanner/Pending/`, Mac watches + imports.
**Mode B: AirDrop** — Share button per project, Mac registers as `.studiio` handler.
**Mode C: Local WiFi** — Bonjour service, `NWConnection` transfer.

User picks in Settings: iCloud / AirDrop / Local WiFi / Ask each time.

### Definition of done
- Project list shows all scans in dark theme
- Detail view shows floors, rooms, tags
- Export works via all three sync modes
- Files arrive on Mac

---

## Phase 5 — Blueprint (Mac): Foundations + Project Import

**Goal:** open Mac app, see imported scans in the dark + orange HUD theme, click one, see 3D preview.

**Effort:** 1 week (~12 hours)

### 5.1 macOS app shell
- SwiftUI lifecycle, dark + orange HUD aesthetic
- Sidebar: project list with modular panel feel
- Main pane: project detail
- Toolbar: New, Import, Export PDF, Settings
- `DocumentGroup` so `.studiio` files open directly

### 5.2 Auto-import from sync sources
On launch, scan: iCloud Pending folder, ~/Downloads (`.studiio` files), Bonjour listener.

### 5.3 3D preview
RealityKit on Mac. Loads project USDZ files. Matches iPhone preview.

### Definition of done
- Drop `.studiio` file on Mac app > it opens
- Project in sidebar with dark + orange styling
- 3D preview matches iPhone
- Floor selector works

---

## Phase 6 — Blueprint (Mac): The 2D Renderer

**Goal:** convert parametric 3D walls into a clean 2D floor plan matching Roomio output quality.

**Effort:** 2-3 weeks (~40-50 hours) — the heart of the system.

### 6.1 The pipeline (per floor)
1. **Project to floor plane** — drop Y axis, get 2D line segment per wall
2. **Snap angles** — round within 2 degrees of cardinal to exact perpendicular
3. **Snap collinear walls** — within 3cm > merged
4. **Close gaps** — corner gaps under 5cm extended to close
5. **Wall thickness** — use auto-detected thickness from LiDAR scan data
6. **Door rendering** — gap + arc swing (90 degree default; iOS 17 open/closed state)
7. **Window rendering** — gap + double parallel line
8. **Opening** — gap, no symbol
9. **Room polygon** — compute interior polygon
10. **Area calculation** — m2 from polygon
11. **Verified dimension override** — if user tape-measured a wall, use that length and adjust connected geometry
12. **Object symbols** — Roomio-style: toilets, sinks, baths, etc. as architectural symbols
13. **Stairs** — parallel lines with UP/DN arrow, shown on both floors
14. **Labels** — room name (caps) + "W x H m" centred
15. **Standard abbreviations** — BIR, WIR, ENS, WC, DW, OV, F, P, WM, DR, etc.
16. **Outdoor zones** — dashed boundary, diagonal hatching for roofed areas
17. **Bathroom fill** — light blue for all wet areas

### 6.2 Symbol library (`Symbols.swift`)
Vector definitions for all fixture types matching Roomio conventions. Toilet, shower, bath, vanity, kitchen sink, stove/oven, fridge, dishwasher, washing machine, dryer, door arc, window, wardrobe, stairs, ceiling fan, BBQ, hot water unit, A/C, etc.

### 6.3 Multi-floor layout
- Each floor rendered separately
- Multiple floors placed **side by side** on one page (Roomio convention)
- Floor labels: "GROUND FLOOR", "FIRST FLOOR", "LOWER GROUND FLOOR"
- Stairs with UP/DN arrows + "Continues to/from <floor>" label
- Detached structures labelled "(NOT IN POSITION)"

### 6.4 Site plan page (when outdoor zones present)
Property outline from above, building footprint, deck, garage, pool (blue), driveway, landscaping.

### 6.5 Canvas rendering
SwiftUI `Canvas { ctx, size in ... }` — GPU-accelerated 2D drawing. All measurements in metres, rendered at chosen scale. Reactive — any data change re-draws immediately.

### Definition of done
- Project opens > 2D plan appears matching Roomio quality
- Walls clean, snapped, correct thickness
- Doors show arc, windows double-line
- Room labels + areas + abbreviations correct
- Bathrooms in light blue
- Outdoor areas with hatching
- Multi-floor side by side
- Tagged objects appear as architectural symbols

---

## Phase 7 — Blueprint (Mac): PDF Export + Branding

**Goal:** click Export > A3 landscape, 1:100 scale PDF with branding and auto-disclaimer.

**Effort:** 1 week (~12 hours)

### 7.1 Export pipeline
- SwiftUI `ImageRenderer` + `PDFKit`
- A3 landscape (297mm x 420mm), 300 DPI, vector throughout
- Multi-floor on same page (side by side) when they fit; overflow to next page
- Saved to user-chosen location (default: `~/Documents/Studiio Plans/`)

### 7.2 Branding system
Settings panel: agency name, agent name + phone + email, logo upload, disclaimer text, custom watermark, colour scheme override.

Renders into: title block (bottom-right), header (logo + agency), disclaimer footer.

### 7.3 Auto-disclaimer
Default text (always included, editable in settings):
*"Whilst every attempt has been made to ensure the accuracy of the floor plan contained here, measurements of doors, windows, rooms and any other items are approximate and no responsibility is taken for any error, omission, or misstatement. This plan is for illustrative purposes only and should be used as such by any prospective purchaser."*

### 7.4 Plan footer
- Property address
- "TOTAL APPROX. FLOOR AREA XXX SQ.M"
- Disclaimer text
- All bottom-left (matching Roomio)

### 7.5 North arrow
Top-right of each page. Oriented based on device compass reading during scan.

### 7.6 Export options
- Page size: A3 landscape (default), A4 landscape, A4 portrait, US Letter
- Scale: 1:100 default, 1:50, 1:200, auto-fit
- Units: metric (m, mm) default, imperial available
- Include site plan? Y/N
- Include summary page? Y/N
- Show measurements? Y/N

### Definition of done
- Click Export > PDF generated in seconds
- Visually matches Roomio samples
- Branding + logo appears correctly
- Australian disclaimer auto-included
- Multi-floor properties export correctly
- North arrow positioned correctly

---

## Phase 8 — Blueprint (Mac): Manual Touch-up Editor + Verified Dimensions

**Goal:** fix scan inaccuracies, input tape-measured dimensions, edit anything before final export.

**Effort:** 2 weeks (~25-30 hours)

### 8.1 Editing tools
The 2D canvas has:
- **Select** — click wall/object, drag to move, delete with backspace
- **Wall** — draw new wall (click two endpoints)
- **Door** — click wall to insert door
- **Window** — click wall to insert window
- **Object** — drop architectural symbols from palette
- **Text** — custom labels anywhere
- **Dimension** — manual dimension annotations

### 8.2 Verified dimensions (key differentiator)
- Select any wall > "Verify dimension" button
- Input tape-measured length (e.g. 4.20m)
- System records original scan length and override
- Renderer adjusts the wall to match measured length
- Connected walls and room polygons recalculate automatically
- Visual indicator on verified walls (small checkmark or different colour)
- Room areas recalculate based on verified dimensions

### 8.3 Room auto-naming + re-labelling
Auto-detect from contents: toilet+shower = "Bathroom", bed = "Bedroom", etc. Double-click to rename. All standard names available: Bedroom 1-N, Living Room, Kitchen, Dining Room, Bathroom, Ensuite, Laundry, Garage, Hall, Foyer, Office, Storage, WIR, WIL, etc.

### 8.4 Undo / redo
Full `UndoManager` stack. Autosave.

### 8.5 Non-destructive editing
Original scan data preserved. Edits stored as overlay. Reset-to-scan button reverts.

### Definition of done
- Can drag walls to fix inaccuracies
- Verified dimensions: input tape measurement > plan adjusts
- Can add doors/windows RoomPlan missed
- Room naming works (auto + manual)
- Undo/redo works
- Reset-to-scan reverts cleanly

---

## Phase 9 — Testing & Real-World Validation

**Goal:** scan 10-15 real properties, fix bugs, reach "I trust this for client work" reliability.

**Effort:** 2 weeks (~20 hours of scanning + fixing)

### 9.1 Test scan plan
- 3 single-story homes (standard 3-4 bed)
- 2 two-story homes
- 1 unit / apartment
- 1 with granny flat / garage / outbuilding
- 1 with deck + outdoor areas
- 1 with odd geometry (curved wall, half-wall, kitchen island, sunken lounge)
- 1 in bright sunlight (outdoor detection test)
- 1 at dusk (low-light test)
- 1 with mirrors and glass sliding doors (LiDAR stress test)

### 9.2 Validation checklist per scan
- All rooms captured
- Total area within +/-2% of tape-measured ground truth
- All doors detected; all windows detected
- Stairs detected, floor split worked
- Outdoor zones captured if present
- Verified dimensions feature tested
- PDF matches Roomio quality
- Time from start to PDF under 20 minutes

### 9.3 Known issues to address
- Long walls >5m getting drift > scan from middle outward
- Mirrors creating phantom rooms > tag mirror in touch-up
- Glass sliding doors invisible > manual tagging
- Outdoor in bright sun losing tracking > scan early morning or overcast

### Definition of done
- 10+ real properties scanned end-to-end
- PDFs you'd hand to a paying agent without embarrassment
- Documented "tips for best scans" cheatsheet

---

## Future Roadmap (not in v1)

### v2 Features
- Voice tagging (enable feature flag, ~3 days)
- iCloud bi-directional sync (~2 weeks)
- Apple Pencil annotations on iPad (~1 week)
- AR Quick Look USDZ export (~2 days)

### v3 Features
- Custom AI object detection via CoreML (~3-4 weeks)
- AI property description generation (~1 week)
- REA Group / Domain portal integration (~1 week each)
- Commercial release: payments, accounts, App Store (~separate playbook)

---

## Total effort summary

| Phase | Effort |
|---|---|
| 0. Setup | 1 evening |
| 1. Whole-house continuous capture | 3 weeks |
| 2. Outdoor capture | 2 weeks |
| 3. Object tagging | 1 week |
| 4. Project management + sync | 1 week |
| 5. Mac app foundations | 1 week |
| 6. 2D renderer | 2-3 weeks |
| 7. PDF export + branding | 1 week |
| 8. Touch-up editor + verified dimensions | 2 weeks |
| 9. Real-world testing | 2 weeks |
| **TOTAL** | **~16-18 weeks part-time** |

**Fastest usable path (Phases 0>1>4>5>6>7):** ~9-10 weeks to scanning whole houses and exporting Roomio-quality PDFs. Then layer on outdoor, tagging, and editor.

---

*Document updated 2026-05-18 v2. This is the source of truth for the build.*
