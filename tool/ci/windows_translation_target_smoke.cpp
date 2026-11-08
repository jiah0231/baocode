#include "../../windows/runner/translation_selection_target.h"
#include "../../windows/runner/translation_action_budget.h"
#include <array>
#include <cstdio>
#include <stdexcept>
namespace {
struct Node {
  int pid = 42;
  BOOL password = FALSE, offscreen = FALSE, focus = TRUE;
  CONTROLTYPEID type = UIA_DocumentControlTypeId;
  Node* parent = nullptr;
};
struct Tree {
  using Element = Node*;
  unsigned calls = 0, fail_at = 0, stop_at = 0, parents = 0;
  bool stopped = false;
  bool Call() { ++calls; if (calls == stop_at) stopped = true; return calls != fail_at; }
  bool Process(Element n, int* out) { if (!Call()) return false; *out = n->pid; return true; }
  bool Password(Element n, BOOL* out) { if (!Call()) return false; *out = n->password; return true; }
  bool Offscreen(Element n, BOOL* out) { if (!Call()) return false; *out = n->offscreen; return true; }
  bool Focus(Element n, BOOL* out) { if (!Call()) return false; *out = n->focus; return true; }
  bool Type(Element n, CONTROLTYPEID* out) { if (!Call()) return false; *out = n->type; return true; }
  bool Same(Element a, Element b, BOOL* out) { if (!Call()) return false; *out = a == b; return true; }
  bool Walker() { return Call(); }
  bool Parent(Element n, Element* out) { if (!Call()) return false; ++parents; *out = n->parent; return true; }
};
using Target = translation_selection::selection_target_detail::Target<Tree>;
void Check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
struct Fixture {
  Node document, inner, group;
  Tree tree;
  Target target;
  Fixture() { group.type = UIA_GroupControlTypeId; group.parent = &inner; inner.parent = &document; }
  bool Resolve(Node* focus, bool transition = true, bool chrome = true) {
    return target.Resolve(tree, focus, chrome, 42, [&] { return !tree.stopped; }, transition);
  }
  bool Empty() { return target.NoteEmpty(tree, [&] { return !tree.stopped; }); }
};
void Tests() {
  using namespace translation_action_budget;
  const auto initial = RequestDeadline(false, 1000, 1120);
  Check(initial == 2500, "Cold discovery extended the original gesture budget");
  Check(!Expired(1821, initial), "Cold discovery was incorrectly cut off at refresh 700ms");
  Check(!Expired(2499, initial) && Expired(2500, initial), "Discovery deadline boundary is inconsistent");
  Check(RequestDeadline(false, 1000, 2300) == initial,
        "A retry or delayed worker renewed the cold discovery budget");
  Check(Expired(2501, RequestDeadline(false, 1000, 2501)),
        "A late queued first request received a new budget");
  const auto refresh = RequestDeadline(true, 1000, 5000);
  Check(refresh == 5700 && !Expired(5699, refresh) && Expired(5700, refresh),
        "Visible-entry refresh no longer uses its strict 700ms budget");
  Fixture warm;
  Check(warm.Resolve(&warm.group) && warm.target.Get() == &warm.inner, "Warm Group did not bind nearest safe Document");
  const unsigned calls = warm.tree.calls;
  Check(warm.Resolve(&warm.group, false), "Pinned warm Group did not validate");
  for (unsigned i = 1; i <= calls; ++i) {
    Fixture fail; fail.tree.fail_at = i;
    Check(!fail.Resolve(&fail.group) && fail.tree.calls == i, "Failed metadata did not stop traversal");
    Fixture stop; stop.tree.stop_at = i;
    Check(!stop.Resolve(&stop.group) && stop.tree.calls == i, "Cancellation/deadline allowed more metadata calls");
  }
  Fixture cold;
  Check(cold.Resolve(&cold.document) && cold.Empty(), "Empty Chrome Document did not qualify for bounded waiting");
  cold.document.focus = FALSE;
  Check(cold.Resolve(&cold.group) && cold.target.Get() == &cold.document,
        "Cold transition replaced the pinned outer Document");
  Check(cold.Resolve(&cold.group, false), "Final Group-to-original-Document relationship failed");
  Node another = cold.group;
  Check(!cold.Resolve(&another), "Second focus identity change was accepted");
  Fixture no_empty;
  Check(no_empty.Resolve(&no_empty.document) && !no_empty.Resolve(&no_empty.group),
        "Known/collapsed selection allowed focus rebinding without zero-range evidence");
  Fixture final;
  Check(final.Resolve(&final.document) && final.Empty() && !final.Resolve(&final.group, false),
        "Final verification rebound focus");
  Fixture wrong;
  Check(wrong.Resolve(&wrong.document) && wrong.Empty(), "Setup failed");
  wrong.inner.parent = nullptr;
  Check(!wrong.Resolve(&wrong.group), "Group outside pinned Document accepted");
  Fixture edit;
  Check(edit.Resolve(&edit.document) && edit.Empty(), "Setup failed");
  edit.group.type = UIA_EditControlTypeId;
  Check(!edit.Resolve(&edit.group), "Focused Edit was treated as a PDF transition");
  Fixture nonchrome;
  Check(nonchrome.Resolve(&nonchrome.document, true, false) && !nonchrome.Empty(),
        "Non-Chromium empty Document enabled PDF transition");
  for (int field = 0; field < 4; ++field) {
    Fixture rejected;
    if (field == 0) rejected.inner.password = TRUE;
    if (field == 1) rejected.inner.pid = 99;
    if (field == 2) rejected.inner.offscreen = TRUE;
    if (field == 3) rejected.inner.type = UIA_EditControlTypeId;
    Check(!rejected.Resolve(&rejected.group), "Unsafe ancestor was accepted");
  }
  Fixture unfocused; unfocused.group.focus = FALSE;
  Check(!unfocused.Resolve(&unfocused.group), "Unfocused starting Group accepted");
  Fixture cyclic; cyclic.group.parent = &cyclic.group;
  Check(!cyclic.Resolve(&cyclic.group) && cyclic.tree.parents <= 8, "Ancestor traversal exceeded bound");
  Fixture expired; expired.tree.stopped = true;
  Check(!expired.Resolve(&expired.group) && expired.tree.calls == 0, "Expired request touched provider");
}
}
int main() {
  try { Tests(); std::puts("Selection target security checks passed"); return 0; }
  catch (const std::exception& error) { std::fprintf(stderr, "%s\n", error.what()); return 1; }
}
