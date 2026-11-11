# Icon regeneration task — status (paused 2026-11-10)

## Goal
Replace the hand-drawn app icon in `icon.swift` with a faithful CoreGraphics port of the
new SVG design (dark rounded square `#121214`, red pillar `#E60000`, 3 white keys with
rounded bottoms, 2 black keys, red LED dot; viewBox 512, group offset translate(4,0)).
Ground-truth SVG render saved at `ground-truth.png` (regenerate with
`qlmanage -t -s 1024 -o /tmp nordpiano/icon-work/icon.svg` if gone) — ideally re-save it into the repo.

## Current state
- `icon.swift` `drawIcon(_:)` rewritten to draw in raw SVG units and map to image points
  via a path transform (`flip` / `toDevice`), NOT via `ctx.translate/scale`.
- Builds OK; iconset + icns build OK:
  `swift icon.swift /tmp/nordpiano.iconset && iconutil -c icns /tmp/nordpiano.iconset -o /tmp/nordpiano.icns`
- DONE 2026-11-10: icns generated from the SVG (identical geometry to
  `icon-work/icon.svg`) and installed at `dist/NordPiano.app/Contents/Resources/AppIcon.icns`
  (Info.plist already declared `CFBundleIconFile = AppIcon.icns`). Verified via
  `qlmanage` thumbnail against the artwork. Note: `Sources/NordPianoApp/AppIcon.swift`
  still draws its own approximate icon at runtime — consider replacing it with the
  faithful `drawIcon` port if the runtime path is still used. DONE 2026-11-11:
  `Sources/NordPianoApp/AppIcon.swift` now IS the faithful `drawIcon` port (the
  runtime `applicationIconImage` was overriding the Dock icon with the old
  approximation), so Dock and Launchpad/icons agree everywhere.

## Key lessons learned (don't rediscover these)
1. **Root-cause bug was context pooling**: the old code mutated the CTM inside
   `drawIcon`. `NSImage.lockFocus()` reuses pooled `NSGraphicsContext`s that RETAIN the
   CTM, and the writer loop draws 10 icons per process. `M² = identity`, so even-numbered
   draws rendered unflipped. Always use per-path transforms (current approach) or
   save/restore GState.
2. **Verify by pixel maps, not by viewing images.** `ReadMediaFile` display orientation
   was misleading throughout. Reliable tools written during this session:
   - `nordpiano/icon-work/map.swift <png> <px-per-svg-unit>` — ASCII map of SVG region x150-250/y90-430.
     NOTE: uses `y = svgy * scale` (SVG top-down), x = svgx * scale. Compare against
     ground truth with same scale.
   - `nordpiano/icon-work/diff.swift` — pixel diff (my render 2048 vs svg.png 1024); ~980k/3.1M channels
     differ, max delta 246. Most of that diff is expected: my icon is deliberately opaque
     (full-square dark fill) while the SVG has transparent corners.
   - `nordpiano/icon-work/line.swift` — row value dump at x=190.
   - Swift PNG pixel probing: load via `CGImageSource`, draw into a
     `premultipliedLast` CGContext, sample top-down. `NSBitmapImageRep.colorAt` has
     bottom-left origin — easy to get wrong.
3. Colors must use `CGColor(srgbRed:...)`; plain `CGColor(red:...)` rendered the pillar
   as EE2200 instead of E60000.
4. White keys are drawn as rect (y 112...383, 1-unit overlap to avoid seams) + two
   corner ellipses (r18 at y 382...400). Manual `addArc` under any flip is fragile —
   ellipses are exact.

## Where to resume
1. Re-run the comparison: `swift nordpiano/icon-work/map.swift /tmp/nordpiano.iconset/icon_512x512@2x.png 4`
   vs ground truth (output from last run was looking correct except the key bottom
   extends ~12 units too low — rows y=400-412 show white where ground truth is empty;
   possibly stale file or a real offset bug in the new transform path — VERIFY FIRST).
   If `/tmp` scripts were cleaned, rewrite from the notes above.
2. Fix remaining geometry delta if real; re-run
   `swift icon.swift /tmp/nordpiano.iconset && iconutil -c icns ...`.
3. Install the .icns into the app bundle / build pipeline (previously the script wrote
   only the iconset; check `Package.swift`/build docs for how `dist/NordPiano.app` is
   assembled) and update the app's icon.
4. Delete this file when done.
