# macOS handoff: bring Melissa's Jerome into the iOS app

## Why this work belongs on macOS

Do this change on macOS with Xcode. The implementation is mostly SwiftUI and
assets, but the important work is visual: Xcode must import and render the SVG,
the app must be exercised in an iOS simulator, and the widget and share card
need native previews. Linux is useful for inspecting the repository, but it
cannot give trustworthy answers about Xcode's SVG handling or the final iOS
rendering.

## Outcome

Replace the placeholder camel in the iOS water screen with the refined Jerome
Melissa drew, while keeping the app's existing orange, oasis-blue, and ink
palette and all existing water interaction behavior.

The result must stay very close to Melissa's actual drawing. Do not redraw it
as a generic camel with a few Bezier curves.

## Source of truth

- Use [`deploy/web/melissa-jerome.svg`](../deploy/web/melissa-jerome.svg) as the
  final visual reference. This is the refined v2 trace after the website work
  to keep the tail and both front legs fillable and the gap between the front
  legs dry.
- That file was derived from
  [`assets/melissa-jerome/2026-07-18-melissa-jerome-v2.svg`](../assets/melissa-jerome/2026-07-18-melissa-jerome-v2.svg).
  The original v2 JPG beside it is useful for checking details in the drawing.
- Do not use `2026-07-18_melissa-jerome.svg` or
  `deploy/web/melissa-jerome-v1.svg`; those are the earlier napkin version.
- `assets/melissa-jerome/2026-07-18-melissa-jerome-filled.png` is a visual
  acceptance reference, not the artwork to ship in the app.

The web file is not itself a suitable drop-in Xcode asset. It contains web CSS
animation and an embedded PNG fill mask. Reuse its refined visible vector trace
and its proven silhouette, but keep animation and coloring under SwiftUI's
control.

## Required implementation

Start in [`ios/Drome/Views/CamelView.swift`](../ios/Drome/Views/CamelView.swift).
Preserve its public contract exactly:

```swift
CamelView(fill: Double, celebrating: Bool)
```

Keep all of these behaviors:

- Clamp `fill` to `0...1`.
- Fill Jerome from bottom to top with the existing two gently animated waves.
- Keep the empty portion as Jerome's orange trace rather than a solid body.
- Keep the celebration bounce/wiggle.
- Keep the percentage accessibility label.
- Keep the entire rendered camel as the drag target used by `WaterView`.
- Use the design-system colors (`dromeCamel`, `dromeOasis`, and `dromeInk`),
  with no new color literals in Swift feature views.

Use the actual refined trace for the visible artwork. A practical approach is:

1. Create a cropped, self-contained SVG asset containing the visible refined
   trace from `deploy/web/melissa-jerome.svg`. Remove the web-only style,
   animation, mask, and background. Give it a fixed fill suitable for original
   rendering, or make it a template only if Xcode preserves the details when
   tinted. Preserve vector data in the asset catalog.
2. Create a second, identically cropped alpha mask for Jerome's fillable
   interior. The website's mask is already the accepted silhouette. It may be
   extracted as a high-resolution alpha image if converting it to a clean
   vector would change the shape; the visible outline must remain vector.
3. Render the existing SwiftUI wave stack through that mask, then overlay the
   refined vector trace. Both layers must use the same bounds, aspect ratio,
   and `scaledToFit` behavior so they cannot drift apart.
4. Keep the current SwiftUI timeline, fill animation, and celebration motion.
   Do not rely on animation inside the SVG.

If Xcode's SVG importer changes or drops details, render the refined trace with
a small, local SVG renderer or convert the trace to equivalent Core Graphics
paths. Do not replace it with a newly sketched approximation. Avoid a new
third-party dependency unless the native asset route demonstrably fails.

The accepted website SVG uses `viewBox="540 150 2480 2800"`; preserve that crop
for both the visible trace and the mask. Expect the new art to be much taller
than the placeholder's `100 x 80` design space. Update `CamelGeometry` (or
remove it if assets provide the layout) so `CamelView` reports the source
aspect ratio. Check that `WaterView`'s existing `maxHeight: 280`, horizontal
padding, drag distance, and the controls below still feel usable on the
smallest supported iPhone.

## Shape-specific acceptance criteria

These details have already needed correction on the website and must not
regress in iOS:

- Jerome's long neck, head, hump, jointed legs, and tail retain Melissa's
  proportions and irregular hand-drawn character.
- The visible trace is smooth at native iPhone scale, with no jagged raster
  outline or rough clipping fringe.
- The tail fills with water.
- Both front legs fill with water.
- The negative-space gap between the two front legs remains empty.
- Water does not fill the exterior space to the left of the front legs.
- At `fill == 0`, there is no blue water.
- At `fill == 1`, the body, tail, and all four legs are filled without blue
  escaping the silhouette.
- Jerome remains legible in both light and dark appearance.

Add or retain previews for at least `0`, `0.35`, `0.72`, and `1.0`, plus the
celebrating state. Inspect partial fill levels that cross the feet, front-leg
gap, belly, tail, neck, and head; checking only empty and full will miss mask
errors.

## Other Jerome surfaces

Do a consistency pass on the two remaining placeholder camel drawings:

- [`ios/DromeWidget/WaterWidget.swift`](../ios/DromeWidget/WaterWidget.swift)
  has its own `CamelSilhouette` for the compact water gauge.
- [`ios/Drome/Views/ShareCardView.swift`](../ios/Drome/Views/ShareCardView.swift)
  has a separate `CamelMarkShape` in the share-card header.

The main `CamelView` must use the near-exact refined trace. For the much smaller
widget and share mark, a simplified derivative is acceptable only where the
full trace becomes illegible; it should still clearly inherit Melissa's head,
neck, hump, legs, tail, orientation, and proportions. Do not leave the old
generic right-facing camel in either surface. Keep the widget self-contained
rather than importing an app-only view.

## Build and visual verification

Before editing, read the repository `CLAUDE.md` and `docs/ARCHITECTURE.md`, then
confirm the working tree so unrelated changes are preserved. New items inside
the existing asset catalog should not require hand-editing the synchronized
Xcode groups.

Use a private Derived Data directory:

```bash
xcodebuild \
  -project ios/Drome.xcodeproj \
  -scheme Drome \
  -destination 'platform=iOS Simulator,name=Chart35iPhone' \
  -derivedDataPath /tmp/drome-jerome-derived \
  build
```

If that named simulator is not installed, select an available iPhone with
`xcrun simctl list devices available` and substitute its name. Launch the
seeded water screen with these debug arguments:

```text
-drome-demo-seed -drome-screen water
```

Also inspect `-drome-screen share`, and preview the small and medium water
widgets. Verify on the smallest available iPhone as well as a current standard
iPhone, in light and dark appearance. Exercise drag-to-pour and the preset
buttons rather than treating this as a static screenshot change.

Finish with:

```bash
git diff --check
git status --short
```

Keep the commit limited to Jerome's iOS assets/views and any documentation that
must change with them. Do not alter the Rust core, website, analytics/privacy
behavior, or upload a TestFlight build as part of this task unless separately
requested.
