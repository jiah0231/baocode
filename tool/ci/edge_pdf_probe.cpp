// Disposable public-document diagnostic. NEVER integrate selected-text logging into product.
#include "translation_selection_action.h"
#include <dwmapi.h>
#include <wrl/client.h>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#include <string>
#include <memory>
#include <utility>
#include <initializer_list>
#include <mutex>
#include <atomic>
#include <vector>
#if defined(BAOCODE_PUBLIC_PDF_IA2_DIAGNOSTIC)
#include "edge_pdf_ia2_probe.h"
#endif
using Microsoft::WRL::ComPtr;
namespace {
  HWND browser=nullptr;
  DWORD targetPid=0;
  HANDLE processHandle=nullptr;
  FILETIME processCreated{};
  std::wstring expectedExecutable;
  bool phraseMatched=false;
  std::unique_ptr<TranslationSelectionAction> action;
  struct ClickState {
    std::mutex mutex;
    translation_selection::Selection selection;
    std::atomic<bool> completed {
      false
    };
    std::atomic<bool> canceled {
      false
    };
    unsigned generation = 0;
    // UI-thread only, supplied by accepted production job.
    unsigned clicks = 0;
    bool queued = false;
  };
  std::shared_ptr<ClickState> clickState = std::make_shared<ClickState>();
  void Check(bool b,const char* msg) {
    if(!b)throw std::runtime_error(msg);
  }
  void Guard() {
    for(const auto& p : {
      std::pair<const wchar_t*,const wchar_t*>(L"GITHUB_ACTIONS",L"true"), {
        L"OS",L"Windows_NT"
      }, {
        L"BAOCODE_DISPOSABLE_UI_TEST",L"1"
      }
    }) {
      wchar_t v[64]{};
      GetEnvironmentVariableW(p.first,v,64);
      Check(std::wstring(v)==p.second,"CI guard rejected");
    }
  }
  BOOL CALLBACK Find(HWND w,LPARAM) {
    DWORD pid=0;
    GetWindowThreadProcessId(w,&pid);
    wchar_t c[128]{};
    GetClassNameW(w,c,128);
    if(pid==targetPid&&IsWindowVisible(w)&&std::wstring(c)==L"Chrome_WidgetWin_1")browser=w;
    return TRUE;
  }
  void Scoped() {
    Check(processHandle&&WaitForSingleObject(processHandle,0)==WAIT_TIMEOUT,"Target process exited");
    FILETIME created{},exited{},kernel{},user{};
    Check(GetProcessTimes(processHandle,&created,&exited,&kernel,&user)&&CompareFileTime(&created,&processCreated)==0,"Target creation identity changed");
    DWORD pid=0;
    GetWindowThreadProcessId(browser,&pid);
    Check(browser&&pid==targetPid&&GetForegroundWindow()==browser,"Target lost identity/foreground");
  }
  LRESULT CALLBACK Dispatch(HWND w,UINT m,WPARAM p,LPARAM l) {
    LRESULT r=0;
    if(action&&action->HandleMessage(m,p,l,&r))return r;
    return DefWindowProcW(w,m,p,l);
  }
  void Pump(DWORD ms) {
    auto end=GetTickCount64()+ms;
    while(GetTickCount64()<end) {
      MSG m;
      while(PeekMessageW(&m,nullptr,0,0,PM_REMOVE)) {
        TranslateMessage(&m);
        DispatchMessageW(&m);
      }
      Sleep(5);
    }
  }
  void Mouse(POINT p,DWORD flags) {
    Scoped();
    RECT r{};
    GetWindowRect(browser,&r);
    Check(PtInRect(&r,p)!=0,"Gesture outside target");
    INPUT i{};
    i.type=INPUT_MOUSE;
    i.mi.dx=MulDiv(p.x-GetSystemMetrics(SM_XVIRTUALSCREEN),65535,GetSystemMetrics(SM_CXVIRTUALSCREEN)-1);
    i.mi.dy=MulDiv(p.y-GetSystemMetrics(SM_YVIRTUALSCREEN),65535,GetSystemMetrics(SM_CYVIRTUALSCREEN)-1);
    i.mi.dwFlags=MOUSEEVENTF_MOVE|MOUSEEVENTF_ABSOLUTE|MOUSEEVENTF_VIRTUALDESK|flags;
    Check(SendInput(1,&i,sizeof(i))==1,"Mouse failed");
    Pump(25);
  }
  void RectLog(const char* key,RECT r) {
    printf("%s|%ld,%ld,%ld,%ld\n",key,r.left,r.top,r.right,r.bottom);
  }
  void Screenshot(const std::wstring& path) {
    Scoped();
    RECT r{};
    Check(GetWindowRect(browser,&r)!=0,"No window frame");
    int w=r.right-r.left,h=r.bottom-r.top;
    Check(w>0&&h>0,"Bad screenshot size");
    HDC screen=GetDC(nullptr),dc=CreateCompatibleDC(screen);
    BITMAPINFO bi{};
    bi.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth=w;
    bi.bmiHeader.biHeight=-h;
    bi.bmiHeader.biPlanes=1;
    bi.bmiHeader.biBitCount=32;
    void* pixels=nullptr;
    HBITMAP bmp=CreateDIBSection(dc,&bi,DIB_RGB_COLORS,&pixels,nullptr,0);
    Check(bmp&&pixels,"Screenshot allocation failed");
    auto old=SelectObject(dc,bmp);
    // Window rendering, never desktop BitBlt: cannot capture unrelated overlapping windows.
    BOOL ok=PrintWindow(browser,dc,2);
    GdiFlush();
    Check(ok!=0,"PrintWindow failed; no desktop fallback");
    BITMAPFILEHEADER bh{};
    bh.bfType=0x4d42;
    bh.bfOffBits=sizeof(bh)+sizeof(BITMAPINFOHEADER);
    bh.bfSize=bh.bfOffBits+static_cast<DWORD>(w*h*4);
    FILE* f=nullptr;
    _wfopen_s(&f,path.c_str(),L"wb");
    Check(f!=nullptr,"Screenshot file failed");
    fwrite(&bh,sizeof(bh),1,f);
    fwrite(&bi.bmiHeader,sizeof(BITMAPINFOHEADER),1,f);
    fwrite(pixels,static_cast<size_t>(w)*h*4,1,f);
    fclose(f);
    SelectObject(dc,old);
    DeleteObject(bmp);
    DeleteDC(dc);
    ReleaseDC(nullptr,screen);
    printf("SCREENSHOT|PrintWindow target only; GPU content may be blank; inspect artifact\n");
  }
  void TextLog(BSTR t) {
    printf("TEXT_UTF16|");
    for(UINT i=0;t&&i<SysStringLen(t);++i)printf("\\u%04X",static_cast<unsigned>(t[i]));
    puts("");
  }
  int Selected(ComPtr<IUIAutomation> uia,bool read,int documentLimit=8) {
    Scoped();
    ComPtr<IUIAutomationElement> root;
    Check(SUCCEEDED(uia->ElementFromHandle(browser,&root)),"UIA root unavailable");
    ComPtr<IUIAutomationCondition> condition;
    uia->CreatePropertyCondition(UIA_IsTextPatternAvailablePropertyId,[] {
      VARIANT v{};v.vt=VT_BOOL;v.boolVal=VARIANT_TRUE;return v;
    }
    (),&condition);
    ComPtr<IUIAutomationElementArray> elements;
    HRESULT hr=root->FindAll(TreeScope_Subtree,condition.Get(),&elements);
    printf("UIA_ENUM|hr=0x%08lX|warm=%d\n",static_cast<unsigned long>(hr),!read);
    if(FAILED(hr)||!elements)return 0;
    int count=0,found=0;
    elements->get_Length(&count);
    Check(count>=0&&count<=2000,"Unexpected huge isolated document tree");
    // Enumerate metadata only. Many PDF text children inherit the same pattern
    // and would return hundreds of duplicate selected-text reads.
    std::vector<int> targets;
    int documentCount=0, focusedNonDocumentCount=0;
    for(int n=0;n<count;++n) {
      Scoped();
      ComPtr<IUIAutomationElement> candidate;
      if(FAILED(elements->GetElement(n,&candidate))||!candidate)continue;
      CONTROLTYPEID candidateType=0;
      BOOL hasFocus=FALSE;
      if(FAILED(candidate->get_CurrentControlType(&candidateType)))continue;
      if(candidateType==UIA_DocumentControlTypeId) {
        ++documentCount;
        if(documentCount<=documentLimit)targets.push_back(n);
      } else if(SUCCEEDED(candidate->get_CurrentHasKeyboardFocus(&hasFocus))&&hasFocus) {
        ++focusedNonDocumentCount;
        if(focusedNonDocumentCount==1)targets.push_back(n);
      }
    }
    printf("UIA_TARGETS|availableTextPatternElements=%d|documentElements=%d|focusedNonDocumentElements=%d|processedTargets=%zu|maxDocuments=%d|maxFocusedNonDocument=1\n",
        count,documentCount,focusedNonDocumentCount,targets.size(),documentLimit);
    for(int n:targets) {
      Scoped();
      ComPtr<IUIAutomationElement> e;
      elements->GetElement(n,&e);
      if(!e)continue;
      // Recheck current target metadata immediately before pattern access.
      CONTROLTYPEID targetType=0;
      BOOL targetFocused=FALSE;
      if(FAILED(e->get_CurrentControlType(&targetType)))continue;
      if(targetType!=UIA_DocumentControlTypeId &&
          (FAILED(e->get_CurrentHasKeyboardFocus(&targetFocused))||!targetFocused))continue;
      BOOL password=TRUE;
      e->get_CurrentIsPassword(&password);
      if(password)continue;
      ComPtr<IUIAutomationTextPattern> pattern;
      e->GetCurrentPatternAs(UIA_TextPatternId,IID_PPV_ARGS(&pattern));
      if(!pattern)continue;
      ComPtr<IUIAutomationTextRangeArray> ranges;
      hr=pattern->GetSelection(&ranges);
      if(FAILED(hr)||!ranges)continue;
      int length=0;
      ranges->get_Length(&length);
      if(!read)continue;
      for(int j=0;j<length;++j) {
        Scoped();
        ComPtr<IUIAutomationTextRange> range;
        ranges->GetElement(j,&range);
        if(!range)continue;
        int collapsed=0;
        if(FAILED(range->CompareEndpoints(TextPatternRangeEndpoint_Start,range.Get(),TextPatternRangeEndpoint_End,&collapsed))||collapsed==0)continue;
        ++found;
        int pid=0;
        CONTROLTYPEID type=0;
        BOOL focused=FALSE;
        e->get_CurrentProcessId(&pid);
        e->get_CurrentControlType(&type);
        e->get_CurrentHasKeyboardFocus(&focused);
        printf("UIA_IDENTITY|elementPid=%d|targetPid=%lu|controlType=%d|focused=%d|subtreeBound=1\n",pid,targetPid,type,focused);
        RECT er{};
        e->get_CurrentBoundingRectangle(&er);
        printf("UIA_SELECTION|element=%d|range=%d|pid=%d\n",n,j,pid);
        RectLog("UIA_ELEMENT_RECT",er);
        SAFEARRAY* a=nullptr;
        hr=range->GetBoundingRectangles(&a);
        printf("UIA_RECTS|hr=0x%08lX",static_cast<unsigned long>(hr));
        if(a) {
          VARTYPE vt=VT_EMPTY;
          Check(SUCCEEDED(SafeArrayGetVartype(a,&vt))&&vt==VT_R8&&SafeArrayGetDim(a)==1&&SafeArrayGetElemsize(a)==sizeof(double),"Malformed rectangle array");
          LONG lo=0,hi=-1;
          SafeArrayGetLBound(a,1,&lo);
          SafeArrayGetUBound(a,1,&hi);
          Check(hi>=lo-1&&hi-lo+1<=16384&&(hi-lo+1)%4==0,"Rectangle array length invalid");
          for(LONG k=lo;k<=hi;++k) {
            double v=0;
            if(SUCCEEDED(SafeArrayGetElement(a,&k,&v)))printf("|%.3f",v);
          }
          SafeArrayDestroy(a);
        }
        puts("");
        BSTR text=nullptr;
        hr=range->GetText(32768,&text);
        printf("UIA_TEXT_HR|0x%08lX|cap=32768\n",static_cast<unsigned long>(hr));
        if(SUCCEEDED(hr)) {
          TextLog(text);
          if(text&&std::wstring(text,SysStringLen(text))==L"VAD method")phraseMatched=true;
        }
        SysFreeString(text);
      }
    }
    return found;
  }
}
int wmain(int argc,wchar_t** argv) {
  setvbuf(stdout,nullptr,_IONBF,0);
  try {
    Guard();
    Check(argc==10,"args: PID fromX fromY toX toY outputPrefix warm0or1 expectedDpi edgeExecutable (physical offsets from window top-left)");
    targetPid=wcstoul(argv[1],nullptr,10);
    Check(targetPid!=0,"Bad PID");
    expectedExecutable=argv[9];
    processHandle=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION|SYNCHRONIZE,FALSE,targetPid);
    Check(processHandle!=nullptr,"Cannot retain target process identity");
    wchar_t executable[32768]{};
    DWORD exeSize=32768;
    Check(QueryFullProcessImageNameW(processHandle,0,executable,&exeSize)&&_wcsicmp(executable,expectedExecutable.c_str())==0,"Target executable mismatch");
    FILETIME exitTime{},kernel{},user{};
    Check(GetProcessTimes(processHandle,&processCreated,&exitTime,&kernel,&user)!=0,"Target creation time missing");
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    for(int i=0;i<100&&!browser;++i) {
      EnumWindows(Find,0);
      Sleep(100);
    }
    Check(browser!=nullptr,"Isolated Edge not found");
    ShowWindow(browser,SW_MAXIMIZE);
    SetForegroundWindow(browser);
    Pump(1000);
    Scoped();
    RECT r{};
    GetWindowRect(browser,&r);
    RectLog("WINDOW_PHYSICAL",r);
    MONITORINFO monitor{};
    monitor.cbSize=sizeof(monitor);
    if(GetMonitorInfoW(MonitorFromWindow(browser,MONITOR_DEFAULTTONEAREST),&monitor)) {
      RectLog("MONITOR_PHYSICAL",monitor.rcMonitor);
      RectLog("WORKAREA_PHYSICAL",monitor.rcWork);
    }
    printf("SYSTEM_DPI|%u\n",GetDpiForSystem());
    printf("DPI|actual=%u|requested=%d\n",GetDpiForWindow(browser),_wtoi(argv[8]));
    Check(_wtoi(argv[8])==0||GetDpiForWindow(browser)==static_cast<UINT>(_wtoi(argv[8])),"DPI mismatch; no fake DPI variant");
    POINT a {
      r.left+_wtoi(argv[2]),r.top+_wtoi(argv[3])
    },b {
      r.left+_wtoi(argv[4]),r.top+_wtoi(argv[5])
    };
    printf("GESTURE_PHYSICAL|from=%ld,%ld|to=%ld,%ld\n",a.x,a.y,b.x,b.y);
    if(_wtoi(argv[7])==-1) {
      Screenshot(std::wstring(argv[6])+L"-calibration.bmp");
      return 0;
    }
    Check(SUCCEEDED(CoInitializeEx(nullptr,COINIT_MULTITHREADED)),"COM failed");
    ComPtr<IUIAutomation> uia;
    Check(SUCCEEDED(CoCreateInstance(CLSID_CUIAutomation8,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&uia))),"UIA unavailable");
    ComPtr<IUIAutomation2> timed;
    if(SUCCEEDED(uia.As(&timed))) {
      timed->put_ConnectionTimeout(500);
      timed->put_TransactionTimeout(1000);
    }
    const bool warm=_wtoi(argv[7])==1;
    printf("PROBE_MODE|warm=%d|diagnostic_only_not_cold_gate\n",warm);
    if(warm) {
      Selected(uia,false);
      Pump(1500);
    }
    WNDCLASSW c{};
    c.lpfnWndProc=Dispatch;
    c.hInstance=GetModuleHandleW(nullptr);
    c.lpszClassName=L"BaoCodePdfProbeDispatch";
    RegisterClassW(&c);
    HWND dispatch=CreateWindowW(c.lpszClassName,L"",0,0,0,0,0,HWND_MESSAGE,nullptr,c.hInstance,nullptr);
    action=std::make_unique<TranslationSelectionAction>(dispatch,[](HWND source) {
      const auto state=clickState; ++state->clicks; if (source!=browser || state->clicks!=1) {
        state->canceled.store(true); puts("CLICK_REJECTED|wrong_source_or_duplicate"); return;
      }
      state->queued=action->CaptureClickedSelection( source, GetTickCount64()+2000, [state] {
        return state->canceled.load();
      }, [state](translation_selection::Selection result) {
        {
          std::lock_guard<std::mutex> lock(state->mutex); state->selection=std::move(result);
        }
        state->completed.store(true);
      }, [state] {
        state->canceled.store(true);
      }, &state->generation); printf("CLICK_QUEUED|queued=%d|generation=%u|source=%p\n", state->queued,state->generation,static_cast<void*>(source));
    });
    Check(action->Configure(true,false),"Real action enable failed");
    Screenshot(std::wstring(argv[6])+L"-before.bmp");
    Mouse(a,0);
    Mouse(a,MOUSEEVENTF_LEFTDOWN);
    for(int i=1;i<=24;++i)Mouse(POINT {
      a.x+(b.x-a.x)*i/24,a.y+(b.y-a.y)*i/24
    },0);
    Mouse(b,MOUSEEVENTF_LEFTUP);
    Pump(1500);
    HWND icon=FindWindowW(L"BaoCodeTranslationSelectionAction",nullptr);
    DWORD owner=0;
    GetWindowThreadProcessId(icon,&owner);
    bool visible=icon&&owner==GetCurrentProcessId()&&IsWindowVisible(icon);
    printf("REAL_ICON|visible=%d|owner=%lu\n",visible,owner);
    if(visible) {
      RECT ir{};
      GetWindowRect(icon,&ir);
      RectLog("REAL_ICON_PHYSICAL",ir);
    }
    Screenshot(std::wstring(argv[6])+L"-selected.bmp");
    // The real click capture must precede independent diagnostic UIA reads.
    bool clickedPhraseMatched=false;
    if (visible) {
      RECT iconRect{};
      Check(GetWindowRect(icon,&iconRect)!=0,"Icon disappeared");
      POINT center {
        (iconRect.left+iconRect.right)/2,(iconRect.top+iconRect.bottom)/2
      };
      Check(GetAncestor(WindowFromPoint(center),GA_ROOT)==icon,"Icon center is not hittable");
      Mouse(center,0);
      Mouse(center,MOUSEEVENTF_LEFTDOWN);
      Mouse(center,MOUSEEVENTF_LEFTUP);
      const auto deadline=GetTickCount64()+2500;
      while(!clickState->completed.load() && GetTickCount64()<deadline) Pump(10);
      printf("CLICK_RESULT|clicks=%u|queued=%d|generation=%u|completed=%d|canceled=%d\n", clickState->clicks,clickState->queued,clickState->generation, clickState->completed.load(),clickState->canceled.load());
      if(clickState->completed.load()) {
        std::lock_guard<std::mutex> lock(clickState->mutex);
        const auto& result=clickState->selection;
        printf("CLICK_SELECTION|status=%s|units=%zu|self=%d\n", result.status.c_str(),result.text.size(),result.self);
        printf("CLICK_TEXT_UTF16|");
        for(wchar_t unit:result.text) printf("\\u%04X",static_cast<unsigned>(unit));
        puts("");
        if(result.bounds) RectLog("CLICK_BOUNDS_PHYSICAL",*result.bounds);
        if(result.area) RectLog("CLICK_AREA_PHYSICAL",*result.area);
        clickedPhraseMatched=!clickState->canceled.load() && result.status=="ok" && result.text==L"VAD method";
        action->ReleaseClickedSelection(clickState->generation);
        printf("CLICK_RELEASE|generation=%u|expectedPhraseMatch=%d\n",clickState->generation,clickedPhraseMatched);
      }
      else {
        clickState->canceled.store(true);
        puts("CLICK_TIMEOUT|not_success");
        action->Hide();
      }
    }
    else {
      puts("CLICK_SKIPPED|icon_hidden|raw_UIA_still_recorded");
    }
#if defined(BAOCODE_PUBLIC_PDF_IA2_DIAGNOSTIC)
    // Both comparisons follow production icon/click evidence. Limit each
    // snapshot to one Document and one focused non-Document TextPattern.
    puts("RAW_UIA_PHASE|BEFORE_IA2");
    Selected(uia,true,1);
    edge_pdf_ia2::Run(uia.Get(), browser, [] { Scoped(); });
    puts("RAW_UIA_PHASE|AFTER_IA2");
    phraseMatched=false;
    int selected=Selected(uia,true,1);
#else
    int selected=Selected(uia,true);
#endif
    printf("RESULT|selectedRanges=%d|iconVisible=%d|expectedPhraseMatch=%d|diagnostic_only\n",selected,visible,phraseMatched);
    action.reset();
    DestroyWindow(dispatch);
    return selected>0&&phraseMatched&&visible&&clickedPhraseMatched?0:1;
  }
  catch(const std::exception& e) {
    fprintf(stderr,"PROBE_FAILED|%s\n",e.what());
    return 2;
  }
}
