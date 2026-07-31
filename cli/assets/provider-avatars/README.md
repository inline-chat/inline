# Provider avatar defaults

The server-usable runtime contract is the four canonical PNG files in this directory:

- `codex.png`
- `claude.png`
- `opencode.png`
- `amp.png`

Every runtime avatar is a square 512 x 512 PNG, kept below the bridge's 512 KiB upload limit. Setup embeds these files and updates an existing avatar only while it is still managed by Inline; a user-customized avatar is preserved. Claude uses the approved opaque RGB `249, 248, 244` background rather than transparency.

The matching SVG files are source/reference previews. Codex and OpenCode remain vector; Claude and Amp reference their canonical raster PNG because their approved sources are raster artwork. Claude's supplied ZIP is an animated pet spritesheet, which the current bot-profile photo API does not support.
