# Unchanged Maple font, split only for transfer

These five binary files are consecutive slices of the original
`MapleMonoNormal-NF-CN-Regular.ttf`. Splitting and concatenation do not modify,
subset, rename or re-encode the font. `../OFL.txt` and `../NOTICE.md` retain the
original copyright, SIL OFL 1.1 license and exact source provenance.

Before **any** Flutter package resolution, test or build from this chunked
validation candidate, run from the repository:

```
python tool/ci/reassemble_maple_font.py
```

The command has no download or alternative source. It accepts only the fixed
local chunk directory and order in `chunks.json`, verifies each chunk's size,
SHA-256 and Git blob digest, then checks the pinned original size
20,563,672 bytes and SHA-256
`9ae0c348a44a681fa8fa20a34e782e95316cec880102295a128b65760944c0f5`.
Only fully verified bytes are atomically written to
`assets/fonts/maple/MapleMonoNormal-NF-CN-Regular.ttf`. An existing different
file is rejected, not overwritten. `--verify-only` checks the reconstructed
font without writing it. This does not install a font into the OS.

The isolated `candidate-validation.yml`, ordinary Windows
`codex-parity-windows.yml`, and signed `custom-update-release.yml` workflows
reassemble before package resolution. All retain their existing tracked-source
or validation gates. The two Windows build jobs also recheck the source font
before packaging and verify the bundled font's exact size and SHA-256 afterward.
The signed workflow's separate Linux publication job reassembles locally before
package resolution and verifies it again before its existing signing step.
The generated TTF is a verified build input; Git's tracked-source check alone
cannot validate that untracked file.

Other build workflows still require the same explicit reassembly command before
package resolution or must restore the original byte-identical TTF as a tracked
file. This wiring does not itself approve or complete a release: existing tests,
build, installation, signature and publication gates remain required. Do not
upload or install a partially assembled file, suppress integrity failures, or
substitute another font.
