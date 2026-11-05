#ifndef RUNNER_DOCUMENT_PREVIEW_HOST_H_
#define RUNNER_DOCUMENT_PREVIEW_HOST_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

#include <cstdint>
#include <functional>
#include <memory>

// Offline, read-only Office preview controllers. No login environment, native
// host objects, generic JavaScript evaluation, workspace mapping or network.
// Channel: baocode/document_preview. Bounds are client physical pixels.
class DocumentPreviewHost {
 public:
  DocumentPreviewHost(flutter::BinaryMessenger* messenger,
                      std::function<HWND(int64_t)> window_for_view);
  ~DocumentPreviewHost();
  DocumentPreviewHost(const DocumentPreviewHost&) = delete;
  DocumentPreviewHost& operator=(const DocumentPreviewHost&) = delete;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_DOCUMENT_PREVIEW_HOST_H_
