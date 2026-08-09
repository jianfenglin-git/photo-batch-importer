# Pre-compiled app icon

`Assets.car` and `PhotoImporter.icns` compiled from `../PhotoImporter.icon` by
`actool`, checked in so `Scripts/build_mas.sh` can produce a submittable app on
a machine with only the Command Line Tools installed.

## Why this exists

`actool` ships only with the full Xcode (~3 GB), and it is the *only* thing that
turns an Icon Composer `.icon` bundle into `Assets.car`. Substituting a flat
full-bleed `.icns` is not equivalent: macOS 13+ reads the icon from `Assets.car`
and does **not** round icon corners at display time, so a flat image shows as a
hard **square** in the Dock and Launchpad. That was the bug v1.0.1 shipped to
fix — regressing it is worse than failing the build.

These bytes were extracted from the signed `Photo Batch Importer.pkg` for
1.0.5 (build 11), which `actool` from Xcode 26.3 produced. Nothing about the
icon has changed since, so recompiling would be a no-op.

## Staleness guard

`source.sha256` is a digest over every file in `../PhotoImporter.icon`. The
build script recomputes it and **refuses to use this cache if it differs**,
because a stale `Assets.car` would ship the *old* artwork with no visible
warning — the build would succeed and the icon would silently be wrong.

## Regenerating (only needed after editing the icon)

On a machine with full Xcode:

    Scripts/build_mas.sh                      # uses actool, ignores this cache
    Scripts/build_mas.sh --refresh-icon-cache # ...and updates it for CLT machines

`--refresh-icon-cache` rewrites both artifacts and `source.sha256` together, so
they cannot drift apart.
