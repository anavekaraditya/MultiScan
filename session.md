# MultiScan Coding Agent Session

## Project

MultiScan is a cross-platform IMEI scanning system for warehouse device trays. The mobile app scans device labels and sends results to a laptop dashboard, while the dashboard supports live session monitoring and uploaded barcode-sheet processing.

This document records the major decisions, implementation work, debugging history, and current state of the coding-agent session.

## Original Problem

Operators needed to process trays containing many devices and manually scan each IMEI. The goal was to photograph a tray or barcode sheet, detect all available IMEIs, map them to positions, remove duplicates, validate results, and display them on a laptop for review and copying.

The original tray concept was a fixed 3×5 layout, but the requirements later expanded to flexible layouts:

- 15 devices: 3×5
- 24 devices: 4×6
- 64 devices: 4×16
- 112 devices: 8×14

## Architecture

### Mobile application

- Flutter for the cross-platform shell.
- Native iOS VisionKit `DataScannerViewController` for live text and barcode detection.
- Native Swift method channel exposed as `multiscan/vision_scanner`.
- Local scan state and session synchronization handled in Dart services.
- Camera capture, photo-library selection, live scanning, review grid, manual correction, and dashboard synchronization.

### Web dashboard

- FastAPI backend.
- Plain HTML, CSS, and JavaScript dashboard.
- Local in-memory session store for the current prototype.
- Vercel deployment under `vercel/`.
- Local backend copy under `backend/multiscan_api/`.
- Phone results arrive through session batch APIs.
- Uploaded barcode sheets are processed locally in the browser.

### Recognition strategy

- Barcode detection is attempted first for uploaded sheets.
- OCR verification is optional and runs when enabled or when barcode coverage is incomplete.
- Candidates are normalized to 15 digits.
- IMEIs are validated using the Luhn check digit.
- Results are classified as accepted, review, or retake.
- Duplicate values are explicitly surfaced for review in document processing.
- Live scanning globally deduplicates values before creating final grid output.

## Product and UX Decisions

The dashboard was designed for warehouse operators working in bright operational environments. The intended personality is:

- Calm
- Precise
- Dependable

Key UX principles:

1. Trust before speed: show why a result was accepted or held.
2. One clear next action: make the current workflow obvious.
3. Cell-level recovery: one unreadable device should not block the entire tray.
4. Visible progress: show expected, detected, confirmed, and unresolved counts.
5. Bright-room legibility: strong contrast, large controls, short labels, and semantic status colors.

## Mobile UI Work

The mobile app evolved from a demo interface into a production-oriented scanning flow.

Implemented mobile UX includes:

- Simplified MultiScan home screen.
- Figma-inspired visual language and branding.
- Splash screen with the MultiScan logo.
- App icon generated from the supplied barcode-scanning artwork.
- Camera capture screen with:
  - Large central capture button.
  - Back action on the left.
  - Photo-library action on the right.
  - Live scan action.
- Tray review screen with expandable accordion sections.
- Position-based result cells.
- Accepted, review, and retake states.
- Manual IMEI correction for individual cells.
- Session connection to the laptop dashboard.

## iOS Live Scanner

The initial native scanner used Apple Vision and fixed grid processing. It was later replaced and expanded with VisionKit live scanning.

The current native implementation in `mobile/ios/Runner/AppDelegate.swift`:

- Imports VisionKit.
- Registers the live scanner through the existing Flutter plugin method channel.
- Accepts the selected row and column count from Flutter.
- Supports text and barcode recognition simultaneously.
- Uses accurate quality mode and multiple-item recognition.
- Shows the camera feed behind an AR-style overlay.
- Shows amber boxes for provisional detections.
- Shows green boxes for confirmed detections.
- Displays the current detected count.
- Displays the confirmed count.
- Captures for five seconds by default.
- Allows the operator to tap Done before the five-second window ends.
- Captures a high-resolution photo after the live session.
- Maps final unique values into the selected grid order.

### Live layout picker

The Flutter live-scan flow asks the operator to select one of four layouts:

- 15 devices, 3×5
- 24 devices, 4×6
- 64 devices, 4×16
- 112 devices, 8×14

The selected layout is passed through the method channel to Swift. The scanner uses it for progress counts and final output cells.

### Live duplicate removal

Live observations are stored in a dictionary keyed by normalized IMEI value. This removes repeated detections of the same code across frames and removes duplicate values globally from the final output.

If a physical tray contains a duplicate IMEI, the scanner cannot reach the expected number of unique values. In that case, the operator can tap Done and review the missing position rather than allowing the application to falsely claim a complete unique set.

### Live false-positive controls

The native live scanner now:

- Accepts only exactly 15 numeric digits.
- Normalizes common OCR substitutions such as `O`/`o` to zero and `I`/`l` to one.
- Applies IMEI Luhn validation.
- Requires a value to be observed in at least three live updates before it counts as confirmed.
- Places only confirmed observations into the final grid.
- Sorts confirmed values spatially before assigning them to positions, avoiding losses caused by multiple VisionKit boxes quantizing into one cell.

## Dashboard and Session System

The dashboard supports:

- Creating a new session.
- Displaying a six-character session code.
- Connecting the phone using that code.
- Polling session state automatically.
- Receiving phone scan batches.
- Showing accepted IMEI count.
- Showing scan batch count.
- Ending a session.
- Copying IMEIs to the clipboard.
- Viewing IMEI, tray number, position, and source.
- Uploading a barcode sheet from the laptop.
- Choosing a sheet layout before processing.
- Optional OCR verification.
- Reviewing highlighted barcode locations.
- Appending accepted results to the session.

The dashboard flow is represented as:

1. Connect
2. Scan
3. Verify
4. Export

The dashboard activity banner changes based on session state, for example:

- Ready for a phone scan or sheet upload.
- IMEIs received; review below.
- Complete; IMEIs ready.

## Dashboard Processing Animation

The uploaded-sheet workflow has a staged processing experience:

- Preparing the image.
- Reading barcode regions.
- Verifying reads.
- Scan ready.

The processing animation was changed from an abstract spinner to a physical scanner effect over the uploaded image:

- A green scanning line travels vertically across the preview.
- The line includes a restrained glow.
- A `SCANNING IMAGE` label appears over the image.
- Reduced-motion users receive a static alternative.

## Uploaded Barcode-Sheet Processing

The browser-side barcode workflow includes:

- Image upload for JPG, PNG, and WebP.
- Image downscaling to a safe processing size.
- Multiple grid definitions.
- Overlapping tile crops.
- Original and contrast-enhanced passes.
- Multiple crop variants per tile.
- ZXing browser barcode decoding.
- Barcode observation deduplication.
- Optional Tesseract OCR verification.
- Luhn validation.
- Spatial row and column inference.
- Configurable layout selection.
- Highlight boxes over the source image.
- Accepted, review, and missing-slot summaries.
- Copy detected codes.
- Append accepted results to the session.

The browser processing intentionally preserves review candidates instead of silently discarding them. This makes it possible to inspect cases where the barcode engine finds a value but independent confirmation is incomplete.

## Figma Dashboard Implementation

A Figma design was supplied for node `89:171` in file `af6V3WtKjLdOLyCytSitQC`.

The implemented dashboard UI now follows the Figma states:

### New-session state

- MultiScan logo header.
- `Start a new session` heading.
- Short explanation of the phone-to-dashboard workflow.
- Phone-to-laptop illustration.
- `Start session` button.
- Four-step `How it works` explanation.

### Active-session state

- `Your session is active` heading.
- Prominent session code.
- Phone scanning illustration.
- `End session` button.
- Upload image action.
- IMEI code list.
- Copy and clear-list actions.

The implementation preserves the existing JavaScript session, scanning, upload, polling, and append logic. Only the visual structure and asset serving were changed.

Figma-provided assets were added under:

- `vercel/app/assets/`
- `backend/multiscan_api/assets/`

The FastAPI applications now mount these directories at `/assets`.

## Major Debugging History

### Flutter and iOS setup

Problems encountered included:

- Missing Android SDK.
- Missing iOS simulator runtime.
- Missing iOS code-signing certificates.
- Device deployment target mismatch.
- Flutter service protocol connection failures.
- Xcode precompiled application failures.
- Missing `Pods_Runner` framework.
- SQLite module/header issues.
- LLDB startup delays.
- Invalid app icon asset catalogs.
- Swift optional registrar errors.
- Swift actor-isolation errors.
- Swift immutable-value mutation errors.
- Dart bracket and constructor syntax errors.
- ML Kit simulator arm64 incompatibilities.

The ML Kit and Google sign-in dependencies were removed from the active mobile implementation when they prevented reliable iOS builds. Native Apple VisionKit became the iOS live-scanning path.

### Important fixes

- Rebuilt Pods and cleaned Flutter build artifacts.
- Corrected Xcode signing configuration.
- Disabled problematic LLDB debugging when needed.
- Repaired the iOS asset catalog.
- Removed unsupported or unused ML Kit integrations.
- Fixed Swift method-channel registration.
- Fixed Swift concurrency and main-actor handling.
- Fixed immutable Swift value mutations.
- Fixed malformed Dart widget trees.
- Added iOS static asset handling.
- Used `flutter build ios --debug --no-codesign` for reliable compile verification.

## Validation Performed

### Mobile

Flutter analysis completed with only existing unused-widget warnings. No analysis errors remained.

The iOS debug build completed successfully multiple times:

```text
✓ Built build/ios/iphoneos/Runner.app
```

### Web dashboard

JavaScript syntax validation was run against both dashboard copies.

Backend tests passed:

```text
Ran 8 tests
OK
```

Validated tests include:

- IMEI Luhn validation.
- Barcode/OCR agreement.
- Conflict handling.
- Empty-cell retake behavior.
- Tray position generation.
- Accepted IMEI appending.
- Ended-session rejection.
- Idempotent batch retry behavior.

The dashboard copies were synchronized and `git diff --check` passed.

## Current Important Files

### Mobile

- `mobile/lib/main.dart`
- `mobile/lib/services/vision_scanner_service.dart`
- `mobile/lib/services/dashboard_sync_service.dart`
- `mobile/ios/Runner/AppDelegate.swift`
- `mobile/assets/multiscan_logo.png`

### Dashboard

- `vercel/app/dashboard.html`
- `vercel/app/main.py`
- `vercel/app/session_store.py`
- `vercel/app/domain.py`
- `vercel/api/index.py`
- `vercel/vercel.json`
- `backend/multiscan_api/dashboard.html`
- `backend/multiscan_api/main.py`
- `backend/multiscan_api/session_store.py`
- `backend/multiscan_api/domain.py`

## How to Run Locally

### Dashboard

From the project root:

```bash
python3 -m uvicorn backend.multiscan_api.main:app --host 127.0.0.1 --port 8000
```

Open:

```text
http://127.0.0.1:8000/dashboard
```

### Mobile

```bash
cd mobile
flutter pub get
flutter run
```

For an iOS debug build:

```bash
flutter build ios --debug --no-codesign
```

For physical iPhone testing, use Xcode signing and an Apple development team, or run through Flutter with the phone connected and trusted.

## Current Limitations

- The backend session store is in memory and is not durable across restarts.
- The Vercel deployment is not a permanent database-backed production system.
- Live scanning uses the fixed five-second capture window.
- A physical duplicate IMEI reduces the number of unique live results and requires manual completion.
- Exact production accuracy still requires a labeled dataset covering every tray layout and difficult operating condition.
- The browser image processor still depends on browser-loaded ZXing and optional Tesseract assets.
- The dashboard's clear-list action currently clears the visible local list; server-backed session data remains managed by the existing session logic.

## Recommended Next Steps

1. Add durable storage for hosted sessions.
2. Add authentication and session ownership.
3. Add a dedicated result-review workflow for unresolved cells.
4. Add explicit duplicate policy and duplicate-location display.
5. Add automated browser tests for the dashboard flow.
6. Benchmark each supported tray layout with labeled images.
7. Measure false accepts, unresolved cells, processing time, and retake rate.
8. Add deployment smoke tests for Vercel assets and API routes.
9. Add Android recognition after the iOS pipeline is stable.
10. Prepare a release build and TestFlight distribution workflow.

