/*
 * SpVoiceBridge.dll — a stand-in for SAPI's SpVoice object, for games under Wine.
 *
 * Wine's own SpVoice cannot render into a stream the game supplies: Diablo IV hands
 * SAPI an ISpStream of its own (it mixes the reader's audio into its sound engine),
 * Wine's speak thread answers "failed setting output format: E_NOTIMPL" to every
 * Speak, and the game gives up two minutes later with a fatal error — measured
 * 28 Sep 2026 with WINEDEBUG=+sapi: every reader-on run died 123 s after start.
 *
 * This DLL takes over CLSID_SpVoice ({96749377-3391-11D2-9EE3-00C04F797396}) in the
 * registry, so CoCreateInstance(CLSID_SpVoice) gives the game this object instead of
 * Wine's. It implements ISpVoice fully as a well-behaved voice that never produces
 * audio: Speak forwards the text to the SpeechBridge listener on 127.0.0.1:52134
 * (S <text> / X), returns at once, and reports itself done; WaitUntilDone returns
 * immediately; every event handle it hands out is already signalled. Voice tokens,
 * categories and streams are still Wine's — only the voice object is replaced, so
 * a game that enumerates SAPI voices (the SapiBridge tokens) keeps working.
 *
 * Registration (regsvr32, inside the bottle; the 32-bit build for 32-bit games):
 *   HKCR\CLSID\{96749377-...}\InprocServer32 = this DLL, ThreadingModel = Both
 * DllUnregisterServer points the class back at Wine's sapi.dll.
 *
 *   x86_64-w64-mingw32-gcc -shared -O2 -Wall -o SpVoiceBridge64.dll spvoice.c spvoice.def -lws2_32 -lole32 -static-libgcc
 *   i686-w64-mingw32-gcc   -shared -O2 -Wall -o SpVoiceBridge32.dll spvoice.c spvoice.def -lws2_32 -lole32 -static-libgcc
 */

#define COBJMACROS
#define INITGUID
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <objbase.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#define BRIDGE_PORT 52134
#define RECONNECT_MS 2000

DEFINE_GUID(CLSID_SpVoice,        0x96749377, 0x3391, 0x11d2, 0x9e, 0xe3, 0x00, 0xc0, 0x4f, 0x79, 0x73, 0x96);
DEFINE_GUID(IID_ISpNotifySource,  0x5eff4aef, 0x8487, 0x11d2, 0x96, 0x1c, 0x00, 0xc0, 0x4f, 0x8e, 0xe6, 0x28);
DEFINE_GUID(IID_ISpEventSource,   0xbe7a9cce, 0x5f9e, 0x11d2, 0x96, 0x0f, 0x00, 0xc0, 0x4f, 0x8e, 0xe6, 0x28);
DEFINE_GUID(IID_ISpVoice,         0x6c44df74, 0x72b9, 0x4992, 0xa1, 0xec, 0xef, 0x99, 0x6e, 0x04, 0x22, 0xd4);

enum { SPF_ASYNC = 1, SPF_PURGEBEFORESPEAK = 2, SPF_IS_FILENAME = 4, SPF_IS_XML = 8, SPF_IS_NOT_XML = 16 };
enum { SPRS_DONE = 0, SPRS_IS_SPEAKING = 1 };

typedef struct {
    ULONG ulCurrentStream; ULONG ulLastStreamQueued; HRESULT hrLastResult; DWORD dwRunningState;
    ULONG ulInputWordPos; ULONG ulInputWordLen; ULONG ulInputSentPos; ULONG ulInputSentLen;
    LONG lBookmarkId; USHORT PhonemeId; int VisemeId; DWORD dwReserved1; DWORD dwReserved2;
} SPVOICESTATUS;

/* ---- ISpVoice vtable, declared by hand (SAPI 5.1 order) ------------------------ */

typedef struct Voice Voice;
typedef struct ISpVoiceVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(Voice *, REFIID, void **);
    ULONG   (STDMETHODCALLTYPE *AddRef)(Voice *);
    ULONG   (STDMETHODCALLTYPE *Release)(Voice *);
    /* ISpNotifySource */
    HRESULT (STDMETHODCALLTYPE *SetNotifySink)(Voice *, void *);
    HRESULT (STDMETHODCALLTYPE *SetNotifyWindowMessage)(Voice *, HWND, UINT, WPARAM, LPARAM);
    HRESULT (STDMETHODCALLTYPE *SetNotifyCallbackFunction)(Voice *, void *, WPARAM, LPARAM);
    HRESULT (STDMETHODCALLTYPE *SetNotifyCallbackInterface)(Voice *, void *, WPARAM, LPARAM);
    HRESULT (STDMETHODCALLTYPE *SetNotifyWin32Event)(Voice *);
    HRESULT (STDMETHODCALLTYPE *WaitForNotifyEvent)(Voice *, DWORD);
    HANDLE  (STDMETHODCALLTYPE *GetNotifyEventHandle)(Voice *);
    /* ISpEventSource */
    HRESULT (STDMETHODCALLTYPE *SetInterest)(Voice *, ULONGLONG, ULONGLONG);
    HRESULT (STDMETHODCALLTYPE *GetEvents)(Voice *, ULONG, void *, ULONG *);
    HRESULT (STDMETHODCALLTYPE *GetInfo)(Voice *, void *);
    /* ISpVoice */
    HRESULT (STDMETHODCALLTYPE *SetOutput)(Voice *, IUnknown *, BOOL);
    HRESULT (STDMETHODCALLTYPE *GetOutputObjectToken)(Voice *, IUnknown **);
    HRESULT (STDMETHODCALLTYPE *GetOutputStream)(Voice *, IUnknown **);
    HRESULT (STDMETHODCALLTYPE *Pause)(Voice *);
    HRESULT (STDMETHODCALLTYPE *Resume)(Voice *);
    HRESULT (STDMETHODCALLTYPE *SetVoice)(Voice *, IUnknown *);
    HRESULT (STDMETHODCALLTYPE *GetVoice)(Voice *, IUnknown **);
    HRESULT (STDMETHODCALLTYPE *Speak)(Voice *, LPCWSTR, DWORD, ULONG *);
    HRESULT (STDMETHODCALLTYPE *SpeakStream)(Voice *, IUnknown *, DWORD, ULONG *);
    HRESULT (STDMETHODCALLTYPE *GetStatus)(Voice *, SPVOICESTATUS *, LPWSTR *);
    HRESULT (STDMETHODCALLTYPE *Skip)(Voice *, LPCWSTR, long, ULONG *);
    HRESULT (STDMETHODCALLTYPE *SetPriority)(Voice *, int);
    HRESULT (STDMETHODCALLTYPE *GetPriority)(Voice *, int *);
    HRESULT (STDMETHODCALLTYPE *SetAlertBoundary)(Voice *, int);
    HRESULT (STDMETHODCALLTYPE *GetAlertBoundary)(Voice *, int *);
    HRESULT (STDMETHODCALLTYPE *SetRate)(Voice *, long);
    HRESULT (STDMETHODCALLTYPE *GetRate)(Voice *, long *);
    HRESULT (STDMETHODCALLTYPE *SetVolume)(Voice *, USHORT);
    HRESULT (STDMETHODCALLTYPE *GetVolume)(Voice *, USHORT *);
    HRESULT (STDMETHODCALLTYPE *WaitUntilDone)(Voice *, ULONG);
    HRESULT (STDMETHODCALLTYPE *SetSyncSpeakTimeout)(Voice *, ULONG);
    HRESULT (STDMETHODCALLTYPE *GetSyncSpeakTimeout)(Voice *, ULONG *);
    HANDLE  (STDMETHODCALLTYPE *SpeakCompleteEvent)(Voice *);
    HRESULT (STDMETHODCALLTYPE *IsUISupported)(Voice *, LPCWSTR, void *, ULONG, BOOL *);
    HRESULT (STDMETHODCALLTYPE *DisplayUI)(Voice *, HWND, LPCWSTR, LPCWSTR, void *, ULONG);
} ISpVoiceVtbl;

struct Voice {
    const ISpVoiceVtbl *lpVtbl;
    LONG refs;
    IUnknown *token;         /* the voice the game chose, handed back by GetVoice */
    IUnknown *output;        /* what SetOutput gave us; kept alive, never used */
    HANDLE done;             /* manual-reset, always signalled */
    long rate;
    USHORT volume;
    int priority;
    int alertBoundary;
    ULONG syncTimeout;
    ULONG streams;
    HRESULT lastResult;
};

/* ---- globals, log, queue, worker (the SpeechBridge core) -------------------------- */

static HMODULE g_module;
static WCHAR g_logPath[MAX_PATH];
static CRITICAL_SECTION g_lock;
static HANDLE g_wake;
static HANDLE g_worker;
static volatile LONG g_started;
static volatile LONG g_objects;

typedef struct Item { struct Item *next; char *line; int cancel; } Item;
static Item *g_head, *g_tail;

static void logLine(const char *utf8)
{
    if (!g_logPath[0]) return;
    FILE *f = _wfopen(g_logPath, L"ab");
    if (!f) return;
    SYSTEMTIME t; GetLocalTime(&t);
    fprintf(f, "%02d:%02d:%02d.%03d %s\n", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds, utf8);
    fclose(f);
}

static void initLogPath(void)
{
    WCHAR path[MAX_PATH];
    if (!GetModuleFileNameW(g_module, path, MAX_PATH)) return;
    WCHAR *slash = wcsrchr(path, L'\\');
    if (!slash) return;
    slash[1] = 0;
    wcscpy(g_logPath, path);
    wcscat(g_logPath, L"SpVoiceBridge.log");
}

static void enqueue(char *line, int cancel)
{
    Item *it = (Item *)malloc(sizeof *it);
    if (!it) { free(line); return; }
    it->next = NULL; it->line = line; it->cancel = cancel;
    EnterCriticalSection(&g_lock);
    if (cancel) { Item *p = g_head; while (p) { Item *n = p->next; free(p->line); free(p); p = n; } g_head = g_tail = NULL; }
    if (g_tail) g_tail->next = it; else g_head = it;
    g_tail = it;
    LeaveCriticalSection(&g_lock);
    SetEvent(g_wake);
}

static Item *dequeue(void)
{
    EnterCriticalSection(&g_lock);
    Item *it = g_head;
    if (it) { g_head = it->next; if (!g_head) g_tail = NULL; }
    LeaveCriticalSection(&g_lock);
    return it;
}

static SOCKET tryConnect(void)
{
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) return INVALID_SOCKET;
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_port = htons(BRIDGE_PORT); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(s, (struct sockaddr *)&a, sizeof a) != 0) {
        char msg[64]; snprintf(msg, sizeof msg, "# no listener on 127.0.0.1:%d (error %d)", BRIDGE_PORT, WSAGetLastError());
        logLine(msg); closesocket(s); return INVALID_SOCKET;
    }
    BOOL nodelay = TRUE; setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (const char *)&nodelay, sizeof nodelay);
    logLine("# connected to listener");
    return s;
}

static int sendAll(SOCKET s, const char *p, int n)
{
    while (n > 0) { int k = send(s, p, n, 0); if (k <= 0) return 0; p += k; n -= k; }
    return 1;
}

static DWORD WINAPI worker(LPVOID arg)
{
    (void)arg;
    WSADATA wsa; WSAStartup(MAKEWORD(2, 2), &wsa);
    SOCKET s = INVALID_SOCKET; DWORD lastTry = 0;
    for (;;) {
        WaitForSingleObject(g_wake, s == INVALID_SOCKET ? RECONNECT_MS : INFINITE);
        Item *it;
        while ((it = dequeue()) != NULL) {
            if (s == INVALID_SOCKET && GetTickCount() - lastTry >= RECONNECT_MS) { lastTry = GetTickCount(); s = tryConnect(); }
            if (s != INVALID_SOCKET && !sendAll(s, it->line, (int)strlen(it->line))) { logLine("# listener went away"); closesocket(s); s = INVALID_SOCKET; }
            free(it->line); free(it);
        }
    }
    return 0;
}

static void ensureStarted(void)
{
    if (InterlockedCompareExchange(&g_started, 1, 0) != 0) return;
    logLine("# SpeechBridge SpVoice loaded");
    g_worker = CreateThread(NULL, 0, worker, NULL, 0, NULL);
}

/* ---- text: strip SAPI XML tags when asked to, fold newlines, UTF-8 ------------------ */

static char *lineFor(const WCHAR *text, BOOL isXml)
{
    size_t n = wcslen(text);
    WCHAR *plain = (WCHAR *)malloc((n + 1) * sizeof(WCHAR));
    if (!plain) return NULL;
    size_t o = 0; int inTag = 0;
    for (size_t i = 0; i < n; i++) {
        WCHAR c = text[i];
        if (isXml) {
            if (c == L'<') { inTag = 1; continue; }
            if (c == L'>') { inTag = 0; plain[o++] = L' '; continue; }
            if (inTag) continue;
        }
        plain[o++] = (c == L'\r' || c == L'\n') ? L' ' : c;
    }
    plain[o] = 0;
    int u = WideCharToMultiByte(CP_UTF8, 0, plain, -1, NULL, 0, NULL, NULL);
    char *line = u > 0 ? (char *)malloc(2 + u + 1) : NULL;
    if (line) {
        line[0] = 'S'; line[1] = ' ';
        WideCharToMultiByte(CP_UTF8, 0, plain, -1, line + 2, u, NULL, NULL);
        int len = 2 + u - 1;
        line[len] = '\n'; line[len + 1] = 0;
    }
    free(plain);
    return line;
}

/* ---- the voice ----------------------------------------------------------------------- */

static HRESULT STDMETHODCALLTYPE v_QueryInterface(Voice *self, REFIID riid, void **out)
{
    if (!out) return E_POINTER;
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_ISpNotifySource) ||
        IsEqualIID(riid, &IID_ISpEventSource) || IsEqualIID(riid, &IID_ISpVoice)) {
        *out = self; InterlockedIncrement(&self->refs); return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE v_AddRef(Voice *self) { return InterlockedIncrement(&self->refs); }
static ULONG STDMETHODCALLTYPE v_Release(Voice *self)
{
    LONG r = InterlockedDecrement(&self->refs);
    if (r == 0) {
        if (self->token) IUnknown_Release(self->token);
        if (self->output) IUnknown_Release(self->output);
        if (self->done) CloseHandle(self->done);
        free(self);
        InterlockedDecrement(&g_objects);
    }
    return r;
}

static HRESULT STDMETHODCALLTYPE v_SetNotifySink(Voice *s, void *p) { (void)s; (void)p; return S_OK; }
static HRESULT STDMETHODCALLTYPE v_SetNotifyWindowMessage(Voice *s, HWND h, UINT m, WPARAM w, LPARAM l) { (void)s;(void)h;(void)m;(void)w;(void)l; return S_OK; }
static HRESULT STDMETHODCALLTYPE v_SetNotifyCallbackFunction(Voice *s, void *f, WPARAM w, LPARAM l) { (void)s;(void)f;(void)w;(void)l; return S_OK; }
static HRESULT STDMETHODCALLTYPE v_SetNotifyCallbackInterface(Voice *s, void *i, WPARAM w, LPARAM l) { (void)s;(void)i;(void)w;(void)l; return S_OK; }
static HRESULT STDMETHODCALLTYPE v_SetNotifyWin32Event(Voice *s) { (void)s; return S_OK; }
static HRESULT STDMETHODCALLTYPE v_WaitForNotifyEvent(Voice *s, DWORD ms) { (void)s; (void)ms; return S_OK; }
static HANDLE  STDMETHODCALLTYPE v_GetNotifyEventHandle(Voice *s) { return s->done; }
static HRESULT STDMETHODCALLTYPE v_SetInterest(Voice *s, ULONGLONG a, ULONGLONG b) { (void)s;(void)a;(void)b; return S_OK; }
static HRESULT STDMETHODCALLTYPE v_GetEvents(Voice *s, ULONG count, void *events, ULONG *fetched) { (void)s;(void)count;(void)events; if (fetched) *fetched = 0; return S_FALSE; }
static HRESULT STDMETHODCALLTYPE v_GetInfo(Voice *s, void *info) { (void)s; if (info) memset(info, 0, 8); return S_OK; }

static HRESULT STDMETHODCALLTYPE v_SetOutput(Voice *self, IUnknown *output, BOOL allowChanges)
{
    (void)allowChanges;
    if (self->output) IUnknown_Release(self->output);
    self->output = output;
    if (output) IUnknown_AddRef(output);
    logLine(output ? "# SetOutput: the game supplied its own stream (ignored; no audio is produced)" : "# SetOutput: default");
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE v_GetOutputObjectToken(Voice *s, IUnknown **out) { (void)s; if (!out) return E_POINTER; *out = NULL; return S_FALSE; }
static HRESULT STDMETHODCALLTYPE v_GetOutputStream(Voice *s, IUnknown **out)
{
    if (!out) return E_POINTER;
    *out = s->output;
    if (s->output) { IUnknown_AddRef(s->output); return S_OK; }
    return S_FALSE;
}
static HRESULT STDMETHODCALLTYPE v_Pause(Voice *s) { (void)s; return S_OK; }
static HRESULT STDMETHODCALLTYPE v_Resume(Voice *s) { (void)s; return S_OK; }

static HRESULT STDMETHODCALLTYPE v_SetVoice(Voice *self, IUnknown *token)
{
    if (self->token) IUnknown_Release(self->token);
    self->token = token;
    if (token) IUnknown_AddRef(token);
    logLine("# SetVoice");
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE v_GetVoice(Voice *self, IUnknown **out)
{
    if (!out) return E_POINTER;
    *out = self->token;
    if (self->token) { IUnknown_AddRef(self->token); return S_OK; }
    return S_FALSE;
}

static HRESULT STDMETHODCALLTYPE v_Speak(Voice *self, LPCWSTR text, DWORD flags, ULONG *streamNumber)
{
    ensureStarted();
    if (flags & SPF_PURGEBEFORESPEAK) { char *x = _strdup("X\n"); if (x) enqueue(x, 1); }
    if (!text) {
        if (streamNumber) *streamNumber = self->streams;
        return (flags & SPF_PURGEBEFORESPEAK) ? S_OK : E_POINTER;
    }
    if (flags & SPF_IS_FILENAME) {
        logLine("# Speak of a file name (ignored)");
        if (streamNumber) *streamNumber = ++self->streams;
        return S_OK;
    }
    char *line = lineFor(text, (flags & SPF_IS_XML) != 0);
    if (line && strlen(line) > 3) {
        size_t len = strlen(line);
        line[len - 1] = 0; logLine(line); line[len - 1] = '\n';
        enqueue(line, 0);
    } else if (line) free(line);
    if (streamNumber) *streamNumber = ++self->streams;
    self->lastResult = S_OK;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE v_SpeakStream(Voice *self, IUnknown *stream, DWORD flags, ULONG *streamNumber)
{
    (void)stream; (void)flags;
    logLine("# SpeakStream (ignored)");
    if (streamNumber) *streamNumber = ++self->streams;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE v_GetStatus(Voice *self, SPVOICESTATUS *status, LPWSTR *bookmark)
{
    if (status) {
        memset(status, 0, sizeof *status);
        status->ulCurrentStream = self->streams;
        status->ulLastStreamQueued = self->streams;
        status->hrLastResult = self->lastResult;
        status->dwRunningState = SPRS_DONE;
    }
    if (bookmark) *bookmark = NULL;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE v_Skip(Voice *s, LPCWSTR type, long n, ULONG *skipped) { (void)s;(void)type;(void)n; if (skipped) *skipped = 0; return S_OK; }
static HRESULT STDMETHODCALLTYPE v_SetPriority(Voice *s, int p) { s->priority = p; return S_OK; }
static HRESULT STDMETHODCALLTYPE v_GetPriority(Voice *s, int *p) { if (!p) return E_POINTER; *p = s->priority; return S_OK; }
static HRESULT STDMETHODCALLTYPE v_SetAlertBoundary(Voice *s, int b) { s->alertBoundary = b; return S_OK; }
static HRESULT STDMETHODCALLTYPE v_GetAlertBoundary(Voice *s, int *b) { if (!b) return E_POINTER; *b = s->alertBoundary; return S_OK; }
static HRESULT STDMETHODCALLTYPE v_SetRate(Voice *s, long r) { s->rate = r; return S_OK; }
static HRESULT STDMETHODCALLTYPE v_GetRate(Voice *s, long *r) { if (!r) return E_POINTER; *r = s->rate; return S_OK; }
static HRESULT STDMETHODCALLTYPE v_SetVolume(Voice *s, USHORT v) { s->volume = v; return S_OK; }
static HRESULT STDMETHODCALLTYPE v_GetVolume(Voice *s, USHORT *v) { if (!v) return E_POINTER; *v = s->volume; return S_OK; }
static HRESULT STDMETHODCALLTYPE v_WaitUntilDone(Voice *s, ULONG ms) { (void)s; (void)ms; return S_OK; }
static HRESULT STDMETHODCALLTYPE v_SetSyncSpeakTimeout(Voice *s, ULONG ms) { s->syncTimeout = ms; return S_OK; }
static HRESULT STDMETHODCALLTYPE v_GetSyncSpeakTimeout(Voice *s, ULONG *ms) { if (!ms) return E_POINTER; *ms = s->syncTimeout; return S_OK; }
static HANDLE  STDMETHODCALLTYPE v_SpeakCompleteEvent(Voice *s) { return s->done; }
static HRESULT STDMETHODCALLTYPE v_IsUISupported(Voice *s, LPCWSTR type, void *extra, ULONG cb, BOOL *supported) { (void)s;(void)type;(void)extra;(void)cb; if (supported) *supported = FALSE; return S_OK; }
static HRESULT STDMETHODCALLTYPE v_DisplayUI(Voice *s, HWND h, LPCWSTR title, LPCWSTR type, void *extra, ULONG cb) { (void)s;(void)h;(void)title;(void)type;(void)extra;(void)cb; return E_NOTIMPL; }

static const ISpVoiceVtbl g_voiceVtbl = {
    v_QueryInterface, v_AddRef, v_Release,
    v_SetNotifySink, v_SetNotifyWindowMessage, v_SetNotifyCallbackFunction, v_SetNotifyCallbackInterface,
    v_SetNotifyWin32Event, v_WaitForNotifyEvent, v_GetNotifyEventHandle,
    v_SetInterest, v_GetEvents, v_GetInfo,
    v_SetOutput, v_GetOutputObjectToken, v_GetOutputStream, v_Pause, v_Resume, v_SetVoice, v_GetVoice,
    v_Speak, v_SpeakStream, v_GetStatus, v_Skip, v_SetPriority, v_GetPriority, v_SetAlertBoundary, v_GetAlertBoundary,
    v_SetRate, v_GetRate, v_SetVolume, v_GetVolume, v_WaitUntilDone, v_SetSyncSpeakTimeout, v_GetSyncSpeakTimeout,
    v_SpeakCompleteEvent, v_IsUISupported, v_DisplayUI
};

/* ---- class factory ------------------------------------------------------------------- */

typedef struct { const IClassFactoryVtbl *lpVtbl; } Factory;

static HRESULT STDMETHODCALLTYPE f_QueryInterface(IClassFactory *iface, REFIID riid, void **out)
{
    if (!out) return E_POINTER;
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IClassFactory)) { *out = iface; return S_OK; }
    *out = NULL; return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE f_AddRef(IClassFactory *i) { (void)i; return 2; }
static ULONG STDMETHODCALLTYPE f_Release(IClassFactory *i) { (void)i; return 1; }
static HRESULT STDMETHODCALLTYPE f_CreateInstance(IClassFactory *iface, IUnknown *outer, REFIID riid, void **out)
{
    (void)iface;
    if (!out) return E_POINTER;
    *out = NULL;
    if (outer) return CLASS_E_NOAGGREGATION;
    Voice *v = (Voice *)calloc(1, sizeof *v);
    if (!v) return E_OUTOFMEMORY;
    v->lpVtbl = &g_voiceVtbl;
    v->refs = 1;
    v->volume = 100;
    v->done = CreateEventW(NULL, TRUE, TRUE, NULL);   /* manual-reset, born signalled */
    InterlockedIncrement(&g_objects);
    ensureStarted();
    logLine("# SpVoice created for a game");
    HRESULT hr = v_QueryInterface(v, riid, out);
    v_Release(v);
    return hr;
}
static HRESULT STDMETHODCALLTYPE f_LockServer(IClassFactory *i, BOOL l) { (void)i; (void)l; return S_OK; }
static const IClassFactoryVtbl g_factoryVtbl = { f_QueryInterface, f_AddRef, f_Release, f_CreateInstance, f_LockServer };
static Factory g_factory = { &g_factoryVtbl };

/* ---- exports --------------------------------------------------------------------------- */

__declspec(dllexport) HRESULT WINAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, void **out)
{
    if (!IsEqualCLSID(rclsid, &CLSID_SpVoice)) return CLASS_E_CLASSNOTAVAILABLE;
    return f_QueryInterface((IClassFactory *)&g_factory, riid, out);
}
__declspec(dllexport) HRESULT WINAPI DllCanUnloadNow(void) { return g_objects == 0 ? S_OK : S_FALSE; }

static const WCHAR *CLSID_KEY = L"CLSID\\{96749377-3391-11D2-9EE3-00C04F797396}\\InprocServer32";

static LONG setValue(HKEY root, const WCHAR *key, const WCHAR *name, const WCHAR *value)
{
    HKEY h; LONG r = RegCreateKeyExW(root, key, 0, NULL, 0, KEY_SET_VALUE, NULL, &h, NULL);
    if (r != ERROR_SUCCESS) return r;
    r = RegSetValueExW(h, name, 0, REG_SZ, (const BYTE *)value, (DWORD)((wcslen(value) + 1) * sizeof(WCHAR)));
    RegCloseKey(h); return r;
}

__declspec(dllexport) HRESULT WINAPI DllRegisterServer(void)
{
    WCHAR path[MAX_PATH];
    if (!GetModuleFileNameW(g_module, path, MAX_PATH)) return E_FAIL;
    if (setValue(HKEY_CLASSES_ROOT, CLSID_KEY, NULL, path) != ERROR_SUCCESS) return E_ACCESSDENIED;
    setValue(HKEY_CLASSES_ROOT, CLSID_KEY, L"ThreadingModel", L"Both");
    ensureStarted();
    logLine("# registered as SAPI's SpVoice class");
    return S_OK;
}

/* Points the class back at Wine's sapi.dll, which is where it lives in a fresh bottle. */
__declspec(dllexport) HRESULT WINAPI DllUnregisterServer(void)
{
    setValue(HKEY_CLASSES_ROOT, CLSID_KEY, NULL, L"C:\\windows\\system32\\Speech\\Common\\sapi.dll");
    setValue(HKEY_CLASSES_ROOT, CLSID_KEY, L"ThreadingModel", L"Both");
    return S_OK;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        g_module = inst;
        DisableThreadLibraryCalls(inst);
        InitializeCriticalSection(&g_lock);
        g_wake = CreateEventW(NULL, FALSE, FALSE, NULL);
        initLogPath();
    }
    return TRUE;
}
