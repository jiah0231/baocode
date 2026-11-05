#include "document_preview_host.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shlwapi.h>
#include <wrl/client.h>
#include <wrl/event.h>

#include <algorithm>
#include <cmath>
#include <cwchar>
#include <cwctype>
#include <filesystem>
#include <fstream>
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "WebView2.h"
#include "utils.h"

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using Result = std::shared_ptr<flutter::MethodResult<Value>>;
constexpr wchar_t kOrigin[] = L"https://baocode-document.invalid/";
constexpr wchar_t kIndex[] = L"https://baocode-document.invalid/index.html";
constexpr wchar_t kChildClass[] = L"BAOCODE_DOCUMENT_PREVIEW";
constexpr size_t kMaxDocumentBytes = 32 * 1024 * 1024;
constexpr size_t kMaxAssetBytes = 24 * 1024 * 1024;
constexpr size_t kMaxPreviews = 4;
// Only bundled scripts execute. Untrusted HTML, event handlers, iframes,
// plugins, forms and all non-local connections are forbidden. Office engines
// require generated inline styles and blob/data images and fonts. CAD uses
// bundled blob modules and WASM; JavaScript string eval remains forbidden.
constexpr wchar_t kCsp[] =
    L"default-src 'none'; script-src 'self' blob: 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; "
    L"img-src 'self' data: blob:; font-src 'self' data: blob:; "
    L"connect-src 'self' blob:; worker-src 'self' blob:; frame-src 'none'; "
    L"child-src 'none'; object-src 'none'; base-uri 'none'; "
    L"form-action 'none'; frame-ancestors 'none'";

const Value* Find(const Map* map, const char* key) {
  if (!map) return nullptr;
  const auto it = map->find(Value(key));
  return it == map->end() ? nullptr : &it->second;
}
std::optional<int64_t> Integer(const Map* map, const char* key) {
  const Value* value = Find(map, key);
  if (!value) return std::nullopt;
  if (const auto* n = std::get_if<int32_t>(value)) return *n;
  if (const auto* n = std::get_if<int64_t>(value)) return *n;
  return std::nullopt;
}
std::optional<double> Number(const Map* map, const char* key) {
  const Value* value = Find(map, key);
  if (!value) return std::nullopt;
  if (const auto* n = std::get_if<double>(value)) return *n;
  if (const auto n = Integer(map, key)) return static_cast<double>(*n);
  return std::nullopt;
}
std::string Text(const Map* map, const char* key) {
  const Value* value = Find(map, key);
  if (value) {
    if (const auto* text = std::get_if<std::string>(value)) return *text;
  }
  return {};
}
bool Boolean(const Map* map, const char* key, bool fallback) {
  const Value* value = Find(map, key);
  if (value) {
    if (const auto* flag = std::get_if<bool>(value)) return *flag;
  }
  return fallback;
}
bool Bounds(const Map* map, RECT* bounds) {
  const auto x = Number(map, "x"), y = Number(map, "y");
  const auto w = Number(map, "width"), h = Number(map, "height");
  if (!x || !y || !w || !h || !std::isfinite(*x) || !std::isfinite(*y) ||
      !std::isfinite(*w) || !std::isfinite(*h) || *x < 0 || *y < 0 ||
      *w < 0 || *h < 0 || *x + *w > 65536 || *y + *h > 65536) return false;
  bounds->left = static_cast<LONG>(std::lround(*x));
  bounds->top = static_cast<LONG>(std::lround(*y));
  bounds->right = static_cast<LONG>(std::lround(*x + *w));
  bounds->bottom = static_cast<LONG>(std::lround(*y + *h));
  return true;
}
std::filesystem::path AssetFolder() {
  std::vector<wchar_t> path(32768);
  const DWORD count = GetModuleFileNameW(nullptr, path.data(),
                                       static_cast<DWORD>(path.size()));
  if (!count || count >= path.size()) return {};
  return std::filesystem::path(std::wstring(path.data(), count)).parent_path() /
         L"data" / L"flutter_assets" / L"assets" / L"office_preview";
}
std::wstring PrivateFolder() {
  wchar_t temp[MAX_PATH + 1]{};
  const DWORD length = GetTempPathW(MAX_PATH + 1, temp);
  GUID guid{};
  wchar_t guid_string[40]{};
  if (!length || length > MAX_PATH || FAILED(CoCreateGuid(&guid)) ||
      !StringFromGUID2(guid, guid_string, 40)) return {};
  return std::wstring(temp, length) + L"BaoCode-Document-" + guid_string;
}
std::wstring Mime(const std::wstring& relative) {
  const auto dot = relative.rfind(L'.');
  if (dot == std::wstring::npos) return {};
  const auto ext = relative.substr(dot);
  if (relative == L"index.html") return L"text/html; charset=utf-8";
  if (relative == L"THIRD_PARTY_NOTICES.txt") return L"text/plain; charset=utf-8";
  if (ext == L".js" || ext == L".mjs") return L"text/javascript; charset=utf-8";
  if (ext == L".css") return L"text/css; charset=utf-8";
  if (ext == L".json") return L"application/json; charset=utf-8";
  if (ext == L".wasm") return L"application/wasm";
  if (ext == L".woff2") return L"font/woff2";
  if (ext == L".woff") return L"font/woff";
  if (ext == L".ttf") return L"font/ttf";
  if (ext == L".png") return L"image/png";
  if (ext == L".jpg" || ext == L".jpeg") return L"image/jpeg";
  if (ext == L".svg") return L"image/svg+xml";
  return {};
}
bool AssetPath(const std::wstring& relative) {
  // Exact build outputs and the visible license notice, not a directory server.
  // Source files and arbitrary paths are not available to rendered documents.
  static const std::vector<std::wstring> allowed{
      L"index.html", L"viewer.js", L"viewer.css", L"word.js", L"excel.js",
      L"powerpoint.js", L"pdf.js", L"cad.js", L"epub.js",
      L"notability.js", L"goodnotes.js", L"THIRD_PARTY_NOTICES.txt"};
  if (std::find(allowed.begin(), allowed.end(), relative) == allowed.end()) return false;
  if (relative.empty() || relative.size() > 1024 || relative.front() == L'/' ||
      relative.back() == L'/') return false;
  for (wchar_t c : relative) {
    if (!((c >= L'a' && c <= L'z') || (c >= L'A' && c <= L'Z') ||
          (c >= L'0' && c <= L'9') || c == L'/' || c == L'.' ||
          c == L'_' || c == L'-')) return false;
  }
  size_t at = 0;
  while (at < relative.size()) {
    const size_t end = relative.find(L'/', at);
    const auto component = relative.substr(at, end == std::wstring::npos ? end : end - at);
    if (component.empty() || component == L"." || component == L"..") return false;
    if (end == std::wstring::npos) break;
    at = end + 1;
  }
  return true;
}

// Small strict JSON envelope parser: only string fields, no nested values,
// duplicate keys or ignored tails. Event contents never become native commands.
void Space(std::wstring_view source, size_t* at) {
  while (*at < source.size() && (source[*at] == L' ' || source[*at] == L'\t' ||
      source[*at] == L'\r' || source[*at] == L'\n')) ++*at;
}
bool JsonString(std::wstring_view source, size_t* at, std::wstring* result) {
  Space(source, at);
  if (*at >= source.size() || source[(*at)++] != L'"') return false;
  result->clear();
  while (*at < source.size()) {
    wchar_t c = source[(*at)++];
    if (c == L'"') return true;
    if (c < 0x20) return false;
    if (c == L'\\') {
      if (*at >= source.size()) return false;
      c = source[(*at)++];
      if (c == L'u') {
        unsigned int unit = 0;
        for (int n = 0; n < 4; ++n) {
          if (*at >= source.size()) return false;
          const wchar_t d = source[(*at)++];
          unit <<= 4;
          if (d >= L'0' && d <= L'9') unit |= static_cast<unsigned int>(d - L'0');
          else if (d >= L'a' && d <= L'f') unit |= static_cast<unsigned int>(d - L'a' + 10);
          else if (d >= L'A' && d <= L'F') unit |= static_cast<unsigned int>(d - L'A' + 10);
          else return false;
        }
        c = static_cast<wchar_t>(unit);
      } else if (c == L'b') c = L'\b';
      else if (c == L'f') c = L'\f';
      else if (c == L'n') c = L'\n';
      else if (c == L'r') c = L'\r';
      else if (c == L't') c = L'\t';
      else if (c != L'"' && c != L'\\' && c != L'/') return false;
    }
    result->push_back(c);
  }
  return false;
}
std::wstring EventType(std::wstring_view json) {
  size_t at = 0;
  Space(json, &at);
  if (at >= json.size() || json[at++] != L'{') return {};
  std::map<std::wstring, std::wstring> fields;
  while (at < json.size()) {
    std::wstring key, value;
    if (!JsonString(json, &at, &key)) return {};
    Space(json, &at);
    if (at >= json.size() || json[at++] != L':' || !JsonString(json, &at, &value)) return {};
    if ((key != L"type" && key != L"message") || fields.count(key)) return {};
    fields.emplace(std::move(key), std::move(value));
    Space(json, &at);
    if (at >= json.size()) return {};
    if (json[at++] == L'}') {
      Space(json, &at);
      return at == json.size() ? fields[L"type"] : std::wstring();
    }
    if (json[at - 1] != L',') return {};
  }
  return {};
}

struct Preview : std::enable_shared_from_this<Preview> {
  int64_t id = 0;
  HWND parent = nullptr;
  HWND child = nullptr;
  RECT bounds{};
  bool visible = true;
  bool closed = false;
  int document_reads = 0;
  std::vector<uint8_t> bytes;
  std::string format;
  std::filesystem::path assets;
  std::wstring user_data_folder;
  Result pending;
  std::function<void(int64_t, const char*)> emit;
  ComPtr<ICoreWebView2Environment> environment;
  ComPtr<ICoreWebView2Controller> controller;
  ComPtr<ICoreWebView2> web;

  ~Preview() { Close(); }
  void Close() {
    if (closed) return;
    closed = true;
    if (pending) {
      pending->Error("closed", "The preview was closed");
      pending.reset();
    }
    if (controller) controller->Close();
    web.Reset();
    controller.Reset();
    environment.Reset();
    if (child && IsWindow(child)) {
      SetWindowLongPtrW(child, GWLP_USERDATA, 0);
      DestroyWindow(child);
    }
    child = nullptr;
    std::vector<uint8_t>().swap(bytes);
    // No document file is written by this host. Remove its exclusively owned
    // InPrivate runtime folder if released; locked runtime metadata may remain.
    if (!user_data_folder.empty()) {
      std::error_code ignored;
      std::filesystem::remove_all(user_data_folder, ignored);
    }
  }
  void Fail(const char* code, const char* message) {
    if (closed) return;
    if (pending) {
      pending->Error(code, message);
      pending.reset();
    }
    if (emit) emit(id, "error");
    Close();
  }
  void Place() {
    if (!child || !IsWindow(child) || !IsWindow(parent)) return;
    RECT client{};
    GetClientRect(parent, &client);
    RECT clipped{};
    IntersectRect(&clipped, &bounds, &client);
    const int width = std::max<LONG>(0, clipped.right - clipped.left);
    const int height = std::max<LONG>(0, clipped.bottom - clipped.top);
    SetWindowPos(child, HWND_TOP, clipped.left, clipped.top, width, height,
                 SWP_NOACTIVATE | SWP_NOOWNERZORDER |
                     ((visible && width > 0 && height > 0) ? SWP_SHOWWINDOW : SWP_HIDEWINDOW));
    if (controller) {
      RECT local{0, 0, width, height};
      controller->put_Bounds(local);
      controller->put_IsVisible(visible && width > 0 && height > 0);
      controller->NotifyParentWindowPositionChanged();
    }
  }
  static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wp, LPARAM lp) {
    auto* self = reinterpret_cast<Preview*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
      self = static_cast<Preview*>(reinterpret_cast<CREATESTRUCTW*>(lp)->lpCreateParams);
      SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    }
    if (message == WM_NCDESTROY && self) {
      SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
      self->child = nullptr;
      self->Close();
    }
    return DefWindowProcW(hwnd, message, wp, lp);
  }
  bool MakeChild() {
    static const bool registered = [] {
      WNDCLASSW window_class{};
      window_class.lpfnWndProc = WindowProc;
      window_class.hInstance = GetModuleHandleW(nullptr);
      window_class.hCursor = LoadCursorW(nullptr, IDC_ARROW);
      window_class.lpszClassName = kChildClass;
      return RegisterClassW(&window_class) != 0 || GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
    }();
    if (!registered) return false;
    child = CreateWindowExW(0, kChildClass, L"", WS_CHILD | WS_CLIPCHILDREN | WS_CLIPSIBLINGS,
                            0, 0, 1, 1, parent, nullptr, GetModuleHandleW(nullptr), this);
    Place();
    return child != nullptr;
  }
  bool SourceIsViewer() const {
    LPWSTR source = nullptr;
    if (!web || FAILED(web->get_Source(&source))) return false;
    const bool valid = source && std::wstring_view(source) == kIndex;
    CoTaskMemFree(source);
    return valid;
  }
  HRESULT Respond(ICoreWebView2WebResourceRequestedEventArgs* args) {
    // The handler always supplies a response, including errors. No path falls
    // back to WebView2's network loader or permits arbitrary local file reads.
    ComPtr<ICoreWebView2WebResourceRequest> request;
    LPWSTR raw_uri = nullptr, raw_method = nullptr;
    std::wstring uri, method;
    if (SUCCEEDED(args->get_Request(&request)) && request) {
      if (SUCCEEDED(request->get_Uri(&raw_uri)) && raw_uri) uri = raw_uri;
      if (SUCCEEDED(request->get_Method(&raw_method)) && raw_method) method = raw_method;
    }
    CoTaskMemFree(raw_uri);
    CoTaskMemFree(raw_method);
    int status = 403;
    std::wstring mime = L"text/plain; charset=utf-8";
    std::vector<uint8_t> asset;
    const std::vector<uint8_t>* payload = &asset;
    if (!closed && method == L"GET" && uri.rfind(kOrigin, 0) == 0) {
      const auto relative = uri.substr(std::wstring_view(kOrigin).size());
      if (relative == L"document" && ++document_reads <= 4) {
        payload = &bytes;
        mime = L"application/octet-stream";
        status = 200;
      } else if (relative == L"document-format") {
        asset.assign(format.begin(), format.end());
        status = 200;
      } else if (AssetPath(relative) && !(mime = Mime(relative)).empty()) {
        // The root is derived from this executable, never a channel argument.
        // Reject links so an asset URL cannot escape the installed asset tree.
        auto file = assets;
        bool safe = !assets.empty();
        for (const auto& component : std::filesystem::path(relative)) {
          file /= component;
          const DWORD attributes = GetFileAttributesW(file.c_str());
          if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
            safe = false;
            break;
          }
        }
        if (safe) {
          std::ifstream stream(file, std::ios::binary | std::ios::ate);
          const auto length = stream.tellg();
          if (stream && length >= 0 && static_cast<uint64_t>(length) <= kMaxAssetBytes) {
            asset.resize(static_cast<size_t>(length));
            stream.seekg(0);
            if (asset.empty() || stream.read(reinterpret_cast<char*>(asset.data()),
                                            static_cast<std::streamsize>(asset.size()))) status = 200;
          }
        }
      }
    }
    if (status != 200) {
      asset.clear();
      payload = &asset;
      mime = L"text/plain; charset=utf-8";
    }
    const std::wstring headers = L"Content-Type: " + mime +
        L"\r\nCache-Control: no-store\r\nPragma: no-cache\r\nX-Content-Type-Options: nosniff"
        L"\r\nReferrer-Policy: no-referrer\r\nX-DNS-Prefetch-Control: off"
        L"\r\nPermissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=(), serial=()"
        L"\r\nContent-Security-Policy: " + kCsp;
    ComPtr<IStream> stream;
    stream.Attach(SHCreateMemStream(payload->empty() ? nullptr : payload->data(),
                                  static_cast<UINT>(payload->size())));
    ComPtr<ICoreWebView2WebResourceResponse> response;
    const HRESULT made = environment->CreateWebResourceResponse(stream.Get(), status,
                        status == 200 ? L"OK" : L"Forbidden", headers.c_str(), &response);
    if (FAILED(made) || !response) {
      // A response creation failure must not release the original request.
      Fail("resource", "The offline preview resource could not be provided");
      return E_ABORT;
    }
    const HRESULT supplied = args->put_Response(response.Get());
    if (FAILED(supplied)) {
      Fail("resource", "The offline preview resource could not be provided");
      return E_ABORT;
    }
    return supplied;
  }

  bool Secure() {
    ComPtr<ICoreWebView2Settings> settings;
    ComPtr<ICoreWebView2Settings3> settings3;
    ComPtr<ICoreWebView2Settings4> settings4;
    ComPtr<ICoreWebView2_4> web4;
    ComPtr<ICoreWebView2_18> web18;
    ComPtr<ICoreWebView2_22> web22;
    if (FAILED(web->get_Settings(&settings)) || !settings ||
        FAILED(settings.As(&settings3)) || FAILED(settings.As(&settings4)) ||
        FAILED(web.As(&web4)) || FAILED(web.As(&web18)) || FAILED(web.As(&web22))) return false;
    if (FAILED(settings->put_IsScriptEnabled(TRUE)) ||
        FAILED(settings->put_IsWebMessageEnabled(TRUE)) ||
        FAILED(settings->put_AreHostObjectsAllowed(FALSE)) ||
        FAILED(settings->put_AreDevToolsEnabled(FALSE)) ||
        FAILED(settings->put_AreDefaultContextMenusEnabled(FALSE)) ||
        FAILED(settings->put_AreDefaultScriptDialogsEnabled(FALSE)) ||
        FAILED(settings->put_IsStatusBarEnabled(FALSE)) ||
        FAILED(settings->put_IsBuiltInErrorPageEnabled(FALSE)) ||
        FAILED(settings3->put_AreBrowserAcceleratorKeysEnabled(FALSE)) ||
        FAILED(settings4->put_IsGeneralAutofillEnabled(FALSE)) ||
        FAILED(settings4->put_IsPasswordAutosaveEnabled(FALSE))) return false;
    std::weak_ptr<Preview> weak = shared_from_this();
    EventRegistrationToken token{};
    if (FAILED(web22->AddWebResourceRequestedFilterWithRequestSourceKinds(
            L"*", COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL,
            COREWEBVIEW2_WEB_RESOURCE_REQUEST_SOURCE_KINDS_ALL)) ||
        FAILED(web->add_WebResourceRequested(
          Callback<ICoreWebView2WebResourceRequestedEventHandler>(
            [weak](ICoreWebView2*, ICoreWebView2WebResourceRequestedEventArgs* args) -> HRESULT {
              const auto self = weak.lock();
              if (!self || self->closed) return E_ABORT;
              try {
                return self->Respond(args);
              } catch (...) {
                self->Fail("resource", "The offline preview resource could not be provided");
                return E_ABORT;
              }
            }).Get(), &token))) return false;
    if (FAILED(web->add_NavigationStarting(
          Callback<ICoreWebView2NavigationStartingEventHandler>(
            [](ICoreWebView2*, ICoreWebView2NavigationStartingEventArgs* args) -> HRESULT {
              LPWSTR uri = nullptr;
              const HRESULT got = args->get_Uri(&uri);
              const bool allowed = SUCCEEDED(got) && uri && std::wstring_view(uri) == kIndex;
              CoTaskMemFree(uri);
              return args->put_Cancel(!allowed);
            }).Get(), &token)) ||
        FAILED(web->add_FrameNavigationStarting(
          Callback<ICoreWebView2NavigationStartingEventHandler>(
            [](ICoreWebView2*, ICoreWebView2NavigationStartingEventArgs* args) -> HRESULT {
              return args->put_Cancel(TRUE);
            }).Get(), &token)) ||
        FAILED(web->add_NewWindowRequested(
          Callback<ICoreWebView2NewWindowRequestedEventHandler>(
            [](ICoreWebView2*, ICoreWebView2NewWindowRequestedEventArgs* args) -> HRESULT {
              return args->put_Handled(TRUE);
            }).Get(), &token)) ||
        FAILED(web->add_PermissionRequested(
          Callback<ICoreWebView2PermissionRequestedEventHandler>(
            [](ICoreWebView2*, ICoreWebView2PermissionRequestedEventArgs* args) -> HRESULT {
              return args->put_State(COREWEBVIEW2_PERMISSION_STATE_DENY);
            }).Get(), &token)) ||
        FAILED(web4->add_DownloadStarting(
          Callback<ICoreWebView2DownloadStartingEventHandler>(
            [](ICoreWebView2*, ICoreWebView2DownloadStartingEventArgs* args) -> HRESULT {
              args->put_Handled(TRUE);
              return args->put_Cancel(TRUE);
            }).Get(), &token)) ||
        FAILED(web18->add_LaunchingExternalUriScheme(
          Callback<ICoreWebView2LaunchingExternalUriSchemeEventHandler>(
            [](ICoreWebView2*, ICoreWebView2LaunchingExternalUriSchemeEventArgs* args) -> HRESULT {
              return args->put_Cancel(TRUE);
            }).Get(), &token))) return false;
    if (FAILED(web->add_WebMessageReceived(
          Callback<ICoreWebView2WebMessageReceivedEventHandler>(
            [weak](ICoreWebView2*, ICoreWebView2WebMessageReceivedEventArgs* args) -> HRESULT {
              const auto self = weak.lock();
              if (!self || self->closed || !self->SourceIsViewer()) return S_OK;
              LPWSTR source = nullptr;
              const HRESULT got = args->get_Source(&source);
              const bool valid = SUCCEEDED(got) && source && std::wstring_view(source) == kIndex;
              CoTaskMemFree(source);
              if (!valid) return S_OK;
              LPWSTR message = nullptr;
              std::wstring type;
              if (SUCCEEDED(args->TryGetWebMessageAsString(&message)) && message) {
                if (wcsnlen(message, 4097) <= 4096) type = message;
              } else {
                CoTaskMemFree(message);
                message = nullptr;
                if (SUCCEEDED(args->get_WebMessageAsJson(&message)) && message &&
                    wcsnlen(message, 4097) <= 4096) type = EventType(message);
              }
              CoTaskMemFree(message);
              if ((type == L"ready" || type == L"loaded" || type == L"error") && self->emit) {
                self->emit(self->id, type == L"ready" ? "ready" : type == L"loaded" ? "loaded" : "error");
              }
              return S_OK;
            }).Get(), &token)) ||
        FAILED(web->add_NavigationCompleted(
          Callback<ICoreWebView2NavigationCompletedEventHandler>(
            [weak](ICoreWebView2*, ICoreWebView2NavigationCompletedEventArgs* args) -> HRESULT {
              const auto self = weak.lock();
              BOOL success = FALSE;
              args->get_IsSuccess(&success);
              COREWEBVIEW2_WEB_ERROR_STATUS status = COREWEBVIEW2_WEB_ERROR_STATUS_UNKNOWN;
              args->get_WebErrorStatus(&status);
              // A denied hyperlink must not tear down a successfully rendered
              // document. Only actual load failures reach the Flutter error UI.
              if (self && !self->closed && !success &&
                  status != COREWEBVIEW2_WEB_ERROR_STATUS_OPERATION_CANCELED && self->emit) {
                self->emit(self->id, "error");
              }
              return S_OK;
            }).Get(), &token)) ||
        FAILED(web->add_ProcessFailed(
          Callback<ICoreWebView2ProcessFailedEventHandler>(
            [weak](ICoreWebView2*, ICoreWebView2ProcessFailedEventArgs*) -> HRESULT {
              const auto self = weak.lock();
              if (self && !self->closed) self->Fail("renderer", "The preview renderer stopped");
              return S_OK;
            }).Get(), &token))) return false;
    return true;
  }

  void StartController() {
    ComPtr<ICoreWebView2Environment10> env10;
    ComPtr<ICoreWebView2ControllerOptions> options;
    if (!environment || FAILED(environment.As(&env10)) ||
        FAILED(env10->CreateCoreWebView2ControllerOptions(&options)) || !options ||
        FAILED(options->put_IsInPrivateModeEnabled(TRUE))) {
      Fail("webview2", "A current WebView2 runtime is required for private previews");
      return;
    }
    std::weak_ptr<Preview> weak = shared_from_this();
    const HRESULT started = env10->CreateCoreWebView2ControllerWithOptions(child, options.Get(),
      Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
        [weak](HRESULT error, ICoreWebView2Controller* made) -> HRESULT {
          const auto self = weak.lock();
          if (!self || self->closed || !IsWindow(self->child)) {
            if (made) made->Close();
            return S_OK;
          }
          if (FAILED(error) || !made) {
            self->Fail("webview2", "The offline document viewer could not start");
            return S_OK;
          }
          self->controller = made;
          if (FAILED(made->get_CoreWebView2(&self->web)) || !self->web || !self->Secure()) {
            self->Fail("webview2", "The WebView2 runtime does not support secure offline previews");
            return S_OK;
          }
          self->Place();
          if (FAILED(self->web->Navigate(kIndex))) {
            self->Fail("navigation", "The offline document viewer could not load");
          } else if (self->pending) {
            self->pending->Success();
            self->pending.reset();
          }
          return S_OK;
        }).Get());
    if (FAILED(started)) Fail("webview2", "The offline document viewer could not start");
  }
  void Start() {
    if (!MakeChild()) {
      Fail("window", "The embedded document viewer could not be created");
      return;
    }
    user_data_folder = PrivateFolder();
    if (user_data_folder.empty()) {
      Fail("profile", "A private document viewer profile could not be created");
      return;
    }
    std::weak_ptr<Preview> weak = shared_from_this();
    const HRESULT started = CreateCoreWebView2EnvironmentWithOptions(
      nullptr, user_data_folder.c_str(), nullptr,
      Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
        [weak](HRESULT error, ICoreWebView2Environment* made) -> HRESULT {
          const auto self = weak.lock();
          if (!self || self->closed) return S_OK;
          if (FAILED(error) || !made) {
            self->Fail("webview2", "The Microsoft WebView2 runtime is not available");
            return S_OK;
          }
          self->environment = made;
          self->StartController();
          return S_OK;
        }).Get());
    if (FAILED(started)) Fail("webview2", "The Microsoft WebView2 runtime is not available");
  }
};
}  // namespace

struct DocumentPreviewHost::Impl {
  std::unique_ptr<flutter::MethodChannel<Value>> channel;
  std::function<HWND(int64_t)> window_for_view;
  std::map<int64_t, std::shared_ptr<Preview>> previews;
  std::shared_ptr<bool> alive = std::make_shared<bool>(true);

  Impl(flutter::BinaryMessenger* messenger, std::function<HWND(int64_t)> lookup)
      : window_for_view(std::move(lookup)) {
    channel = std::make_unique<flutter::MethodChannel<Value>>(
        messenger, "baocode/document_preview", &flutter::StandardMethodCodec::GetInstance());
    channel->SetMethodCallHandler([this](const auto& call, auto result) {
      Handle(call, std::move(result));
    });
  }
  ~Impl() {
    *alive = false;
    channel->SetMethodCallHandler(nullptr);
    for (auto& [id, preview] : previews) preview->Close();
    previews.clear();
  }
  void Handle(const flutter::MethodCall<Value>& call,
              std::unique_ptr<flutter::MethodResult<Value>> unique) {
    Result result(std::move(unique));
    const auto* arguments = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
    const auto id = Integer(arguments, "id");
    if (!id || *id < 0) {
      result->Error("argument", "A preview id is required");
      return;
    }
    const auto& method = call.method_name();
    if (method == "dispose") {
      const auto it = previews.find(*id);
      if (it != previews.end()) {
        it->second->Close();
        previews.erase(it);
      }
      result->Success();
      return;
    }
    if (method == "open") {
      const auto view = Integer(arguments, "viewId");
      const auto* data_value = Find(arguments, "bytes");
      const auto* data = data_value ? std::get_if<std::vector<uint8_t>>(data_value) : nullptr;
      const auto format = Text(arguments, "format");
      static const std::vector<std::string> formats{
          "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pdf",
          "dwg", "dxf", "epub", "note", "goodnotes"};
      RECT bounds{};
      const HWND parent = view ? window_for_view(*view) : nullptr;
      if (!data || data->empty() || data->size() > kMaxDocumentBytes ||
          std::find(formats.begin(), formats.end(), format) == formats.end() ||
          !parent || !IsWindow(parent) || !Bounds(arguments, &bounds)) {
        result->Error("argument", "Invalid or oversized document preview request");
        return;
      }
      if (previews.count(*id)) {
        result->Error("id", "This preview id is already open");
        return;
      }
      for (auto it = previews.begin(); it != previews.end();) {
        if (it->second->closed) it = previews.erase(it);
        else ++it;
      }
      if (previews.size() >= kMaxPreviews) {
        result->Error("limit", "Too many document previews are open");
        return;
      }
      auto preview = std::make_shared<Preview>();
      preview->id = *id;
      preview->parent = parent;
      preview->bounds = bounds;
      preview->visible = Boolean(arguments, "visible", true);
      preview->bytes = *data;
      preview->format = format;
      preview->assets = AssetFolder();
      preview->pending = result;
      const std::weak_ptr<bool> valid = alive;
      preview->emit = [this, valid](int64_t preview_id, const char* type) {
        const auto state = valid.lock();
        if (!state || !*state) return;
        Map event{{Value("id"), Value(preview_id)}, {Value("type"), Value(type)}};
        if (std::string_view(type) == "error") {
          event.emplace(Value("message"), Value("The document preview could not be displayed."));
        }
        channel->InvokeMethod("event", std::make_unique<Value>(event));
      };
      previews.emplace(*id, preview);
      preview->Start();
      return;
    }
    const auto found = previews.find(*id);
    if (found == previews.end() || found->second->closed) {
      result->Error("closed", "The preview is not open");
      return;
    }
    const auto& preview = found->second;
    if (method == "updateBounds") {
      if (!Bounds(arguments, &preview->bounds)) {
        result->Error("argument", "Invalid preview bounds");
        return;
      }
      preview->visible = Boolean(arguments, "visible", preview->visible);
      preview->Place();
    } else if (method == "setVisible") {
      preview->visible = Boolean(arguments, "visible", false);
      preview->Place();
    } else if (method == "postMessage") {
      const auto json = Text(arguments, "json");
      if (json.empty() || json.size() > 64 * 1024 || !preview->SourceIsViewer()) {
        result->Error("message", "The offline viewer is not ready for this message");
        return;
      }
      if (FAILED(preview->web->PostWebMessageAsJson(Utf16FromUtf8(json).c_str()))) {
        result->Error("message", "The viewer command could not be sent");
        return;
      }
    } else {
      result->NotImplemented();
      return;
    }
    result->Success();
  }
};

DocumentPreviewHost::DocumentPreviewHost(flutter::BinaryMessenger* messenger,
    std::function<HWND(int64_t)> window_for_view)
    : impl_(std::make_unique<Impl>(messenger, std::move(window_for_view))) {}
DocumentPreviewHost::~DocumentPreviewHost() = default;
