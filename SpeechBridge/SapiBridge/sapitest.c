/*
 * sapitest.exe — speaks through SAPI the way a game does, and writes what
 * happened to sapitest.log beside itself. Run it inside the bottle; if the
 * SpeechBridge voice is registered, SpeechBridge.log and the Mac listener
 * should both show the two sentences.
 *
 *   x86_64-w64-mingw32-gcc -O2 -Wall -o sapitest64.exe sapitest.c -lole32 -static-libgcc
 *   i686-w64-mingw32-gcc   -O2 -Wall -o sapitest32.exe sapitest.c -lole32 -static-libgcc
 *
 * ISpVoice is declared by hand (enough of its vtable to reach WaitUntilDone).
 */

#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <objbase.h>
#include <stdio.h>

DEFINE_GUID(CLSID_SpVoice, 0x96749377, 0x3391, 0x11d2, 0x9e, 0xe3, 0x00, 0xc0, 0x4f, 0x79, 0x73, 0x96);
DEFINE_GUID(IID_ISpVoice,  0x6c44df74, 0x72b9, 0x4992, 0xa1, 0xec, 0xef, 0x99, 0x6e, 0x04, 0x22, 0xd4);

typedef struct ISpObjectToken ISpObjectToken;
typedef struct ISpObjectTokenVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(ISpObjectToken *, REFIID, void **);
    ULONG   (STDMETHODCALLTYPE *AddRef)(ISpObjectToken *);
    ULONG   (STDMETHODCALLTYPE *Release)(ISpObjectToken *);
    /* ISpDataKey */
    HRESULT (STDMETHODCALLTYPE *SetData)(ISpObjectToken *, LPCWSTR, ULONG, const BYTE *);
    HRESULT (STDMETHODCALLTYPE *GetData)(ISpObjectToken *, LPCWSTR, ULONG *, BYTE *);
    HRESULT (STDMETHODCALLTYPE *SetStringValue)(ISpObjectToken *, LPCWSTR, LPCWSTR);
    HRESULT (STDMETHODCALLTYPE *GetStringValue)(ISpObjectToken *, LPCWSTR, LPWSTR *);
    HRESULT (STDMETHODCALLTYPE *SetDWORD)(ISpObjectToken *, LPCWSTR, DWORD);
    HRESULT (STDMETHODCALLTYPE *GetDWORD)(ISpObjectToken *, LPCWSTR, DWORD *);
    HRESULT (STDMETHODCALLTYPE *OpenKey)(ISpObjectToken *, LPCWSTR, void **);
    HRESULT (STDMETHODCALLTYPE *CreateKey)(ISpObjectToken *, LPCWSTR, void **);
    HRESULT (STDMETHODCALLTYPE *DeleteKey)(ISpObjectToken *, LPCWSTR);
    HRESULT (STDMETHODCALLTYPE *DeleteValue)(ISpObjectToken *, LPCWSTR);
    HRESULT (STDMETHODCALLTYPE *EnumKeys)(ISpObjectToken *, ULONG, LPWSTR *);
    HRESULT (STDMETHODCALLTYPE *EnumValues)(ISpObjectToken *, ULONG, LPWSTR *);
    /* ISpObjectToken */
    HRESULT (STDMETHODCALLTYPE *SetId)(ISpObjectToken *, LPCWSTR, LPCWSTR, BOOL);
    HRESULT (STDMETHODCALLTYPE *GetId)(ISpObjectToken *, LPWSTR *);
} ISpObjectTokenVtbl;
struct ISpObjectToken { const ISpObjectTokenVtbl *lpVtbl; };

typedef struct ISpVoice ISpVoice;
typedef struct ISpVoiceVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(ISpVoice *, REFIID, void **);
    ULONG   (STDMETHODCALLTYPE *AddRef)(ISpVoice *);
    ULONG   (STDMETHODCALLTYPE *Release)(ISpVoice *);
    /* ISpNotifySource */
    void *SetNotifySink, *SetNotifyWindowMessage, *SetNotifyCallbackFunction, *SetNotifyCallbackInterface,
         *SetNotifyWin32Event, *WaitForNotifyEvent, *GetNotifyEventHandle;
    /* ISpEventSource */
    void *SetInterest, *GetEvents, *GetInfo;
    /* ISpVoice */
    void *SetOutput, *GetOutputObjectToken, *GetOutputStream, *Pause, *Resume;
    HRESULT (STDMETHODCALLTYPE *SetVoice)(ISpVoice *, ISpObjectToken *);
    HRESULT (STDMETHODCALLTYPE *GetVoice)(ISpVoice *, ISpObjectToken **);
    HRESULT (STDMETHODCALLTYPE *Speak)(ISpVoice *, LPCWSTR, DWORD, ULONG *);
    void *SpeakStream, *GetStatus, *Skip, *SetPriority, *GetPriority, *SetAlertBoundary, *GetAlertBoundary,
         *SetRate, *GetRate, *SetVolume, *GetVolume;
    HRESULT (STDMETHODCALLTYPE *WaitUntilDone)(ISpVoice *, ULONG);
} ISpVoiceVtbl;
struct ISpVoice { const ISpVoiceVtbl *lpVtbl; };

enum { SPF_DEFAULT = 0, SPF_ASYNC = 1, SPF_PURGEBEFORESPEAK = 2 };

static FILE *g_log;
static DWORD g_t0;

static void logf_(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(g_log, "%6lu ms  ", (unsigned long)(GetTickCount() - g_t0));
    vfprintf(g_log, fmt, ap);
    fputc('\n', g_log);
    fflush(g_log);
    va_end(ap);
}

int main(void)
{
    char path[MAX_PATH];
    GetModuleFileNameA(NULL, path, MAX_PATH);
    char *slash = strrchr(path, '\\');
    if (slash) strcpy(slash + 1, "sapitest.log"); else strcpy(path, "sapitest.log");
    g_log = fopen(path, "w");
    if (!g_log) return 1;
    g_t0 = GetTickCount();
    logf_("sapitest %d-bit starting", (int)(sizeof(void *) * 8));

    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    logf_("CoInitializeEx: %#lx", (unsigned long)hr);

    ISpVoice *voice = NULL;
    hr = CoCreateInstance(&CLSID_SpVoice, NULL, CLSCTX_ALL, &IID_ISpVoice, (void **)&voice);
    logf_("CoCreateInstance(SpVoice): %#lx", (unsigned long)hr);
    if (FAILED(hr)) { CoUninitialize(); return 2; }

    ISpObjectToken *token = NULL;
    hr = voice->lpVtbl->GetVoice(voice, &token);
    if (SUCCEEDED(hr) && token) {
        LPWSTR id = NULL;
        if (SUCCEEDED(token->lpVtbl->GetId(token, &id)) && id) {
            logf_("default voice token: %ls", id);
            CoTaskMemFree(id);
        }
        token->lpVtbl->Release(token);
    } else {
        logf_("GetVoice: %#lx", (unsigned long)hr);
    }

    hr = voice->lpVtbl->Speak(voice, L"Hello from a Windows program in the bottle.", SPF_DEFAULT, NULL);
    logf_("synchronous Speak: %#lx", (unsigned long)hr);

    hr = voice->lpVtbl->Speak(voice, L"Second line, asynchronous, purging the first.", SPF_ASYNC | SPF_PURGEBEFORESPEAK, NULL);
    logf_("async Speak: %#lx", (unsigned long)hr);
    hr = voice->lpVtbl->WaitUntilDone(voice, 5000);
    logf_("WaitUntilDone(5 s): %#lx", (unsigned long)hr);

    voice->lpVtbl->Release(voice);
    CoUninitialize();
    logf_("done");
    fclose(g_log);
    return 0;
}
