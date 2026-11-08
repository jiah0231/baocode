#ifndef RUNNER_TRANSLATION_SELECTION_TARGET_H_
#define RUNNER_TRANSLATION_SELECTION_TARGET_H_
#include <windows.h>
#include <UIAutomation.h>
#include <wrl/client.h>

namespace translation_selection {
// Optional metadata-only diagnostics. No selected text or document values.
struct SelectionTargetDiagnostics {
  const char* stage = "none";
  HRESULT result = S_OK;
  int process = 0;
  BOOL password = TRUE, offscreen = TRUE, has_focus = FALSE, same = FALSE;
  CONTROLTYPEID type = 0;
};
namespace selection_target_detail {
// Resolves only the current focus and a bounded CONTROL-parent chain. Chromium
// PDF exposes focused Groups inside a selectable Document. No descendants,
// pointer hit tests, ValuePattern or document text are inspected here.
template <typename Tree>
class Target {
 public:
  using Element = typename Tree::Element;
  void Reset() { focus_ = Element{}; target_ = Element{}; empty_document_ = false; chrome_ = false; initial_document_ = false; }
  Element Get() const { return target_; }
  template <typename Ready>
  bool Resolve(Tree& tree, Element focus,
               bool chrome, DWORD pid, const Ready& ready, bool allow_transition = true) {
    CONTROLTYPEID type = 0;
    BOOL has_focus = FALSE;
    if (!Safe(tree, focus, pid, ready) || !ready() ||
        !tree.Focus(focus, &has_focus) || !has_focus ||
        !ready() || !tree.Type(focus, &type)) return false;
    if (focus_) {
      BOOL same = FALSE;
      if (!ready() || !tree.Same(focus_, focus, &same)) return false;
      if (!same) {
        // One narrowly defined cold-PDF transition: the previously empty,
        // pinned Document must be an ancestor of the newly focused Group.
        if (!allow_transition || !empty_document_ || !chrome_ || !chrome ||
            type != UIA_GroupControlTypeId ||
            !FindDocument(tree, focus, pid, target_, ready)) return false;
        focus_ = focus;
        empty_document_ = false;
        initial_document_ = false;
      } else if (target_ != focus_) {
        // COM pointer equality is not identity; a redundant ancestry check is
        // harmless and keeps every delivery tied to the original Document.
        if (!FindDocument(tree, focus, pid, target_, ready)) return false;
      }
      return ready();
    }
    Element target = focus;
    if (chrome && type == UIA_GroupControlTypeId) {
      target = FindDocument(tree, focus, pid, {}, ready);
      if (!target) return false;
    }
    focus_ = focus;
    target_ = target;
    chrome_ = chrome;
    initial_document_ = type == UIA_DocumentControlTypeId;
    return ready();
  }
  // Only zero ranges can indicate a not-yet-populated PDF accessibility tree.
  // A known collapsed range remains a terminal noSelection result.
  template <typename Ready>
  bool NoteEmpty(Tree& tree, const Ready& ready) {
    CONTROLTYPEID type = 0;
    const bool retry = chrome_ && target_ && ready() &&
        tree.Type(target_, &type) &&
        type == UIA_DocumentControlTypeId && ready();
    empty_document_ = retry && initial_document_;
    return retry;
  }
 private:
  template <typename Ready>
  static bool Safe(Tree& tree, Element node, DWORD pid, const Ready& ready) {
    int actual = 0;
    BOOL node_password = TRUE, offscreen = TRUE;
    return node && ready() && tree.Process(node, &actual) &&
        static_cast<DWORD>(actual) == pid && ready() &&
        tree.Password(node, &node_password) && !node_password && ready() &&
        tree.Offscreen(node, &offscreen) && !offscreen && ready();
  }
  template <typename Ready>
  static Element FindDocument(Tree& tree, Element focus,
                              DWORD pid, Element pinned,
                              const Ready& ready) {
    if (!ready() || !tree.Walker()) return {};
    Element node = focus;
    for (unsigned depth = 0; depth < 8 && node; ++depth) {
      CONTROLTYPEID type = 0;
      if (!Safe(tree, node, pid, ready) || !ready() ||
          !tree.Type(node, &type)) return {};
      if (type != UIA_GroupControlTypeId && type != UIA_DocumentControlTypeId) return {};
      if (type == UIA_DocumentControlTypeId) {
        BOOL same = FALSE;
        if (!pinned) return node;
        if (!ready() || !tree.Same(node, pinned, &same)) return {};
        if (same) return node;
      }
      Element parent{};
      if (!ready() || !tree.Parent(node, &parent)) return {};
      node = parent;
    }
    return {};
  }
  Element focus_{}, target_{};
  bool empty_document_ = false, chrome_ = false, initial_document_ = false;
};
class UiaTree {
 public:
  using Element = Microsoft::WRL::ComPtr<IUIAutomationElement>;
  explicit UiaTree(IUIAutomation* automation, SelectionTargetDiagnostics* diagnostics = nullptr)
      : automation_(automation), diagnostics_(diagnostics) {}
  bool Process(const Element& node, int* value) {
    const bool ok = Observe("Target.ProcessId", node->get_CurrentProcessId(value));
    if (ok && diagnostics_) diagnostics_->process = *value;
    return ok;
  }
  bool Password(const Element& node, BOOL* value) {
    const bool ok = Observe("Target.IsPassword", node->get_CurrentIsPassword(value));
    if (ok && diagnostics_) diagnostics_->password = *value;
    return ok;
  }
  bool Offscreen(const Element& node, BOOL* value) {
    const bool ok = Observe("Target.IsOffscreen", node->get_CurrentIsOffscreen(value));
    if (ok && diagnostics_) diagnostics_->offscreen = *value;
    return ok;
  }
  bool Focus(const Element& node, BOOL* value) {
    const bool ok = Observe("Target.HasKeyboardFocus", node->get_CurrentHasKeyboardFocus(value));
    if (ok && diagnostics_) diagnostics_->has_focus = *value;
    return ok;
  }
  bool Type(const Element& node, CONTROLTYPEID* value) {
    const bool ok = Observe("Target.ControlType", node->get_CurrentControlType(value));
    if (ok && diagnostics_) diagnostics_->type = *value;
    return ok;
  }
  bool Same(const Element& first, const Element& second, BOOL* value) {
    const bool ok = Observe("Target.CompareElements", automation_->CompareElements(first.Get(), second.Get(), value));
    if (ok && diagnostics_) diagnostics_->same = *value;
    return ok;
  }
  bool Walker() {
    return Observe("Target.ControlWalker", automation_->get_ControlViewWalker(walker_.ReleaseAndGetAddressOf())) && walker_;
  }
  bool Parent(const Element& node, Element* parent) {
    return Observe("Target.Parent", walker_->GetParentElement(node.Get(), parent->GetAddressOf()));
  }
 private:
  bool Observe(const char* stage, HRESULT result) {
    if (diagnostics_) { diagnostics_->stage = stage; diagnostics_->result = result; }
    return SUCCEEDED(result);
  }
  IUIAutomation* automation_;
  SelectionTargetDiagnostics* diagnostics_;
  Microsoft::WRL::ComPtr<IUIAutomationTreeWalker> walker_;
};
}  // namespace selection_target_detail
class SelectionTarget {
 public:
  void Reset() { state_.Reset(); }
  IUIAutomationElement* Get() const { return state_.Get().Get(); }
  template <typename Ready>
  bool Resolve(IUIAutomation* automation, IUIAutomationElement* focus,
               HWND source, DWORD pid, const Ready& ready, bool allow_transition = true,
               SelectionTargetDiagnostics* diagnostics = nullptr) {
    if (diagnostics) *diagnostics = SelectionTargetDiagnostics{};
    if (!automation || !focus || !ready()) return false;
    wchar_t window_class[64]{};
    const bool chrome = GetClassNameW(source, window_class, 64) &&
        wcscmp(window_class, L"Chrome_WidgetWin_1") == 0;
    selection_target_detail::UiaTree tree(automation, diagnostics);
    return state_.Resolve(tree, focus, chrome, pid, ready, allow_transition);
  }
  template <typename Ready>
  bool NoteEmpty(const Ready& ready) {
    selection_target_detail::UiaTree tree(nullptr);  // Only a target property is read.
    return state_.NoteEmpty(tree, ready);
  }
 private:
  selection_target_detail::Target<selection_target_detail::UiaTree> state_;
};
}  // namespace translation_selection
#endif
