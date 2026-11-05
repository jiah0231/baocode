# Pebrel themes in BaoCode

Adapted on 2026-11-04 from Kuddev/pebrel commit
`e4a4c02ebbae8d73ea99b0818708633d004ce4a5`:
https://github.com/Kuddev/pebrel/tree/e4a4c02ebbae8d73ea99b0818708633d004ce4a5

Source files: `nebula_settings/src/themes.rs`, `custom_theme.rs`, and the
ThemeName/terminal definitions in `nebula_settings/src/lib.rs`, plus the native schema adapter
`nebula_app/src/theme_library/document.rs`.
Pebrel's nebula_settings crate is GPL-3.0-or-later. The complete GPL v3 text
is included in LICENSE. These derived assets and the Pebrel app adapter are
GPL-3.0-or-later, not part of the MIT-licensed bao_editor/bao_xterm packages.

Changes: palette snapshots converted into JSON; theme display names spaced;
VS Code-compatible app colors and syntax token mappings supplied by BaoCode.
Original UI and terminal colors remain separate. All 256 indexed colors,
optional terminal marks, typography, geometry, effects and unknown fields are
retained by the snapshot model. Typography rendering overrides preserve the
user's saved editor and terminal preferences; layout and window-effect settings
are unchanged. Native geometry/effects and
custom indexed 16–255 overrides are retained for the terminal renderer.
The adapter accepts BaoCode snapshots and Pebrel schema-v1 JSON documents;
original documents and unknown fields are retained on export. Non-color effects
and geometry are stored but not automatically applied.

The pinned source excerpts are in tool/pebrel/upstream. Regenerate the built-in
catalog offline with `python3 tool/pebrel/generate.py` from the repository root.

Catppuccin palette: Copyright (c) 2021 Catppuccin; MIT license retained in
CATPPUCCIN-LICENSE. https://github.com/catppuccin/palette
Nord: Copyright (c) 2016-present Sven Greb <development@svengreb.de>;
MIT license retained in NORD-LICENSE. https://github.com/nordtheme/nord
The legacy light terminal fallback originates from Pebrel's GitHub Primer
Light-derived LIGHT_ANSI; its source comments are retained in the excerpt.

## Typography adaptation (BaoCode)

Explicit enabled typography fields now render in BaoCode. Font family, size,
weight (nearest Flutter hundred-weight), line height, letter spacing and
ligatures apply to code surfaces; UI family and base size apply to workbench
text. UI base size scales relative to 13 logical pixels and composes with system
accessibility scaling and window zoom. Code size is compensated for that UI
base-size factor so an explicit 15 remains 15 before accessibility/zoom.
Terminals consume family, size, weight, line height and letter spacing. Terminal
line height has a renderer minimum of 1; smaller values remain lossless in the
document and apply to code. Terminal ligatures remain disabled because this
renderer shapes individual cells; no unsupported shaping is claimed.

A separate, opt-in “Pebrel screenshot typography” preset supplies Maple Mono
Normal NF CN, 15px, weight 400, 1.45 line height and zero added letter spacing,
plus a 15px UI base size. This is BaoCode's screenshot-inspired preset, not
metadata supplied by each of the sixteen upstream color palettes. Explicit
document fields win over preset defaults; enabled=false disables the overlay.
Absent fields retain user preferences. Legacy built-in ligatures=true is a
model default and does not override a user's disabled ligatures by itself.
Preview/cancel and switching to ordinary themes remove the rendering overlay
without rewriting editor.* or terminal.* settings.

The unchanged Maple font asset is registered only within the application. See
assets/fonts/maple/OFL.txt and NOTICE.md for its independent SIL OFL license,
upstream commit, size and SHA256. There is no system installation, background
download, font modification, subsetting or font rename. Imported unavailable
families fall back through the user's font stack and platform/system fonts;
font availability is not inferred from a family name.
