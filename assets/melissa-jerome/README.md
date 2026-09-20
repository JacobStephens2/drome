Melissa drew this version of Jerome on a napkin at Sabrina's east of the river in Philly on Sat. July 18 2026.

I used https://github.com/visioncortex/vtracer - the web app version at https://www.visioncortex.org/vtracer/ to create the svg.

Melissa then drew a refined Jerome (`2026-07-18-melissa-jerome-v2.*`): cleaner
lines, a defined eye, jointed legs, and a tail. That v2 trace (same vtracer
process) is what now fills as you drink on drome.day. The napkin v1 is kept as
`deploy/web/melissa-jerome-v1.svg` and stays on the Jerome evolution page.

The live SVG is assembled from the raw vtracer trace: noise paths are dropped and
a body-fill silhouette (for the rising water) is derived by flood-filling the
camel interior, since vtracer traces the ink lines, not the enclosed body.