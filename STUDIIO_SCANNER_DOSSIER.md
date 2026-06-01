# Studiio Scanner — Research Dossier & Build Plan

*Prepared for Pete, May 2026. Covers competitive research on Roomio and CubiCasa, the technical pipeline that turns iPhone LiDAR into a finished floor plan, and a recommended architecture and build plan for your own iOS-only scanning app.*

---

## TL;DR — the honest assessment

Building a Roomio-class app on iPhone is **realistic for a solo founder with a Swift developer's help** because Apple has done most of the hard work for you. The framework that powers Roomio (and which you saw in your screenshots — the purple wall overlay and white mesh on the ceiling is the unmistakable Apple `RoomCaptureView` UI) is called **RoomPlan**. It ships free with iOS, runs entirely on-device, and emits a clean parametric model of a room with walls, doors, windows, openings, and ~16 furniture categories. The hard part of "scan a room and get geometry" is solved.

The hard part of building a **business** is everything around it:

1. Turning that parametric model into a *marketing-grade* PDF floor plan that a real-estate agent will pay for (this is where Roomio's human-finishing step sits, and where you'll either copy them or beat them with automation).
2. ANSI Z765 compliance for GLA (Gross Living Area) — the US standard Fannie Mae now requires for appraisals. This is CubiCasa's moat in the US market; less relevant for Australian real estate.
3. Multi-room stitching across a whole house without the corridors bending.
4. Distribution. CubiCasa wins because it's plumbed into 30+ US MLS systems and now Realtor.com (Jan 2026). Roomio wins on Australian pricing (A$15 per plan) and branded outputs.

You said you spend "hundreds per year" on scans. If that's $500/year and CubiCasa-style pricing is $20-30 per scan, you're doing 15-25 scans annually. The break-even on building your own is **not the personal cost saving** — it's whether you can sell it to other photographers and agents at $10-15 a plan and capture the Australian volume Roomio is going after.

**My recommendation:** build a focused MVP — iOS-only, LiDAR-only, single-room and multi-room scanning, parametric output rendered to PDF and SVG, manual touch-up step on a Mac/web companion, pay-per-plan pricing model. Defer GLA / ANSI / DXF / 3D rendering until you have paying users. Budget: 3-5 months of full-time Swift dev work for a solid v1.

---

## 1. The two competitors — at a glance

| | **Roomio** | **CubiCasa** |
|---|---|---|
| Company | Phoria Pty Ltd, Melbourne AUS (founded 2014 as XR/AR studio; Roomio launched ~mid-2025) | CubiCasa Oy, Oulu Finland (founded 2014); acquired by Clear Capital (USA) Sept 2021 |
| Founders | Trent Clews-de Castella (CEO), Steven Kounnas (COO) | Harri Pesola, Jarmo Lumpus, Petra Söderling |
| Headcount | ~35 | ~96 |
| Target user | Real estate agents + photographers (AUS-first, US-expanding) | Real estate agents, photographers, appraisers, B2B partners |
| Platform | iOS only, **LiDAR-required** (iPhone 12 Pro+) | iOS + Android; LiDAR boosts accuracy ~36% but is optional |
| Scanning tech | Almost certainly Apple **RoomPlan** + ARKit (inferred from outputs and accuracy claims) | **Proprietary CV pipeline** trained on their CubiCasa5K dataset; cloud-side AI + human QA |
| Scan time | ~5 min for a 3-4 bed home | ~5-10 min |
| Delivery | Human-drafted; 12-24h standard, 8-10h express | Human-QA'd; <24h for 2D, <48h for 3D |
| Output formats | PNG, JPG, SVG (2D); rendered 3D view; AI property report; site plan | PDF + SVG + PNG (2D); DWG + DAE + FBX + OBJ (3D/CAD); MP4 walkthrough; **ANSI Z765 GLA** report |
| Pricing | **Pay-per-plan: A$15** base; +A$5-20 for 3D; +A$15 GLA; +A$20 express | Pay-per-scan: **$9.99 entry, $22.99-29.99 standard**; free for MLS partners; ~$15 rush add-on |
| Pricing model | Pay-as-you-go (no subscription) | Pay-per-order, free tier for first scan, free for partners |
| Differentiator | Cheap, branded, AUS-first, fast, all-in-one bundle | ANSI-compliant GLA, MLS distribution, partner API (Integrate), 30+ MLS integrations, Realtor.com (Jan 2026) |
| Funding | Seed-stage (CP Ventures); amount undisclosed | Pre-acquisition ~$325K seed; now part of Clear Capital (PE-backed by GTCR) |

---

## 2. Roomio — deep dive

### What it is
Roomio is essentially a **packaged Apple RoomPlan front-end with a human drafting service behind it**, sold pay-per-plan to Australian real estate agents and photographers. Phoria — the parent — is a long-running AR/VR studio in Melbourne with serious ARKit credentials (their portfolio includes a Telstra/IBM digital twin of the City of Melbourne and an Attenborough/WWF/Netflix VR piece). Roomio is their first SaaS-style productisation of that capability.

### Features
- LiDAR scan via iPhone Pro / iPad Pro (12 Pro or later)
- 5-minute scan for a 3-4 bed house
- **Combined interior + exterior scan in one capture** (yields a site plan when exterior is included — notable, because Apple RoomPlan officially supports indoor only; Phoria likely fuses ARKit raw mesh for the outdoor portion)
- Custom branding — agency logo, agent details, custom disclaimer baked into the delivered plan
- Multiple custom floor plan templates per account
- Total floor area in m² or ft²
- Fixtures and appliances marked
- AI-generated written property description
- Multi-user accounts (invite teammates to one account)
- Web portal at `app.roomio.io` for desktop order management
- Live in-scan progress visualisation — reviewers call this the "game changer"

### Outputs
- 2D plan: **PNG, JPG, SVG**
- Optional 3D plan view with furniture/colour/textures (extra cost)
- Site plan when exterior is captured
- AI property report (text)
- No DXF, no IFC, no native PDF mentioned in their official copy (but some search results mention PDF — unclear).
- Not instant. 12-24h standard; 8-10h express.

### Pricing
- Standard 2D plan: **A$15**
- 3D add-on: +A$5 to +A$20 (sources inconsistent — one newer article says a "Plus 3D" bundle is A$99/48h)
- GLA report add-on: A$15
- Express 10h: A$20
- WGAN forum members: 2 free plans
- **No subscription** — pay only when you order, scanning is free

### Tech stack inference
Phoria has not publicly stated their stack, but the evidence is overwhelming for **Apple RoomPlan + ARKit**, finished with a human drafter on a desktop tool, then exported to branded SVG/PNG/JPG:

- LiDAR-only device requirement = same as RoomPlan
- Pro-device-only floor = same as RoomPlan
- 1-2 cm accuracy claim = matches RoomPlan's published performance
- Indoor + outdoor in one capture = inferring they fuse `RoomCaptureSession` with ARKit `ARMeshAnchor` (Apple's scene reconstruction) outside, because RoomPlan alone won't do outdoor
- The screenshots in your `Screens/` folder show the classic RoomPlan `RoomCaptureView` UX: translucent coloured fill on detected walls + white textured mesh on the ceiling + "Complete scan" CTA. The purple tint is a custom brand colour applied to the standard view.

### Company / leadership
- **Trent Clews-de Castella** — CEO, Phoria co-founder, AR/VR veteran, Radford College Canberra (2007)
- **Steven Kounnas** — COO/CFO, same cohort
- HQ Fitzroy, Melbourne
- Crunchbase: seed-stage, CP Ventures as most recent investor, amount undisclosed

### App Store / reviews
- AU listing: `apps.apple.com/au/app/roomio-floor-plan-creator/id6752274376`
- US listing also live
- Rating signals are early and small-sample (AppRecs reports 3.0 stars on low volume; visible 5-star reviews praise the LiDAR accuracy and in-scan progress view)
- Common complaint: one user reported scans picking up only small sections; dev responded that a non-LiDAR version is in development

### Why it works (and what's vulnerable)
**Working for them:** ruthlessly focused product (one job: cheap fast branded floor plans), Australian-market focus where CubiCasa has thin presence, undercutting CubiCasa on price by ~50%, all-in-one pricing where competitors charge piecemeal for branding/site plan/property report.

**Vulnerable to:** anyone who can do the same drafting step automatically without humans (collapses their cost structure and their turnaround), anyone who plumbs into Australian real estate portals (REA Group, Domain) the way CubiCasa plumbed into US MLS.

---

## 3. CubiCasa — deep dive

### What it is
CubiCasa is the industry-standard cloud floor-plan service for US real estate. You scan a property with your phone, upload, and within 24 hours a human-QA'd, ANSI-compliant 2D floor plan comes back. They've expanded into 3D, CAD exports, GLA reports for appraisers, an embedded SDK for partners, and an AI-generated interactive virtual tour (CubiCasa Tour, launched 2024).

### Ownership chain (important — there's misinformation online)
- **2014** founded in Oulu, Finland
- **2021** acquired by Clear Capital (Nevada-based valuation tech firm)
- **2025** Clear Capital received strategic investment from PE firm GTCR
- **January 14, 2026** Realtor.com (Move Inc., a News Corp subsidiary) announced an **integration partnership** that puts CubiCasa floor plans and Tours on Realtor.com listings. This is *not* an acquisition by Realtor.com / News Corp — CubiCasa remains owned by Clear Capital. Some online sources also incorrectly say Zillow acquired CubiCasa; that didn't happen.

### Product line
- Mobile scanning app (iOS + Android)
- 2D floor plans (PDF, SVG, PNG)
- 3D floor plans / models (DWG, DAE, FBX, OBJ)
- CAD package (2D DWG + 3D DWG + DAE/OBJ/FBX) — works with AutoCAD, SketchUp, Revit, 3ds Max, Archicad, Blender, Chief Architect, BricsCAD, Cedreo
- **Digital GLA** — ANSI Z765-2021 compliant Gross Living Area report (the appraiser-grade product)
- **CubiCasa Tour** — AI-generated interactive virtual tour from the same scan, with auto-placed photos
- Walkthrough video (MP4)
- **CubiCapture SDK** — open-source iOS + Android sample apps (`github.com/CubiCasa/cubicasa-ios-sdk-example-project`); partners embed this, capture the scan bundle, upload to CubiCasa
- **Integrate API** — REST API for plugging scans into your own workflow
- **GoToScan** — hosted scan link (no SDK needed)

### How the scan works
- Walk around for 5-10 minutes, 15-20 seconds per room
- Sensors required: ARKit (iOS) or ARCore (Android) — i.e. **does not require LiDAR**, that's optional
- With LiDAR, accuracy improves ~36% over the non-LiDAR baseline
- Captures RGB video + visual-inertial SLAM pose + depth (where available) + voice-labeled room names

### Pipeline
1. Phone uploads the scan bundle to CubiCasa's cloud
2. Cloud reconstructs a **point cloud** from frames + AR pose data
3. Proprietary **deep-learning models** (descended from their open-source **CubiCasa5K** research — 5,000 annotated plans, 80+ object classes, published at SCIA 2019) detect walls/doors/windows/fixtures/rooms
4. Generates 2D vector floor plan, then derives 3D, CAD, GLA
5. **QA engineer manually reviews every plan** before delivery — this is the human-in-the-loop step they have not yet replaced with pure AI

### ANSI Z765 — what it is and why it matters
ANSI Z765-2021 is the American National Standards Institute's standard for measuring single-family residential floor area. **Effective April 1, 2022, Fannie Mae requires ANSI-Z765-aligned plans for appraisals it purchases** — and CubiCasa was the first phone-scanning product approved by both Fannie Mae and Freddie Mac for appraisal modernisation. Key rules:

- Detached homes: measure **exterior** wall to exterior wall
- Condos / attached: measure **interior** perimeter
- Ceilings ≥ 7 ft to count; ≥ 50% of a sloped-ceiling room must be ≥ 7 ft; nothing under 5 ft counts
- Exclude voids/openings to floor below (two-story foyers, voids over stairs)
- Report to nearest whole sq ft

**Implication for you:** if you target the US market and want appraisers as customers, you must compute and certify GLA to ANSI Z765. This is non-trivial because RoomPlan gives you wall *centerlines*, and you must offset by an assumed wall thickness to derive the exterior. The Australian market does not have an equivalent legal standard, which is why Roomio can ship without one.

### Pricing (US, individual buyers)
- Free first 2D scan in the US
- Entry plans from ~$9.99
- Standard 2D in the $22.99-$29.99 range (Tekpon / GetApp / Capterra)
- Add-ons: 3D upgrade, fixed-furniture, GLA add-on, 6-hour rush (~$15), CAD bundle
- **Free** for MLS members through dozens of partner portals, and now Realtor.com (Jan 2026)
- Volume discounts for high-volume customers

### Strengths
Speed, low hardware requirement (works on any modern phone), ANSI compliance, MLS distribution, strong B2B/API channel, AI-tour add-on now competitive.

### Weaknesses (per real-user reviews)
- Accuracy drops on old houses with unusual or curved walls, non-orthogonal layouts
- Sometimes misses islands, mislocates doors, classifies outdoor fences as living area
- **Editing workflow is rigid** — can't easily delete misplaced walls or selectively include square footage
- Not instant — 6-24h wait
- Older non-ARCore Android devices unsupported
- No offline mode

### Competitive position
- **vs Matterport** — Matterport is higher fidelity, but needs dedicated 3D cameras and is expensive; CubiCasa wins on price + speed + ANSI compliance.
- **vs Zillow 3D Home** — Zillow is free but lower-fidelity, tied to Zillow listings; CubiCasa has the better floor plan.
- **vs Polycam** — Polycam is a stronger general 3D scanner, but lacks real-estate workflow (no ANSI, no MLS).
- **vs magicplan** — direct on phone-based plans, both ANSI-capable; magicplan is more DIY/manual sketch, popular in restoration/contractor segments.
- **vs Apple RoomPlan-only apps (SecondFloor, RoomScan Pro, Roomio)** — fast but no human QA, no ANSI, no GLA report.

---

## 4. Your screenshots — what they show

The three screenshots in `Screens/` show a real LiDAR scan in progress on what looks like your own home (kitchen, dining bar with stools, hallway). All three are the canonical Apple **RoomPlan `RoomCaptureView`** UI with the standard Phoria/Roomio purple brand colour applied:

- **Top chrome:** small red dot + "Scanning…" text + X (cancel)
- **Camera passthrough:** the live RGB feed of the room
- **Detected surfaces overlay:** translucent purple fill on every wall/floor/cabinet RoomPlan has classified as a structural surface
- **White textured mesh** on the ceilings — this is ARKit's raw `ARMeshAnchor` reconstruction rendered as a wireframe / dot pattern. RoomPlan apps often show this layer because RoomPlan itself doesn't capture ceilings; showing the raw mesh gives the user useful visual feedback that the device is tracking, even where there's no parametric surface to highlight.
- **Bottom:** large pill-shaped purple "Complete scan" button — Apple's recommended CTA, restyled

**These screenshots tell me:** Roomio is running standard `RoomCaptureView` with light customisation (purple tint, brand colour on the CTA). Your own app can replicate this UX in a couple of days of Swift work — Apple even provides the entire scanning view as a drop-in `RoomCaptureView` SwiftUI/UIKit component. The differentiation is everything *after* the user taps Complete scan.

---

## 5. The LiDAR → floor plan technical pipeline

This is the section that matters most for your build. Read it carefully — it's the spine of the rest of this doc.

### 5.1 The iPhone LiDAR sensor

A time-of-flight (ToF) infrared sensor on the back of every iPhone Pro (12 Pro through 17 Pro) and every iPad Pro since 2020. It fires an IR dot grid, measures bounce time, and gives ARKit a **256×192 depth map per frame at up to ~60 Hz**, with absolute accuracy roughly ±1 cm on objects > 10 cm.

Reliable range: ~5 m on iPhone 12 Pro through 14 Pro; ~10 m on iPhone 15 Pro / 16 Pro / iPad Pro M4. iPhone 17 Pro (Sept 2025) has an upgraded module with better low-light and resolution.

**Failure modes** to design around: direct sunlight, glass and mirrors (mirrors create phantom geometry, glass is invisible), matte black surfaces, glossy stone floors, very long walls > 5 m, fast camera motion.

### 5.2 Apple RoomPlan — the framework that does 90% of the work

`RoomPlan` is a Swift framework that wraps ARKit + LiDAR + on-device ML and gives you a clean parametric model. **This is the framework that Roomio almost certainly uses, that Polycam uses, that magicplan uses, that almost every iOS scanner app uses.**

**Requirements:** iOS 16+ for single room, iOS 17+ for multi-room. LiDAR device (12 Pro+, iPad Pro 2020+).

**What it detects:**
- Surfaces: `wall`, `door`, `window`, `opening`, `floor`
- 16 object categories: `storage`, `refrigerator`, `stove`, `oven`, `dishwasher`, `table`, `sofa`, `chair`, `bed`, `sink`, `washerDryer`, `toilet`, `bathtub`, `fireplace`, `television`, `stairs`
- iOS 17 added: door open/closed state, curved-wall representation

**Data model:** A scan produces a `CapturedRoom` Swift struct containing arrays of `Surface` and `Object`. Each element is a *parametric* 3D-oriented bounding box with `transform`, `dimensions`, `category`, and `confidence`. For multi-room, `StructureBuilder.capturedStructure(from: [CapturedRoom])` merges rooms into a `CapturedStructure`.

**Export:** `CapturedRoom.export(to:, exportOptions:)` writes USDZ / USD / USDA. Options are `.parametric` (clean boxes), `.mesh` (raw mesh), or `.all`. You can also `Codable`-encode the struct directly to JSON, which is what you'll want for your own rendering pipeline.

**Licensing:** RoomPlan ships free as part of iOS SDK under the Apple Developer Program License Agreement. No per-scan fee. Commercial App Store apps using it are explicitly allowed.

**Known limitations** (these are the boundaries of what RoomPlan can do for you):
- Max single-room footprint **~9 m × 9 m**; bigger and it throws `CaptureError.exceedSceneSizeLimit`
- Max session length ~5 min
- Min lighting ~50 lux
- **No ceiling capture** — just walls/floors/doors/windows/openings
- Walls **snap to 90°** if close — out-of-square rooms are lost
- Curved walls are approximated as segmented chains, often with gaps
- **No support** for mezzanines, split levels, half walls, kitchen islands as walls, balconies, outdoor

### 5.3 When you'd drop down to raw ARKit
If you need ceilings (for ceiling height per room), non-rectilinear walls, balconies, half-walls, or your own segmentation: use `ARWorldTrackingConfiguration.sceneReconstruction = .meshWithClassification`. You then handle `ARMeshAnchor` (semantic-tagged mesh) and `ARFrame.sceneDepth` (raw depth map) yourself. This is what Roomio almost certainly does for the outdoor/site-plan portion of their scan.

### 5.4 From `CapturedRoom` to a printable floor plan PDF

This is the algorithmic part you'll be writing. RoomPlan gives you walls as 3D oriented bounding boxes; you need a clean 2D drawing. Steps:

1. **Project each wall to the floor plane** — drop the Y axis, get a 2D line segment per wall
2. **Build a 2D wall graph** — snap collinear walls, snap near-90° corners, close gaps under tolerance (~5 cm)
3. **Render wall thickness** — draw walls as twin parallel lines with hatching or a filled offset (typical interior wall ~100-150 mm, exterior ~200-300 mm)
4. **Insert door and window symbols** — doors as arc swings from a detected hinge, windows as double lines inside the wall thickness
5. **Label dimensions** — running dimensions on each wall, overall room W×L, room name
6. **Compose plan layout** — title block, scale bar, north arrow, legend
7. **Export to PDF** — use `PDFKit` + SwiftUI `ImageRenderer` (iOS 16+) to render straight to vector PDF, or send the parametric JSON to a Mac/server companion that renders SVG/PDF with more typography control

### 5.5 Multi-room stitching
Two paths:
- **RoomPlan MultiRoom (iOS 17+)**: scan rooms in sequence; walk through doorways without lifting the device; call `StructureBuilder.capturedStructure(from:)`. Works best for single-floor homes ≤ ~186 m² (~2000 ft²), 1-4 bedrooms.
- **Your own stitching**: save an `ARWorldMap` between rooms, relocalize, run your own alignment. Necessary for multi-floor or commercial.

Even Apple's MultiRoom introduces visible distortion (corridors bend, corners separate by a few cm). Most professional apps run a post-merge cleanup pass.

### 5.6 Accuracy
- Per-wall length: typically ±1-3 cm on walls under 5 m, in good conditions
- GLA out of RoomPlan: 2-5% error
- CubiCasa claims < 1% GLA error with cloud + human QA
- Apple's own published RoomPlan metrics: **91% precision / 90% recall** on furniture categories at IoU ≥ 0.3

### 5.7 What's truly hard
The problems that will eat your time:
- Multi-floor scans (RoomPlan has no native "floor 1 vs 2" — you split sessions and stack manually)
- Mezzanines, voids over double-height rooms, split levels
- Irregular / non-rectilinear / curved walls
- Half walls, kitchen islands, partitions, breakfast bars
- Door swing direction / sliding / pocket doors (not detected)
- Outdoor balconies, patios, terraces (RoomPlan is indoor-only)
- Mirrors, large glazing, glass doors
- Reconciling wall centerline geometry with ANSI exterior measurement
- Multi-room merging without warping corridors

---

## 6. Recommended architecture for Studiio Scanner

### 6.1 Stack at a glance
- **Platform:** iOS only, iPhone 12 Pro+ / iPad Pro 2020+
- **Language:** Swift 5.10+ / Swift 6
- **Frameworks:** RoomPlan, ARKit, RealityKit, PDFKit, SwiftUI
- **Min iOS:** 17.0 (gets you MultiRoom out of the box)
- **Backend (Phase 2):** lightweight Node/Bun + Postgres + S3 for scan storage + Stripe; or Supabase + Stripe to skip a backend
- **Auth:** Sign in with Apple + email
- **Payments:** RevenueCat on top of StoreKit 2 if you go in-app purchase; or Stripe if you go web checkout (App Store rules — IAP is mandatory for digital deliverables, so plan for it)

### 6.2 Capture flow
1. User opens app → Sign in with Apple → "New scan" → enter property address (optional)
2. Show capture screen: drop in `RoomCaptureView`, restyled with your brand colour
3. User scans room 1 → taps Complete → preview parametric model in RealityKit
4. User taps "Add room" → walks through doorway without lifting device → scans room 2 → repeat
5. Final stitch: `StructureBuilder.capturedStructure(from:)`
6. User sees a 3D preview of the whole house in RealityKit
7. Optional manual touch-up: drag walls, rename rooms ("Master bedroom"), tag doors/windows

### 6.3 Plan generation
- On-device: pipe `CapturedStructure` JSON → your renderer → PDF via `PDFKit`
- 2D vector plan with: walls (with thickness), doors (arc), windows (double line), openings (gap), room labels + areas, overall dimensions, title block, scale bar, north arrow, your branding
- Optional 3D view: render the parametric USDZ in RealityKit, export USDZ for AR Quick Look
- Square area calculation: sum each room's interior polygon (centerline minus assumed wall thickness)

### 6.4 Output formats
**MVP:** PDF + SVG + USDZ
**v2:** PNG, JPG, DXF (use a Swift DXF writer or convert from SVG server-side)
**Phase 3:** ANSI Z765 GLA report (US only), CAD bundle, 3D rendered furniture view, AI property description

### 6.5 Backend / storage
Phase 1 (no backend, pure iOS): scans live on-device, share via iOS share sheet or AirDrop. Cuts your build time in half.
Phase 2: optional cloud sync, multi-device access, web download links, billing.

### 6.6 Branded templates (Roomio-style)
Store branding as JSON: `{ logo: ..., agentName: ..., agency: ..., phone: ..., disclaimer: ... }`. At render time, your PDF generator composes the template with the user's branding overlay. This is where Roomio earns its A$15 — they sell **branded, marketing-ready** plans, not raw RoomPlan output.

### 6.7 Manual finishing — your strategic choice
The single biggest product decision: do you do **fully automated** delivery (instant, no human, like an Apple RoomPlan-only app) or **human-in-the-loop** (12-24h, like Roomio and CubiCasa)?

- **Fully automated** — much cheaper to operate (no human labour), instant gratification, but the plans will look "raw" compared to Roomio's finished output. Hard to charge A$15 for what users perceive as a 30-second auto-generation.
- **Human-in-the-loop** — better-looking plans, can charge more, but you need to staff drafters (or do it yourself). Roomio is doing this. CubiCasa is doing this.

My recommendation: **start fully automated** with a good template + clean rendering, charge less (A$5-10), prove demand, then add a "Pro plan" tier that's human-finished at A$15-20.

---

## 7. MVP scope (3-5 months, one developer)

### Must-have for v1.0
- iOS app, iOS 17+, iPhone Pro / iPad Pro only
- Sign in with Apple
- Single-room scan + multi-room scan via RoomPlan
- 3D preview in RealityKit
- 2D floor plan auto-rendered to PDF (walls, doors, windows, openings, room labels, dimensions, total area)
- USDZ export for AR Quick Look
- Share sheet for PDF/USDZ
- Settings: agency name, agent name, logo upload, default disclaimer
- Branded PDF template (logo + agent details overlaid on plan)
- In-app purchase: pay per plan (A$10 launch price?)
- TestFlight beta with 5-10 real photographers/agents

### Explicitly out of scope for v1
- Android
- Non-LiDAR devices
- DXF, IFC, CAD outputs
- ANSI Z765 GLA report
- Multi-floor stitching
- AI property description
- Site plan / exterior capture
- 3D rendered furniture view with textures
- Backend / cloud sync
- Subscription tiers
- Team / multi-user accounts
- Web portal

These are all good Phase 2 / Phase 3 features. Don't build them in v1.

---

## 8. Build plan & timeline

Assuming one full-time Swift developer (or you + a contracted iOS dev), and aiming for a TestFlight beta in **month 4** and App Store launch in **month 5**.

### Month 1 — Foundations
- Project setup, SwiftUI scaffold, sign-in-with-apple, settings screens
- Drop in `RoomCaptureView`, restyle to brand colour
- Single-room scan flow + parametric preview in RealityKit
- Save/load `CapturedRoom` JSON
- Build basic 2D renderer: walls + doors + windows + room labels → SwiftUI Canvas

### Month 2 — Multi-room + PDF
- MultiRoom via `StructureBuilder`
- Stitching cleanup pass (snap angles, close gaps)
- PDF renderer via `PDFKit` + `ImageRenderer`
- Dimension labels, scale bar, north arrow, title block
- Area calculation per room + total
- Branded template composition (logo + agency details)

### Month 3 — Polish + monetisation
- USDZ export + AR Quick Look
- In-app purchase: pay-per-plan via StoreKit 2 + RevenueCat
- Onboarding screens, sample scans, tutorial overlay
- Error states (room too big, low light, lost tracking)
- Manual touch-up: drag walls, rename rooms, edit dimensions
- Comprehensive QA — test on 10 real properties of varied layouts

### Month 4 — TestFlight beta
- Invite 5-10 real estate photographers / agents
- Iterate on feedback for 3-4 weeks
- Build in-app feedback flow
- Marketing site at studiioscanner.com (or similar)
- Privacy policy, terms, App Store screenshots

### Month 5 — Launch
- App Store submission (expect 1-2 rejection cycles around IAP / privacy)
- Soft launch in Australia first
- Outreach to AUS real estate photographer Facebook groups, WGAN forum
- Refine pricing based on early data
- Plan Phase 2: cloud sync + web portal + DXF export

---

## 9. Cost estimate

### Build (Phase 1 → launch)
- **Solo founder + contractor**: A$40-80K for 4-5 months of Swift dev, depending on rate (assumes 0.5-1.0 FTE senior iOS contractor at A$100-150/hr part-time)
- **You build it yourself with AI assistance**: time, not money. Realistic for a determined non-developer paired with Claude / Cursor / Xcode + 6-8 months
- **Two co-founders (you + a developer for equity)**: A$0 cash, equity split
- Apple Developer Program: US$99/year
- TestFlight: free
- Stripe / RevenueCat: ~1-2.5% of revenue

### Operating (per month, first 1000 plans/month)
- App Store fee: 30% on first US$1M, 15% after — or 15% if you're in the small-business program (under US$1M/year). At A$10/plan × 1000 = A$10K revenue, Apple takes A$1.5-3K
- Backend (when you add it): A$50-200/month on Supabase / Render / Fly.io
- Email / notifications: A$30/month
- Domain + marketing site hosting: A$30/month
- **Floor: ~A$200/month to operate v1 if no human-finishing step**
- If you add human drafting: 1 drafter doing 10 plans/day at A$30/hr × 8h = A$240/day = ~A$5K/month for 200 plans

### Break-even
At A$10/plan auto-finished, the marginal cost per plan is near zero. After Apple's cut you keep ~A$7-8.50. **Break-even on a A$50K build is ~6000-7000 plans sold.** At Roomio's pricing of A$15 with human drafting at ~A$24 in labour per plan, they need volume *and* automation to grow margin.

---

## 10. Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Apple changes RoomPlan API or restricts commercial use | Low | High | Keep an ARKit fallback path; monitor WWDC each June |
| RoomPlan accuracy not good enough for paying customers | Medium | High | Run a 20-property accuracy benchmark before launch; budget for human-finishing tier |
| Australian real estate market won't pay for an unbranded competitor to Roomio | Medium | High | Undercut on price (A$10 vs A$15), better turnaround (instant vs 12-24h), better UX |
| App Store rejection (in-app purchase rules around digital deliverables) | Medium | Medium | Use IAP from day one, no Stripe-for-digital-content workarounds |
| Customer support / drafting becomes a labour sinkhole | High (if human-finishing) | Medium | Start auto-only; add human tier only after volume is proven |
| Privacy concerns over uploading interior photos | Medium | Medium | Keep MVP on-device; if cloud, encrypt at rest + clear retention policy |
| Roomio launches a non-LiDAR / Android version first | High | Medium | Track their releases; LiDAR-only is a defensible *premium* product, lean into accuracy |
| CubiCasa enters AUS market seriously | Medium | High | Build relationships with REA Group, Domain, AUS-specific MLS equivalents early |

---

## 11. What I'd build differently from Roomio / CubiCasa

If you want to actually *beat* them rather than just clone them, a few angles worth considering:

1. **Instant delivery, no human in the loop.** A clean auto-renderer + good template can produce a 90%-as-good plan in 30 seconds. Speed is a feature.
2. **AUS-portal integration.** Plumb directly into REA Group (realestate.com.au) and Domain listing flows. CubiCasa won the US on MLS distribution; same play is open in AUS.
3. **AR walkthrough for buyers, not just the plan.** Export USDZ that a buyer can drop on their living room floor via AR Quick Look — "see if your couch fits". CubiCasa Tour is moving in this direction but it's a separate web viewer; native AR Quick Look is a stronger consumer experience.
4. **Reno calculator.** Detect wall area, multiply by paint coverage rates; detect floor area, multiply by typical flooring costs. "Renovate this room for ~A$X" — useful for both agents (marketing) and renovators.
5. **iPad Pro for photographers.** A photographer holding an iPad Pro gets a much bigger viewfinder + better scan stability + same A14 Bionic. Lean into the "pro photographer" segment with iPad-optimised UI.

---

## 12. Where to start tomorrow

Concrete next moves, in order:

1. **Buy/borrow an iPhone Pro** if you don't have one (12 Pro minimum; ideally 15 Pro+ for the longer LiDAR range)
2. **Download Apple's official RoomPlan sample app** — runs straight from Xcode, lets you feel the capability before writing any code: https://developer.apple.com/documentation/roomplan
3. **Watch the two WWDC sessions** — they're the best 60 minutes of education on this stack:
   - WWDC22: *Create parametric 3D room scans with RoomPlan*
   - WWDC23: *Explore enhancements to RoomPlan* (covers MultiRoom)
4. **Sign up for Apple Developer Program** (US$99/yr) so you can run on a real device and ship to TestFlight
5. **Hire a contracted senior iOS dev for 20 hours** to set up the project scaffold, in-app-purchase, and a basic single-room scan + PDF export — that gets you to the point where you can iterate on rendering and UX yourself
6. **Scan 10 of your own listings** with the official RoomPlan sample app, compare the auto-generated parametric output side-by-side with what Roomio and CubiCasa give you for the same property — this is your reality check before committing real money
7. **Pick a name and grab the domains.** "Studiio Scanner" (your folder name) is fine; check `.com.au` and `.com`

---

## Appendix A — key sources

### Roomio / Phoria
- https://roomio.io/
- https://roomio.io/articles/cubicasa-alternative-roomio/
- https://roomio.io/articles/polycam-alternative-roomio/
- https://roomio.io/articles/how-much-do-floor-plan-apps-cost-in-2026-complete-pricing-guide/
- https://apps.apple.com/au/app/roomio-floor-plan-creator/id6752274376
- https://www.phoria.com.au/
- https://au.linkedin.com/company/phoria
- https://www.crunchbase.com/organization/phoria
- https://www.wegetaroundnetwork.com/topic/21485/roomio-app-review-quick-and-easy-floorplans-with-your-phone/
- https://www.youtube.com/watch?v=7nnB2rwc5p0 (full-house scan walkthrough)

### CubiCasa / Clear Capital
- https://www.cubi.casa/
- https://www.cubi.casa/pricing/
- https://www.cubi.casa/developers/
- https://www.cubi.casa/cubicasa-gla-follows-ansi-standards/
- https://github.com/CubiCasa
- https://github.com/CubiCasa/CubiCasa5k
- https://arxiv.org/abs/1904.01920 (CubiCasa5K paper)
- https://www.clearcapital.com/clear-capital-completes-acquisition-of-cubicasa/
- https://aimgroup.com/2026/01/14/realtor-com-adds-cubicasa-floor-plans-tours/
- https://apps.apple.com/us/app/cubicasa-2d-3d-floor-plans/id1439879192

### Apple RoomPlan / ARKit
- https://developer.apple.com/documentation/roomplan/
- https://developer.apple.com/documentation/roomplan/capturedroom
- https://developer.apple.com/documentation/roomplan/capturedstructure
- https://developer.apple.com/documentation/roomplan/scanning-the-rooms-of-a-single-structure
- https://developer.apple.com/augmented-reality/roomplan/
- https://developer.apple.com/videos/play/wwdc2022/10127/
- https://developer.apple.com/videos/play/wwdc2023/10192/
- https://machinelearning.apple.com/research/roomplan
- https://developer.apple.com/documentation/arkit/ardepthdata
- https://developer.apple.com/documentation/swiftui/canvas

### ANSI Z765 / GLA
- https://www.mckissock.com/blog/appraisal/understanding-gross-living-area/
- https://plansnapper.com/learn/ansi-z765-square-footage-standard
- https://singlefamily.fanniemae.com/media/30266/display

### Comparisons / benchmarks
- https://www.it-jim.com/blog/apple-roomplan-api/
- https://www.it-jim.com/blog/roomframework-by-apple/
- https://www.it-jim.com/blog/comparison-of-ios-applications-for-3d-reconstruction/
- https://www.insiderealestatephotography.com/post/cubicasa-matterport-floor-plans-how-accurate-are-they
- https://www.wegetaroundnetwork.com/topic/19262/benchmarking-floor-plans-matterport-zillow-cubicasa-and-urbanimmersive/
- https://www.nature.com/articles/s41598-021-01763-9 (iPhone 12 Pro LiDAR scientific evaluation)

---

*End of dossier. Last updated: 2026-05-18.*
