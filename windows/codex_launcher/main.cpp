// One Codex launch, one owned Windows Job. No arguments, files, or PID kills.
// stdin: "BCJ1", then exe/cwd/full command line, each uint32 LE + UTF-8 bytes,
// then the child's raw stdin. The environment is inherited unchanged.
// stdout: [kind:uint8][size:uint32 LE][bytes]; 1=stdout, 2=stderr, 3=status.
// Only this helper can emit status frames. Never put launch data in diagnostics.
#include <windows.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

namespace {
constexpr DWORD kFailure = 125;
constexpr DWORD kCancelled = 130;
constexpr size_t kQueueLimit = 64 * 1024 * 1024;
constexpr DWORD kChunk = 16 * 1024;

struct Handle {
  HANDLE value = nullptr;
  Handle() = default;
  explicit Handle(HANDLE h) : value(h) {}
  ~Handle() { reset(); }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  void reset(HANDLE h = nullptr) {
    if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value);
    value = h;
  }
};

bool write_all(HANDLE handle, const void* data, DWORD size) {
  auto* bytes = static_cast<const unsigned char*>(data);
  while (size) {
    DWORD written = 0;
    if (!WriteFile(handle, bytes, size, &written, nullptr) || !written)
      return false;
    bytes += written;
    size -= written;
  }
  return true;
}

bool read_all(HANDLE handle, void* data, DWORD size) {
  auto* bytes = static_cast<unsigned char*>(data);
  while (size) {
    DWORD read = 0;
    if (!ReadFile(handle, bytes, size, &read, nullptr) || !read) return false;
    bytes += read;
    size -= read;
  }
  return true;
}

bool read_field(HANDLE input, std::wstring& result) {
  unsigned char length[4];
  if (!read_all(input, length, 4)) return false;
  const uint32_t size = uint32_t(length[0]) | (uint32_t(length[1]) << 8) |
                        (uint32_t(length[2]) << 16) | (uint32_t(length[3]) << 24);
  if (size > 1024 * 1024) return false;
  if (!size) return true;
  std::string bytes(size, '\0');
  if (!read_all(input, bytes.data(), size) || bytes.find('\0') != bytes.npos)
    return false;
  const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                       bytes.data(), static_cast<int>(size),
                                       nullptr, 0);
  if (!count || count > 32766) return false;
  result.resize(static_cast<size_t>(count));
  return MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, bytes.data(),
                             static_cast<int>(size), result.data(), count) == count;
}

bool absolute_path(const std::wstring& path) {
  return (path.size() >= 3 &&
          ((path[0] >= L'A' && path[0] <= L'Z') ||
           (path[0] >= L'a' && path[0] <= L'z')) &&
          path[1] == L':' && (path[2] == L'\\' || path[2] == L'/')) ||
         (path.size() >= 3 && path[0] == L'\\' && path[1] == L'\\');
}

struct Frame {
  unsigned char kind;
  std::vector<unsigned char> bytes;
};

// Readers must never block behind the child or the parent: otherwise a stuck
// pipe can hide parent EOF and keep its child tree alive. Bound memory and fail
// closed on overload. Only the output worker serializes/writes stdout frames.
class Queue {
 public:
  bool put(unsigned char kind, const void* data, size_t size) {
    std::lock_guard<std::mutex> lock(mutex_);
    const size_t cost = size + sizeof(Frame);
    if (closed_ || cost > kQueueLimit - bytes_) return false;
    const auto* first = static_cast<const unsigned char*>(data);
    frames_.push_back({kind, std::vector<unsigned char>(first, first + size)});
    bytes_ += cost;
    ready_.notify_one();
    return true;
  }
  bool take(Frame& frame) {
    std::unique_lock<std::mutex> lock(mutex_);
    ready_.wait(lock, [this] { return closed_ || !frames_.empty(); });
    if (frames_.empty()) return false;
    frame = std::move(frames_.front());
    frames_.pop_front();
    bytes_ -= frame.bytes.size() + sizeof(Frame);
    return true;
  }
  void close(bool discard = false) {
    std::lock_guard<std::mutex> lock(mutex_);
    closed_ = true;
    if (discard) {
      frames_.clear();
      bytes_ = 0;
    }
    ready_.notify_all();
  }
 private:
  std::mutex mutex_;
  std::condition_variable ready_;
  std::deque<Frame> frames_;
  size_t bytes_ = 0;
  bool closed_ = false;
};

bool write_frame(HANDLE output, const Frame& frame) {
  const auto size = static_cast<uint32_t>(frame.bytes.size());
  const unsigned char header[] = {
      frame.kind, static_cast<unsigned char>(size),
      static_cast<unsigned char>(size >> 8),
      static_cast<unsigned char>(size >> 16),
      static_cast<unsigned char>(size >> 24)};
  return write_all(output, header, sizeof(header)) &&
         write_all(output, frame.bytes.data(), size);
}

struct State {
  HANDLE parent_input = GetStdHandle(STD_INPUT_HANDLE);
  HANDLE parent_output = GetStdHandle(STD_OUTPUT_HANDLE);
  Handle gate{CreateEventW(nullptr, TRUE, FALSE, nullptr)};
  Handle child_input, child_output, child_error;
  Queue input, output;
  std::atomic<bool> stopping{false}, parent_closed{false};
  std::atomic<DWORD> fault{0};
  void fail(DWORD code) {
    DWORD expected = 0;
    fault.compare_exchange_strong(expected, code ? code : ERROR_GEN_FAILURE);
  }
  void status(const std::string& message) {
    if (!output.put(3, message.data(), message.size()))
      fail(ERROR_NOT_ENOUGH_MEMORY);
  }
};

DWORD WINAPI read_parent(void* context) {
  auto& state = *static_cast<State*>(context);
  WaitForSingleObject(state.gate.value, INFINITE);
  unsigned char bytes[kChunk];
  while (!state.stopping.load()) {
    DWORD read = 0;
    if (!ReadFile(state.parent_input, bytes, kChunk, &read, nullptr) || !read) {
      if (!state.stopping.load()) state.parent_closed = true;
      break;
    }
    if (!state.input.put(0, bytes, read)) {
      if (!state.stopping.load()) state.fail(ERROR_NOT_ENOUGH_MEMORY);
      break;
    }
  }
  state.input.close();
  return 0;
}

DWORD WINAPI write_child(void* context) {
  auto& state = *static_cast<State*>(context);
  WaitForSingleObject(state.gate.value, INFINITE);
  Frame frame;
  bool child_open = true;
  while (state.input.take(frame) && !state.stopping.load()) {
    if (child_open && !write_all(state.child_input.value, frame.bytes.data(),
                                 static_cast<DWORD>(frame.bytes.size()))) {
      // A root may close stdin or exit while descendants remain. Keep draining
      // parent input to observe EOF rather than killing those descendants early.
      const DWORD error = GetLastError();
      if (error != ERROR_BROKEN_PIPE && error != ERROR_NO_DATA &&
          !state.stopping.load()) state.fail(error);
      child_open = false;
      state.child_input.reset();
    }
  }
  state.child_input.reset();
  return 0;
}

struct Reader {
  State* state;
  HANDLE pipe;
  unsigned char kind;
};
DWORD WINAPI read_child(void* context) {
  auto& reader = *static_cast<Reader*>(context);
  auto& state = *reader.state;
  WaitForSingleObject(state.gate.value, INFINITE);
  unsigned char bytes[kChunk];
  for (;;) {
    DWORD read = 0;
    if (!ReadFile(reader.pipe, bytes, kChunk, &read, nullptr)) {
      const DWORD error = GetLastError();
      if (error != ERROR_BROKEN_PIPE && error != ERROR_NO_DATA) state.fail(error);
      break;
    }
    if (!read) break;
    if (!state.output.put(reader.kind, bytes, read)) {
      state.fail(ERROR_NOT_ENOUGH_MEMORY);
      break;
    }
  }
  return 0;
}

DWORD WINAPI write_parent(void* context) {
  auto& state = *static_cast<State*>(context);
  WaitForSingleObject(state.gate.value, INFINITE);
  Frame frame;
  while (state.output.take(frame)) {
    if (!write_frame(state.parent_output, frame)) {
      state.fail(GetLastError());
      state.output.close(true);
      break;
    }
  }
  return 0;
}

bool make_pipe(Handle& read, Handle& write, bool inherit_read) {
  SECURITY_ATTRIBUTES security{sizeof(security), nullptr, TRUE};
  return CreatePipe(&read.value, &write.value, &security, 0) &&
         SetHandleInformation(inherit_read ? write.value : read.value,
                              HANDLE_FLAG_INHERIT, 0);
}

bool job_empty(HANDLE job, bool& empty) {
  JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info{};
  if (!QueryInformationJobObject(job, JobObjectBasicAccountingInformation,
                                 &info, sizeof(info), nullptr)) return false;
  empty = info.ActiveProcesses == 0;
  return true;
}

// Called only before opening the worker gate. No child has been resumed on any
// expected failure path. Still confirm the entire job is empty before sending
// launch_failed, which Dart treats as a terminal ownership acknowledgement.
[[noreturn]] void launch_failure(State& state, HANDLE job, HANDLE process,
                                unsigned int stage, DWORD error) {
  bool safe = true;
  if (process) {
    TerminateProcess(process, kFailure);  // Owned creation handle, never a PID.
    if (job) TerminateJobObject(job, kFailure);
    safe = WaitForSingleObject(process, INFINITE) == WAIT_OBJECT_0;
    bool empty = false;
    while (safe && job) {
      safe = job_empty(job, empty);
      if (!safe || empty) break;
      Sleep(10);
    }
  }
  if (safe) {
    const std::string message = "launch_failed:" + std::to_string(stage) +
                                "/" + std::to_string(error);
    Frame frame{3, std::vector<unsigned char>(message.begin(), message.end())};
    if (!write_frame(state.parent_output, frame)) {
      constexpr char diagnostic[] = "Codex owned launcher failed.\n";
      write_all(GetStdHandle(STD_ERROR_HANDLE), diagnostic,
                sizeof(diagnostic) - 1);
    }
  }
  // Also closes the non-inherited kill-on-close job on any verification error.
  ExitProcess(kFailure);
}

// Cancel repeatedly: cancellation can race with a worker entering ReadFile or
// WriteFile. Never close a handle out from under a live I/O operation.
void cancel_and_join(HANDLE thread) {
  while (WaitForSingleObject(thread, 10) == WAIT_TIMEOUT)
    CancelSynchronousIo(thread);
}
}  // namespace

int main(int argc, char**) {
  State state;
  std::wstring exe, cwd, command;
  char magic[4];
  if (argc != 1 || !state.gate.value ||
      !read_all(state.parent_input, magic, sizeof(magic)) ||
      std::memcmp(magic, "BCJ1", 4) != 0 || !read_field(state.parent_input, exe) ||
      !read_field(state.parent_input, cwd) || !read_field(state.parent_input, command) ||
      !absolute_path(exe) || command.empty() ||
      (!cwd.empty() && !absolute_path(cwd)))
    launch_failure(state, nullptr, nullptr, 1, ERROR_INVALID_DATA);

  Handle job(CreateJobObjectW(nullptr, nullptr));  // Unnamed, non-inheritable.
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!job.value || !SetInformationJobObject(job.value,
          JobObjectExtendedLimitInformation, &limits, sizeof(limits)))
    launch_failure(state, job.value, nullptr, 2, GetLastError());

  Handle child_read, child_write, child_error_write;
  if (!make_pipe(child_read, state.child_input, true) ||
      !make_pipe(state.child_output, child_write, false) ||
      !make_pipe(state.child_error, child_error_write, false))
    launch_failure(state, job.value, nullptr, 3, GetLastError());

  SIZE_T attribute_size = 0;
  InitializeProcThreadAttributeList(nullptr, 2, 0, &attribute_size);
  std::vector<unsigned char> storage(attribute_size);
  auto* attributes = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(storage.data());
  if (!InitializeProcThreadAttributeList(attributes, 2, 0, &attribute_size))
    launch_failure(state, job.value, nullptr, 4, GetLastError());
  HANDLE inherited[] = {child_read.value, child_write.value, child_error_write.value};
  HANDLE assigned_job = job.value;
#ifdef BAOCODE_LAUNCHER_TEST_REJECT_JOB
  // Dedicated fixture binary only. Production has no runtime failure switch.
  assigned_job = INVALID_HANDLE_VALUE;
#endif
  // Atomic enrollment closes the suspended-create/AssignProcessToJobObject crash
  // gap. Do not fall back to a launch outside the job on older Windows versions.
  if (!UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
          inherited, sizeof(inherited), nullptr, nullptr) ||
      !UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST,
          &assigned_job, sizeof(assigned_job), nullptr, nullptr))
    launch_failure(state, job.value, nullptr, 4, GetLastError());

  Reader out{&state, state.child_output.value, 1};
  Reader err{&state, state.child_error.value, 2};
  Handle input_reader(CreateThread(nullptr, 0, read_parent, &state, 0, nullptr));
  Handle input_writer(CreateThread(nullptr, 0, write_child, &state, 0, nullptr));
  Handle output_reader(CreateThread(nullptr, 0, read_child, &out, 0, nullptr));
  Handle error_reader(CreateThread(nullptr, 0, read_child, &err, 0, nullptr));
  Handle output_writer(CreateThread(nullptr, 0, write_parent, &state, 0, nullptr));
  if (!input_reader.value || !input_writer.value || !output_reader.value ||
      !error_reader.value || !output_writer.value)
    launch_failure(state, job.value, nullptr, 5, ERROR_NOT_ENOUGH_MEMORY);

  STARTUPINFOEXW startup{};
  startup.StartupInfo.cb = sizeof(startup);
  startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  startup.StartupInfo.hStdInput = child_read.value;
  startup.StartupInfo.hStdOutput = child_write.value;
  startup.StartupInfo.hStdError = child_error_write.value;
  startup.lpAttributeList = attributes;
  PROCESS_INFORMATION process{};
  const BOOL created = CreateProcessW(exe.c_str(), command.data(), nullptr, nullptr,
      TRUE, EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED | CREATE_NO_WINDOW,
      nullptr, cwd.empty() ? nullptr : cwd.c_str(), &startup.StartupInfo, &process);
  const DWORD create_error = created ? 0 : GetLastError();
  DeleteProcThreadAttributeList(attributes);
  if (!created) launch_failure(state, job.value, nullptr, 6, create_error);
  Handle root(process.hProcess), root_thread(process.hThread);
  BOOL in_job = FALSE;
  const BOOL verified = IsProcessInJob(root.value, job.value, &in_job);
#ifdef BAOCODE_LAUNCHER_TEST_REJECT_MEMBERSHIP
  in_job = FALSE;  // Exercise cleanup of the owned, still-suspended process.
#endif
  if (!verified || !in_job)
    launch_failure(state, job.value, root.value, 7, ERROR_ACCESS_DENIED);
  child_read.reset();
  child_write.reset();
  child_error_write.reset();
  if (ResumeThread(root_thread.value) == static_cast<DWORD>(-1))
    launch_failure(state, job.value, root.value, 8, GetLastError());
  // Workers were created behind this gate so setup failures cannot emit partial
  // child frames or race launch_failed. After resume, only job_empty is terminal.
  if (!SetEvent(state.gate.value)) ExitProcess(kFailure);
  root_thread.reset();

  bool root_exited = false, shutdown = false, terminated = false, empty = false;
  DWORD root_code = kFailure;
  ULONGLONG shutdown_at = 0;
  DWORD reported_fault = 0;
  for (;;) {
    if (!root_exited && WaitForSingleObject(root.value, 0) == WAIT_OBJECT_0) {
      if (!GetExitCodeProcess(root.value, &root_code)) ExitProcess(kFailure);
      root_exited = true;
      state.status("root_exited:" + std::to_string(root_code));
    }
    if (!job_empty(job.value, empty)) ExitProcess(kFailure);
    if (empty && root_exited) break;
    const DWORD fault = state.fault.load();
    if (fault && !reported_fault) {
      reported_fault = fault;
      state.status("transport_failed:" + std::to_string(fault));
    }
    if (!shutdown && (state.parent_closed.load() || fault)) {
      shutdown = true;
      shutdown_at = GetTickCount64();
      state.status("shutdown_requested");
    }
    if (shutdown && !terminated &&
        (fault || GetTickCount64() - shutdown_at >= 1000)) {
      // Root exit alone is never permission to end live descendants.
      if (!TerminateJobObject(job.value, kCancelled)) ExitProcess(kFailure);
      terminated = true;
      state.status("job_terminated");
    }
    Sleep(10);
  }

  state.stopping = true;
  state.input.close(true);
  cancel_and_join(input_reader.value);
  cancel_and_join(input_writer.value);
  // Job emptiness means every owned writer has gone. Drain both pipes before the
  // terminal frame, and the framed output queue before the helper itself exits.
  WaitForSingleObject(output_reader.value, INFINITE);
  WaitForSingleObject(error_reader.value, INFINITE);
  state.status("job_empty");
  state.output.close();
  WaitForSingleObject(output_writer.value, INFINITE);
  return static_cast<int>(state.fault.load() ? kFailure :
                          terminated ? kCancelled : root_code);
}
