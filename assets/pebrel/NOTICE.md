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
retained by the snapshot model. Applying a color theme intentionally preserves
BaoCode's layout, font and window-effect settings. Native geometry/effects and
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
