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
- Sort-able, multi-select photo table (Cmd/Shift-click for modifier select),
  live "Destination file name" preview column.
- Option to verify every copied file against the source and confirm no data
  loss, with a choice of digest: **SHA-256 (safer)** or **xxHash64 (faster)** —
  xxHash64 computes roughly 2.7× faster, which saves ~18 s verifying a full
  64 GB card. Either way the copy's byte count is checked against the source, so
  a card pulled mid-copy is caught rather than silently verified as good.
- JPG+RAW dual-format pair detection to use same sequence number for matching pairs.
- Collision policies: skip-if-identical, rename, overwrite, skip-all.
- Post-import deletion with confirmation to free up card space.
- One-click eject (manual or automatic after import).
- Free-space check before copying.
- Settings saved to iCloud and sync-ed across devices, with a warning under the
  naming template when iCloud is unreachable and the template uses `{seq}` —
  offline, the counter can't sync, so importing from two Macs could collide.

## Privacy

Three things go to the user's private iCloud (via NSUbiquitousKeyValueStore):
  
  1. Saved presets (PresetStore, key presets)
  The full list of named naming-rule presets — each preset's name and its template rules (file-type + template string).

  2. Sequence counter (SequenceStore, key sequence.lastSeq)
  The monotonic {seq} watermark — a single integer — so the counter keeps climbing across your devices.

  3. Import options (SyncedOptions, key options.v1)
  Five settings: collisionPolicy, verify, hashAlgorithm, deleteAfter, autoEject.

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

An *identity* is a certificate **plus its private key**. The `.cer` files in
`certs/` are only the public halves — the keys were generated on the machine
that made the CSR and live in that machine's keychain. `certs/` alone is
therefore **not** a portable signing setup: after an OS reinstall or a move to
a new Mac, either import a `.p12` (cert + key exported together) or revoke and
regenerate from a fresh CSR. Note that the provisioning profile embeds the
distribution certificate, so regenerating that cert also requires re-creating
the profile.

The script signs with the entitlements in `Resources/PhotoImporter.mas.entitlements`
(App Sandbox + user-selected RW + app-scope bookmarks + iCloud KV).

It builds **universal (arm64 + x86_64)** by default. With full Xcode, xcbuild
does both slices in one pass; without it, each slice is cross-compiled via
`swift build --triple <arch>-apple-macosx<LSMinimumSystemVersion>` and merged
with `lipo` — the Command Line Tools SDK carries x86_64 stubs, so no Xcode is
needed. Deriving the triple from `LSMinimumSystemVersion` keeps both slices'
`minos` in agreement, which the App Store requires. Set `UNIVERSAL=0` for a
native-only build.

**Full Xcode is not required.** `actool` (Xcode-only) compiles the Icon Composer
`Resources/PhotoImporter.icon` into `Assets.car`; when it's unavailable the
script uses the pre-compiled copy in `Resources/CompiledIcon`, but only after
verifying its `source.sha256` still matches the icon source — a stale cache is
rejected rather than silently shipping the old artwork. After editing the icon,
regenerate the cache on a machine with full Xcode:

```sh
./Scripts/build_mas.sh --refresh-icon-cache
```

**Note:** a MAS-distribution-signed build **cannot be launched locally** —
`open` fails with "Launchd job spawn failed" because the distribution profile
authorizes no devices. Test the sandboxed runtime via TestFlight after upload.

Upload: install **Transporter** (free, Mac App Store), sign in, drag in
`build/Photo Batch Importer.pkg`, **Deliver**. Each re-upload needs a unique,
increasing `CFBundleVersion` in `Resources/Info.plist`.

This app has been published to macOS App Store and you can install directly from there.

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
    XXHash64.swift                  Streaming XXH64 (non-cryptographic)
    Deletion.swift                  Post-import unlink
    Eject.swift                     NSWorkspace.unmountAndEjectDevice
    Preflight.swift                 Free-space check
    SequenceStore.swift             Persistent {seq} counter
    PresetStore.swift               Named config persistence
    CloudKVStore.swift              iCloud KV sync + reachability
    CardAccessStore.swift           Security-scoped card bookmarks
    FolderRef.swift                 Bookmark-backed folder reference
    Sandbox.swift                   Sandbox helpers
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
  PhotoImporter.icon                Icon Composer source (rounded macOS shape)
  CompiledIcon/                     Pre-compiled Assets.car (no-Xcode builds)
Scripts/
  build_app.sh                      Build + bundle into .app (local dev)
  build_mas.sh                      Signed universal .app + .pkg for the App Store
Tests/PhotoImporterTests/           swift test (47 tests)
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
