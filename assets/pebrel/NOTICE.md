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

Font family, weight (nearest Flutter hundred-weight), line height, letter
spacing and ligatures can be supplied explicitly by an imported theme. UI
family applies to workbench text. Terminals consume family, weight, line height
and letter spacing; their renderer requires line height of at least 1 and
shapes individual cells, so terminal ligatures remain disabled.

Font sizes always follow BaoCode's existing editor, terminal and interface
settings. Imported font_size and ui_font_size remain lossless on export but do
not override those settings. No theme multiplier is added to system text
scaling or window zoom.

The optional global Maple Mono Normal NF CN choice changes font families only,
for all themes. It takes precedence over theme font-family fields without
rewriting editor.* or terminal.* preferences. Turning it off restores the
existing font choices. It does not set a 15px size, weight, line height, letter
spacing or ligature preference. Preview/Cancel restores both the global font
selection and the original theme. The new baocode.mapleFont boolean takes
precedence over the legacy baocode.pebrelTypographyPreset key; explicit false
must be saved to disable a legacy true. Legacy settings are read, not rewritten.

The unchanged Maple font asset is registered only within the application. See
assets/fonts/maple/OFL.txt and NOTICE.md for its independent SIL OFL license,
upstream commit, size and SHA256. There is no system installation, background
download, font modification, subsetting or font rename. Imported unavailable
families fall back through the user's font stack and platform/system fonts;
font availability is not inferred from a family name.
