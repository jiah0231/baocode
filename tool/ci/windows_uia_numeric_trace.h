#ifndef BAOCODE_WINDOWS_UIA_NUMERIC_TRACE_H_
#define BAOCODE_WINDOWS_UIA_NUMERIC_TRACE_H_
#if !defined(BAOCODE_DISPOSABLE_UI_TEST_BUILD) || !defined(BAOCODE_SCOPED_UIA_TIMING_TRACE)
#error This collector is exclusively for explicitly enabled disposable CI builds.
#endif
#if defined(BAOCODE_CAPTURE_FOREGROUND_CONNECTION_EXPERIMENT) || defined(BAOCODE_CAPTURE_TEST_PREPARED_CLIENT)
#error Scoped timing capture must not be mixed with root or prepared-client experiments.
#endif
#include <windows.h>
#include <memory>
#include <optional>
namespace uia_numeric_trace {
// Tool modes only enable the private zero-payload probe provider, or clean up
// one supplied session identity. They never enable UIAutomationCore.
std::optional<int> ToolMode(int argc, wchar_t** argv);
// Holds the exact PowerShell-launched process instance for the whole fixture.
class BrowserIdentity {
 public:
  BrowserIdentity(const wchar_t* pid, const wchar_t* created, const wchar_t* exact_path);
  ~BrowserIdentity();
  BrowserIdentity(const BrowserIdentity&) = delete;
  BrowserIdentity& operator=(const BrowserIdentity&) = delete;
  bool Matches(HWND source) const;
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
class CaptureTrace {
 public:
  CaptureTrace(HWND verified_source, const wchar_t* receipt, const wchar_t* session_id, const BrowserIdentity& browser);
  ~CaptureTrace();
  CaptureTrace(const CaptureTrace&) = delete;
  CaptureTrace& operator=(const CaptureTrace&) = delete;
  void MarkCaptureStart();
  void MarkCaptureEnd();
  bool Finish();
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
}  // namespace uia_numeric_trace
#endif
