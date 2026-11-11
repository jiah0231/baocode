"""One controlled build-configuration experiment; original assertions unchanged."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import subprocess

SHA = "1308fb3b70328aea8ca549ef4d1a287865d413da"
SCRIPT = "tool/ci/windows_translation_desktop_entry_smoke.ps1"
COMPILE = "  & cl.exe /nologo /std:c++17 /EHsc /W4 /WX /wd4100 /utf-8 /DUNICODE /D_UNICODE /DNOMINMAX /DBAOCODE_TRANSLATION_ACTION_DIAGNOSTICS `\n    $source $implementation /Fe:desktop_entry_smoke.exe /link user32.lib gdi32.lib dwmapi.lib advapi32.lib ole32.lib oleaut32.lib uiautomationcore.lib uuid.lib\n"
MODES = ("legacy-diagnostic", "legacy-quiet", "release-diagnostic", "release-quiet")

def native_project(cmake_source, diagnostics):
    functions = re.findall(r"(?ms)^function\(APPLY_STANDARD_SETTINGS TARGET\).*?^endfunction\(\)", cmake_source)
    if len(functions) != 1:
        raise ValueError("Cannot extract unique actual runner standard settings")
    function = functions[0]
    required = ('cxx_std_17', '/W4 /WX', '/EHsc', '"_HAS_EXCEPTIONS=0"', '"_DISABLE_CONSTEXPR_MUTEX_CONSTRUCTOR"')
    if not all(part in function for part in required):
        raise ValueError("Runner compile settings changed")
    return '\n'.join([
        'cmake_minimum_required(VERSION 3.14)',
        'project(baocode_entry_parity LANGUAGES CXX)',
        'add_definitions(-DUNICODE -D_UNICODE)', function,
        'add_executable(desktop_entry_smoke',
        '  "${BAOCODE_SOURCE_ROOT}/tool/ci/windows_translation_desktop_entry_smoke.cpp"',
        '  "${BAOCODE_SOURCE_ROOT}/windows/runner/translation_selection_action.cpp")',
        'apply_standard_settings(desktop_entry_smoke)',
        'target_compile_options(desktop_entry_smoke PRIVATE /utf-8)',
        'target_compile_definitions(desktop_entry_smoke PRIVATE "NOMINMAX")',
        'target_compile_definitions(desktop_entry_smoke PRIVATE "BAOCODE_TRANSLATION_ACTION_DIAGNOSTICS")' if diagnostics else '# No diagnostic definition: same as the shipped native source.',
        'target_link_libraries(desktop_entry_smoke PRIVATE user32 gdi32 dwmapi advapi32 ole32 oleaut32 uiautomationcore uuid)',
        '',
    ])

def variant(source, mode, cmake_source):
    if mode not in MODES or source.count(COMPILE) != 1:
        raise ValueError("Unknown mode or altered original compiler invocation")
    if mode == "legacy-diagnostic":
        replacement = COMPILE
    elif mode == "legacy-quiet":
        replacement = COMPILE.replace(" /DBAOCODE_TRANSLATION_ACTION_DIAGNOSTICS", "")
    else:
        project = native_project(cmake_source, mode.endswith("diagnostic"))
        replacement = "\n".join([
            "  $nativeProject = @'", project.rstrip(), "'@",
            "  [IO.File]::WriteAllText((Join-Path $root 'CMakeLists.txt'), $nativeProject)",
            "  $sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path",
            "  $buildRoot = Join-Path $root 'native-release-build'",
            '  & cmake -S $root -B $buildRoot -A x64 "-DBAOCODE_SOURCE_ROOT=$sourceRoot"',
            "  if ($LASTEXITCODE -ne 0) { throw 'Native Release parity configure failed' }",
            "  Copy-Item -LiteralPath (Join-Path $root 'CMakeLists.txt') -Destination (Join-Path $output 'parity-CMakeLists.txt')",
            "  Copy-Item -LiteralPath (Join-Path $buildRoot 'desktop_entry_smoke.vcxproj') -Destination (Join-Path $output 'parity-compile.vcxproj')",
            "  & cmake --build $buildRoot --config Release --verbose",
            "  if ($LASTEXITCODE -ne 0) { throw 'Native Release parity build failed' }",
            "  Copy-Item -LiteralPath (Join-Path $buildRoot 'Release/desktop_entry_smoke.exe') -Destination $testExe",
            "",
        ])
    result = source.replace(COMPILE, replacement, 1)
    if result.replace(replacement, COMPILE, 1) != source:
        raise ValueError("Non-compiler test content changed")
    return result, replacement

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("checkout", type=Path)
    parser.add_argument("mode", choices=MODES)
    args = parser.parse_args()
    root = args.checkout
    def git(*arguments):
        return subprocess.check_output(["git", "-C", str(root), *arguments])
    if git("rev-parse", "HEAD").decode().strip() != SHA:
        raise ValueError("Wrong baseline SHA")
    if git("status", "--porcelain").strip():
        raise ValueError("Baseline checkout is not pristine")
    path = root / SCRIPT
    original = path.read_bytes()
    normalized = original.replace(b"\r\n", b"\n")
    if normalized != git("show", SHA+":"+SCRIPT).replace(b"\r\n", b"\n"):
        raise ValueError("Baseline test script changed")
    source = normalized.decode()
    cmake = (root / "windows/CMakeLists.txt").read_text(encoding="utf-8")
    output, replacement = variant(source, args.mode, cmake)
    newline = b"\r\n" if b"\r\n" in original else b"\n"
    result = output.encode().replace(b"\n", newline)
    path.write_bytes(result)
    changed = git("diff", "--name-only").decode().splitlines()
    expected = [] if args.mode == "legacy-diagnostic" else [SCRIPT]
    if changed != expected:
        raise ValueError("Changes exceeded the compiler-only boundary")
    print(json.dumps({"baseline": SHA, "mode": args.mode, "modifiedPaths": changed,
        "originalScriptSha256": hashlib.sha256(original).hexdigest(),
        "variantScriptSha256": hashlib.sha256(result).hexdigest(),
        "originalHarnessAndAssertionsUnchanged": True,
        "nativeProductionSourcesUnchanged": True,
        "note": "Native harness only, not the full shipped Flutter executable. Legacy-required release gate is unchanged."}))

if __name__ == "__main__":
    main()
