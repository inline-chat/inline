# Native math implementation

Vendored subset of mgriebling/SwiftMath 1.7.3, commit
`fa8244ed032f4a1ade4cb0571bf87d2f1a9fd2d7` (MIT; see LICENSE-SwiftMath.txt).
Original paths: `Sources/SwiftMath/MathRender/*.swift` for the eight copied
parser/model/typesetter/font files. No upstream UI/image helpers are included.

Local changes replace platform colors/paths with Core Graphics, remove obsolete
iOS compatibility/debug drawing, bound parser recursion/table cells and glyph
assembly work, and add a bounded raster entry point. Font creation uses validated immutable bundled data
and Core Text directly, without process-wide font registration or UI font APIs.
Mutable upstream objects never cross the serial InlineMath actor boundary.

Input hardening rejects unsupported characters/colors instead of silently
dropping source. Named basic colors and exact six-digit RGB hex are supported.
Local correctness fixes cover nested row-separator indexing, Unicode command
arguments, empty/structured color wrappers, overline-script finalization and
matrix-cell finalization. Typesetting resource failures propagate to the caller
instead of asserting or substituting an undersized glyph.

Only unmodified Latin Modern Math and its matching math table are bundled.
The font's GUST Font License and the upstream bundle's MIT notice are retained in
`Sources/SwiftMathCore/mathFonts.bundle/`. GUST incorporates LPPL 1.3c or later:
https://www.latex-project.org/lppl/lppl-1-3c.txt
No other SwiftMath fonts are shipped, and no font-selection API is exposed.

Original SHA-256:

- latinmodern-math.otf: `6075562b771f8b82f0c179e363389684f2dd09de30038269e2628e504bd7be0f`
- latinmodern-math.plist: `201e6a483783415f335328f2d02b356fe55cd478eb0cd052898236589c8cb946`

MathTextProjection keeps canonical UTF-16 source separate from attachment text.
Only successful formula ranges are replaced; selection/copy maps back to TeX.
It is bounded to 64 replacements and 131,072 UTF-16 units per projection.

Display and inline math are connected to the existing native rich renderers;
canonical TeX is retained for fallback, selection and copying. Inline projection
runs after canonical block slicing and native styling. The shipped resource bundle
includes the SwiftMath MIT notice. Package tests
and the `inline-math-probe` executable exercise raster/baseline, input budgets,
malformed and valid generated formulas, colors, cache, selection and concurrency.
The probe writes `/tmp/inline-rich-text-v2-math-contact-sheet.png` and prints
local timing JSON. These checks do not prove native layout, scrolling, selection,
accessibility, device behavior, or safety for every possible TeX input.
