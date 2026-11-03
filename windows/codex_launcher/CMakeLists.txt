cmake_minimum_required(VERSION 3.14)
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
  project(codex_owned_launcher LANGUAGES CXX)
endif()

# A console-subsystem helper with piped stdio; CreateProcess hides its child.
# Keep it beside baocode.exe. The parent Windows CMake owns installation.
function(add_codex_launcher TARGET)
  add_executable(${TARGET} "main.cpp")
  if(COMMAND apply_standard_settings)
    apply_standard_settings(${TARGET})
  else()
    target_compile_features(${TARGET} PRIVATE cxx_std_17)
    if(MSVC)
      target_compile_options(${TARGET} PRIVATE /W4 /WX /EHsc)
    endif()
  endif()
  if(MSVC)
    target_compile_options(${TARGET} PRIVATE /utf-8)
  endif()
  target_compile_definitions(${TARGET} PRIVATE
    "UNICODE" "_UNICODE" "NOMINMAX" "WIN32_LEAN_AND_MEAN"
    "_WIN32_WINNT=0x0A00" "WINVER=0x0A00"
    "_DISABLE_CONSTEXPR_MUTEX_CONSTRUCTOR")
endfunction()

add_codex_launcher(BaocodeCodexLauncher)

# Never installed. These binaries test fail-closed setup without any switch in
# the production helper, launch environment, user directory, or Codex account.
option(BAOCODE_LAUNCHER_TESTS "Build isolated ownership failure fixtures" OFF)
if(BAOCODE_LAUNCHER_TESTS)
  add_codex_launcher(BaocodeCodexLauncherRejectJob)
  target_compile_definitions(BaocodeCodexLauncherRejectJob PRIVATE
    BAOCODE_LAUNCHER_TEST_REJECT_JOB)
  add_codex_launcher(BaocodeCodexLauncherRejectMembership)
  target_compile_definitions(BaocodeCodexLauncherRejectMembership PRIVATE
    BAOCODE_LAUNCHER_TEST_REJECT_MEMBERSHIP)
endif()
