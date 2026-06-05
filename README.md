# Photo Batch Importer

Native macOS app for importing photos from SD/CF cards with EXIF-driven naming
rules. Pure SwiftUI + Foundation — no WebView, no bundled exiftool, no Node, 
small and fast.

## Features

- Auto-detect inserted/ejected removable volumes (`NSWorkspace` notifications).
- EXIF photo properties via macOS `ImageIO` — JPEG, TIFF, PNG, HEIC, CR2/CR3, 
  NEF, ARW, DNG, RAF, and everything else the system supports natively.
- Persistent monotonic sequence counter across runs.
- Template-driven naming with properties for date, time, camera, lens, exposure,
  file name, sequence counter, card label.
- Sor-table, multi-select photo table (Cmd/Shift-click for modifier select),
  live "Destination file name" preview column.
- Option to verify copied files with SHA-256 and confirm no data loss, 
- JPG+RAW dual-format pair detection to use same sequence number for matching pairs.
- Collision policies: skip-if-identical, rename, overwrite, skip-all.
- Post-import deletion with confirmation to free up card space.
- One-click eject (manual or automatic after import).
- Free-space check before copying.
- Settings saved to iCloud and sync-ed across devices.

## Privacy

Three things go to the user's private iCloud (via NSUbiquitousKeyValueStore):
  
  1. Saved presets (PresetStore, key presets)
  The full list of named naming-rule presets — each preset's name and its template rules (file-type + template string).

  2. Sequence counter (SequenceStore, key sequence.lastSeq)
  The monotonic {seq} watermark — a single integer — so the counter keeps climbing across your devices.

  3. Import options (SyncedOptions, key options.v1)
  Four behavior toggles: collisionPolicy, verify, deleteAfter, autoEject.

  What is NOT synced — stays device-local in UserDefaults (LocalFormState, key formState.v1):
  - activePresetID (which preset is currently selected)
  - rules (the in-progress template rules in the editor)
  - destination — the destination folder path (a security-scoped path wouldn't resolve on another Mac)
  - The card-access paths from CardAccessStore (also local)
  - Window size/position
  
  No photos, no file contents, no metadata ever sent to the cloud — only these small settings saved in the user's private iCloud.


## Build

Requires macOS 14+ and the Xcode Command Line Tools:

```sh
./Scripts/build_app.sh            # produces build/Photo Batch Importer.app
./Scripts/build_app.sh --debug    # faster iteration build
```

The build script:

1. `swift build -c release` via Swift Package Manager
2. Wraps the resulting Mach-O into `build/Photo Batch Importer.app` with proper
   `Contents/MacOS/`, `Contents/Resources/`, and `Contents/Info.plist`.

## Run

```sh
open "build/Photo Batch Importer.app"
```

The app is unsigned — macOS Gatekeeper will complain on first launch. Either
right-click → Open, or:

```sh
xattr -rd com.apple.quarantine "build/Photo Batch Importer.app"
```

## Mac App Store build

`Scripts/build_mas.sh` produces a sandboxed, signed `Photo Batch Importer.app`
and a signed installer `Photo Batch Importer.pkg` for upload to App Store
Connect.

```sh
./Scripts/build_mas.sh        # → build/Photo Batch Importer.pkg
```

One-time prerequisites in your login keychain / repo:

- **Apple Distribution** identity — signs the `.app`.
- **3rd Party Mac Developer Installer** identity — signs the `.pkg`.
- **Apple WWDR G3** intermediate cert — completes the chain. Without it
  `security find-identity -v -p codesigning` reports *0 valid identities*
  even though the certs import fine. Install from
  <https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer>.
- A **Mac App Store** provisioning profile at
  `certs/Photo_Importer.provisionprofile` (override with `PROFILE=…`).

The script signs with the entitlements in `Resources/PhotoImporter.mas.entitlements`
(App Sandbox + removable-volume RW for card auto-scan + user-selected RW +
app-scope bookmarks + iCloud KV). It builds universal (arm64 + x86_64) when the
full Xcode toolchain is present, otherwise native-arch (set `UNIVERSAL=0` to
force native).

**Note:** a MAS-distribution-signed build **cannot be launched locally** —
`open` fails with "Launchd job spawn failed" because the distribution profile
authorizes no devices. Test the sandboxed runtime via TestFlight after upload.

Upload: install **Transporter** (free, Mac App Store), sign in, drag in
`build/Photo Batch Importer.pkg`, **Deliver**. Each re-upload needs a unique,
increasing `CFBundleVersion` in `Resources/Info.plist`.

## Project layout

```
Package.swift                       Swift Package manifest
Sources/PhotoImporter/
  PhotoImporterApp.swift            @main — SwiftUI.App entry
  Models/
    Domain.swift                    Volume, PhotoFile, Preset, …
    Template.swift                  Naming DSL parser + evaluator
  Services/
    VolumeWatcher.swift             NSWorkspace-driven volume list
    PhotoScanner.swift              ImageIO EXIF extraction
    ImportEngine.swift              Plan + execute + verify
    Deletion.swift                  Post-import unlink
    Eject.swift                     NSWorkspace.unmountAndEjectDevice
    Preflight.swift                 Free-space check
    SequenceStore.swift             Persistent {seq} counter
    PresetStore.swift               Named config persistence
  Views/
    AppViewModel.swift              Single owner of UI state
    ContentView.swift               Root layout + section views
    PhotoTableSection.swift         SwiftUI Table with selection/sort
    Sheets.swift                    Confirm/preflight/preset sheets
    CursorTextEditor.swift          NSTextView wrapper for chip insertion
    FlowLayout.swift                Chip wrapping layout
    TokenCatalog.swift              Chip + all-tokens data
Resources/
  Info.plist                        Embedded in binary + copied to bundle
  AppIcon.icns
Scripts/build_app.sh                Build + bundle into .app
Tests/PhotoImporterTests/           Parked behind the commented test target
```

## Persistent state

- `~/Library/Application Support/PhotoImporter/presets.json`
- `~/Library/Application Support/PhotoImporter/sequence.json`

Both are atomic-written (tmp + rename) JSON. Safe to inspect, back up, or
delete to reset.

## Tests

Tests are written with `swift-testing` (`import Testing`), which ships with
Xcode but not with the plain Command Line Tools. The test target in
`Package.swift` is commented out until you have Xcode installed; re-enable
it and run `swift test`.

Test coverage: template parsing + evaluation (including the `/` sanitization 
regression), import plan (including dual-format JPG+RAW pair detection), 
sequence and preset store persistence, and an ImageIO regression against the 
original test fixtures.
