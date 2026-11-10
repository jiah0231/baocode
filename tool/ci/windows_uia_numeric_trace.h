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
class CaptureTrace {
 public:
  CaptureTrace(HWND verified_source, const wchar_t* receipt, const wchar_t* session_id);
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
