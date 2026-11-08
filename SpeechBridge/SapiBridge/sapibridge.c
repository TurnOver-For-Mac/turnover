/*
 * SapiBridge — a SAPI 5 text-to-speech "engine" for Windows games running under
 * CrossOver / Wine, which forwards every utterance to the Mac instead of
 * synthesising it.
 *
 * Wine ships a SAPI implementation and a default voice whose engine is a stub:
 * ISpTTSEngine::Speak does nothing (msttsengine.dll, "stub"), so a game that
 * uses the built-in Windows voice runs and says nothing. This DLL registers a
 * real voice token whose engine is us. Wine's SpVoice then calls our Speak with
 * the game's text, and we
 *   1. append it to SpeechBridge.log beside the DLL (proof of life, no listener
 *      needed), and
 *   2. send it to 127.0.0.1:52134 with the same line protocol as SAAPI64.dll:
 *        S <utf-8 text>\n   speak this
 *        X\n                stop speaking
 *      which SpeechBridge/listener speaks through VoiceOver or the system voice.
 *
 * Wine's speak thread waits for the audio the engine wrote to finish playing
 * before the game's Speak call completes, so we write a few milliseconds of
 * silence per utterance; nothing else touches the audio device.
 *
 * Build (both are needed — a 32-bit game loads the 32-bit DLL):
 *   x86_64-w64-mingw32-gcc -shared -O2 -Wall -o SapiBridge64.dll sapibridge.c sapibridge.def -lws2_32 -lole32 -luuid -static-libgcc
 *   i686-w64-mingw32-gcc   -shared -O2 -Wall -o SapiBridge32.dll sapibridge.c sapibridge.def -lws2_32 -lole32 -luuid -static-libgcc
 * Register inside the bottle (each writes its own registry view):
 *   regsvr32 SapiBridge64.dll
 *   regsvr32 SapiBridge32.dll
 * Registration also makes this the default voice, so a game that never picks a
 * voice gets it.
 *
 * The SAPI engine-side interfaces are declared here by hand (the SDK's
 * sapiddk.h is not part of MinGW); layouts are SAPI 5.1's.
 */

#define COBJMACROS
#define INITGUID
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <objbase.h>
#include <mmreg.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#define BRIDGE_PORT 52134
#define RECONNECT_MS 2000
#define SAMPLE_RATE 16000
#define SILENCE_MS 40

/* ---- SAPI declarations we need --------------------------------------------- */

DEFINE_GUID(CLSID_SapiBridge,      0x7b5d1a8e, 0x2c3f, 0x4e6a, 0x9b, 0x01, 0x5f, 0x0e, 0x1c, 0x2d, 0x3a, 0x4b);
DEFINE_GUID(IID_ISpTTSEngine,      0xa74d7c8e, 0x4cc5, 0x4f2f, 0xa6, 0xeb, 0x80, 0x4d, 0xee, 0x18, 0x50, 0x0e);
DEFINE_GUID(IID_ISpObjectWithToken,0x5b559f40, 0xe952, 0x11d2, 0xbb, 0x91, 0x00, 0xc0, 0x4f, 0x8e, 0xe6, 0xc0);
DEFINE_GUID(SPDFID_WaveFormatEx,   0xc31adbae, 0x527f, 0x4ff5, 0xa2, 0x30, 0xf6, 0x2b, 0xb6, 0x1f, 0xf7, 0x0c);

enum { SPVES_CONTINUE = 0, SPVES_SKIP = 1, SPVES_ABORT = 2, SPVES_RATE = 4, SPVES_VOLUME = 8 };
enum { SPVA_Speak = 0, SPVA_Silence, SPVA_Pronounce, SPVA_Bookmark, SPVA_SpellOut, SPVA_Section, SPVA_ParseUnknownTag };

typedef struct { long MiddleAdj; long RangeAdj; } SPVPITCH;
typedef struct { LPCWSTR pCategory; LPCWSTR pBefore; LPCWSTR pAfter; } SPVCONTEXT;
typedef struct {
    int eAction;            /* SPVACTIONS */
    WORD LangID;
    WORD wReserved;
    long EmphAdj;
    long RateAdj;
    ULONG Volume;
    SPVPITCH PitchAdj;
    ULONG SilenceMSecs;
    WCHAR *pPhoneIds;
    int ePartOfSpeech;      /* SPPARTOFSPEECH */
    SPVCONTEXT Context;
} SPVSTATE;
typedef struct SPVTEXTFRAG {
    struct SPVTEXTFRAG *pNext;
    SPVSTATE State;
    LPCWSTR pTextStart;
    ULONG ulTextLen;
    ULONG ulTextSrcOffset;
} SPVTEXTFRAG;

typedef struct ISpTTSEngineSite ISpTTSEngineSite;
typedef struct ISpTTSEngineSiteVtbl {
    /* IUnknown */
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(ISpTTSEngineSite *, REFIID, void **);
    ULONG   (STDMETHODCALLTYPE *AddRef)(ISpTTSEngineSite *);
    ULONG   (STDMETHODCALLTYPE *Release)(ISpTTSEngineSite *);
    /* ISpEventSink */
    HRESULT (STDMETHODCALLTYPE *AddEvents)(ISpTTSEngineSite *, const void *, ULONG);
    HRESULT (STDMETHODCALLTYPE *GetEventInterest)(ISpTTSEngineSite *, ULONGLONG *);
    /* ISpTTSEngineSite */
    DWORD   (STDMETHODCALLTYPE *GetActions)(ISpTTSEngineSite *);
    HRESULT (STDMETHODCALLTYPE *Write)(ISpTTSEngineSite *, const void *, ULONG, ULONG *);
    HRESULT (STDMETHODCALLTYPE *GetRate)(ISpTTSEngineSite *, long *);
    HRESULT (STDMETHODCALLTYPE *GetVolume)(ISpTTSEngineSite *, USHORT *);
    HRESULT (STDMETHODCALLTYPE *GetSkipInfo)(ISpTTSEngineSite *, int *, long *);
    HRESULT (STDMETHODCALLTYPE *CompleteSkip)(ISpTTSEngineSite *, long);
} ISpTTSEngineSiteVtbl;
struct ISpTTSEngineSite { const ISpTTSEngineSiteVtbl *lpVtbl; };

typedef struct Engine Engine;
typedef struct ISpTTSEngineVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(Engine *, REFIID, void **);
    ULONG   (STDMETHODCALLTYPE *AddRef)(Engine *);
    ULONG   (STDMETHODCALLTYPE *Release)(Engine *);
    HRESULT (STDMETHODCALLTYPE *Speak)(Engine *, DWORD, REFGUID, const WAVEFORMATEX *, const SPVTEXTFRAG *, ISpTTSEngineSite *);
    HRESULT (STDMETHODCALLTYPE *GetOutputFormat)(Engine *, const GUID *, const WAVEFORMATEX *, GUID *, WAVEFORMATEX **);
} ISpTTSEngineVtbl;

typedef struct ISpObjectWithTokenVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(void *, REFIID, void **);
    ULONG   (STDMETHODCALLTYPE *AddRef)(void *);
    ULONG   (STDMETHODCALLTYPE *Release)(void *);
    HRESULT (STDMETHODCALLTYPE *SetObjectToken)(void *, IUnknown *);
    HRESULT (STDMETHODCALLTYPE *GetObjectToken)(void *, IUnknown **);
} ISpObjectWithTokenVtbl;

struct Engine {
    const ISpTTSEngineVtbl *engineVtbl;
    const ISpObjectWithTokenVtbl *tokenVtbl;   /* second interface, at offset sizeof(void*) */
    LONG refs;
    IUnknown *token;
};

/* ---- globals ----------------------------------------------------------------- */

static HMODULE g_module;
static WCHAR g_logPath[MAX_PATH];
static CRITICAL_SECTION g_lock;
static HANDLE g_wake;
static HANDLE g_worker;
static volatile LONG g_started;
static volatile LONG g_objects;

typedef struct Item { struct Item *next; char *line; int cancel; } Item;
static Item *g_head, *g_tail;

/* ---- log file (never load-bearing, never fatal) ------------------------------ */

static void logLine(const char *utf8)
{
    if (!g_logPath[0]) return;
    FILE *f = _wfopen(g_logPath, L"ab");
    if (!f) return;
    SYSTEMTIME t;
    GetLocalTime(&t);
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
    wcscat(g_logPath, L"SpeechBridge.log");
}

/* ---- queue + worker: owns the socket, reconnects, never blocks the caller ---- */

static void enqueue(char *line, int cancel)
{
    Item *it = (Item *)malloc(sizeof *it);
    if (!it) { free(line); return; }
    it->next = NULL; it->line = line; it->cancel = cancel;
    EnterCriticalSection(&g_lock);
    if (cancel) {
        Item *p = g_head;
        while (p) { Item *n = p->next; free(p->line); free(p); p = n; }
        g_head = g_tail = NULL;
    }
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
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons(BRIDGE_PORT);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(s, (struct sockaddr *)&a, sizeof a) != 0) {
        char msg[64];
        snprintf(msg, sizeof msg, "# no listener on 127.0.0.1:%d (error %d)", BRIDGE_PORT, WSAGetLastError());
        logLine(msg);
        closesocket(s);
        return INVALID_SOCKET;
    }
    BOOL nodelay = TRUE;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (const char *)&nodelay, sizeof nodelay);
    logLine("# connected to listener");
    return s;
}

static int sendAll(SOCKET s, const char *p, int n)
{
    while (n > 0) {
        int k = send(s, p, n, 0);
        if (k <= 0) return 0;
        p += k; n -= k;
    }
    return 1;
}

static DWORD WINAPI worker(LPVOID arg)
{
    (void)arg;
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
    SOCKET s = INVALID_SOCKET;
    DWORD lastTry = 0;
    for (;;) {
        WaitForSingleObject(g_wake, s == INVALID_SOCKET ? RECONNECT_MS : INFINITE);
        Item *it;
        while ((it = dequeue()) != NULL) {
            if (s == INVALID_SOCKET && GetTickCount() - lastTry >= RECONNECT_MS) {
                lastTry = GetTickCount();
                s = tryConnect();
            }
            if (s != INVALID_SOCKET && !sendAll(s, it->line, (int)strlen(it->line))) {
                logLine("# listener went away");
                closesocket(s);
                s = INVALID_SOCKET;
            }
            free(it->line);
            free(it);
        }
    }
    return 0;
}

/* The lock, the event and the log path are set up in DllMain, so two threads calling in
   at once cannot race past the "started" flag into an uninitialised critical section
   (Tolk's callers are not always the game's main thread). Only the worker thread, which
   must not be created inside the loader lock, waits for the first call. */
static void ensureStarted(void)
{
    if (InterlockedCompareExchange(&g_started, 1, 0) != 0) return;
    logLine("# SpeechBridge SAPI engine loaded");
    g_worker = CreateThread(NULL, 0, worker, NULL, 0, NULL);
}

/* ---- text ----------------------------------------------------------------------- */

/* Joins every spoken fragment into one "S ...\n" line (UTF-8, newlines folded). */
static char *lineForFragments(const SPVTEXTFRAG *frag)
{
    size_t cap = 256, len = 0;
    WCHAR *text = (WCHAR *)malloc(cap * sizeof(WCHAR));
    if (!text) return NULL;
    for (; frag; frag = frag->pNext) {
        if (frag->State.eAction != SPVA_Speak && frag->State.eAction != SPVA_SpellOut) continue;
        if (!frag->pTextStart || !frag->ulTextLen) continue;
        if (len + frag->ulTextLen + 2 > cap) {
            cap = (len + frag->ulTextLen + 2) * 2;
            WCHAR *grown = (WCHAR *)realloc(text, cap * sizeof(WCHAR));
            if (!grown) { free(text); return NULL; }
            text = grown;
        }
        if (len) text[len++] = L' ';
        memcpy(text + len, frag->pTextStart, frag->ulTextLen * sizeof(WCHAR));
        len += frag->ulTextLen;
    }
    text[len] = 0;
    if (!len) { free(text); return NULL; }

    int n = WideCharToMultiByte(CP_UTF8, 0, text, -1, NULL, 0, NULL, NULL);
    char *line = n > 0 ? (char *)malloc(2 + n + 1) : NULL;
    if (line) {
        line[0] = 'S'; line[1] = ' ';
        WideCharToMultiByte(CP_UTF8, 0, text, -1, line + 2, n, NULL, NULL);
        int total = 2 + n - 1;
        for (int i = 2; i < total; i++) if (line[i] == '\r' || line[i] == '\n') line[i] = ' ';
        line[total] = '\n';
        line[total + 1] = 0;
    }
    free(text);
    return line;
}

/* ---- ISpTTSEngine / ISpObjectWithToken --------------------------------------------- */

static HRESULT STDMETHODCALLTYPE engine_QueryInterface(Engine *self, REFIID riid, void **out)
{
    if (!out) return E_POINTER;
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_ISpTTSEngine)) {
        *out = self;
    } else if (IsEqualIID(riid, &IID_ISpObjectWithToken)) {
        *out = &self->tokenVtbl;
    } else {
        *out = NULL;
        return E_NOINTERFACE;
    }
    InterlockedIncrement(&self->refs);
    return S_OK;
}

static ULONG STDMETHODCALLTYPE engine_AddRef(Engine *self)
{
    return InterlockedIncrement(&self->refs);
}

static ULONG STDMETHODCALLTYPE engine_Release(Engine *self)
{
    LONG r = InterlockedDecrement(&self->refs);
    if (r == 0) {
        if (self->token) IUnknown_Release(self->token);
        free(self);
        InterlockedDecrement(&g_objects);
    }
    return r;
}

static HRESULT STDMETHODCALLTYPE engine_Speak(Engine *self, DWORD flags, REFGUID formatId,
                                              const WAVEFORMATEX *wfx, const SPVTEXTFRAG *frags,
                                              ISpTTSEngineSite *site)
{
    (void)self; (void)flags; (void)formatId;
    ensureStarted();

    char *line = lineForFragments(frags);
    if (line) {
        size_t len = strlen(line);
        line[len - 1] = 0; logLine(line); line[len - 1] = '\n';
        enqueue(line, 0);
    } else {
        logLine("# Speak with no spoken text");
    }

    /* Wine waits for the audio we wrote to finish before the game's call returns;
       give it a few milliseconds of silence so that wait always ends. */
    if (site && !(site->lpVtbl->GetActions(site) & SPVES_ABORT)) {
        ULONG bytesPerMs = wfx ? (wfx->nAvgBytesPerSec / 1000) : (SAMPLE_RATE * 2 / 1000);
        ULONG n = bytesPerMs * SILENCE_MS;
        if (n == 0 || n > 65536) n = SAMPLE_RATE * 2 / 1000 * SILENCE_MS;
        void *silence = calloc(1, n);
        if (silence) {
            ULONG written = 0;
            site->lpVtbl->Write(site, silence, n, &written);
            free(silence);
        }
    }
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE engine_GetOutputFormat(Engine *self, const GUID *targetId,
                                                        const WAVEFORMATEX *targetWfx,
                                                        GUID *outId, WAVEFORMATEX **outWfx)
{
    (void)self; (void)targetId; (void)targetWfx;
    if (!outId || !outWfx) return E_POINTER;
    WAVEFORMATEX *w = (WAVEFORMATEX *)CoTaskMemAlloc(sizeof *w);
    if (!w) return E_OUTOFMEMORY;
    memset(w, 0, sizeof *w);
    w->wFormatTag = WAVE_FORMAT_PCM;
    w->nChannels = 1;
    w->nSamplesPerSec = SAMPLE_RATE;
    w->wBitsPerSample = 16;
    w->nBlockAlign = 2;
    w->nAvgBytesPerSec = SAMPLE_RATE * 2;
    *outId = SPDFID_WaveFormatEx;
    *outWfx = w;
    return S_OK;
}

#define ENGINE_FROM_TOKEN(p) ((Engine *)((char *)(p) - offsetof(Engine, tokenVtbl)))

static HRESULT STDMETHODCALLTYPE token_QueryInterface(void *p, REFIID riid, void **out)
{
    return engine_QueryInterface(ENGINE_FROM_TOKEN(p), riid, out);
}
static ULONG STDMETHODCALLTYPE token_AddRef(void *p) { return engine_AddRef(ENGINE_FROM_TOKEN(p)); }
static ULONG STDMETHODCALLTYPE token_Release(void *p) { return engine_Release(ENGINE_FROM_TOKEN(p)); }

static HRESULT STDMETHODCALLTYPE token_SetObjectToken(void *p, IUnknown *token)
{
    Engine *self = ENGINE_FROM_TOKEN(p);
    if (self->token) IUnknown_Release(self->token);
    self->token = token;
    if (token) IUnknown_AddRef(token);
    ensureStarted();
    logLine("# engine bound to its voice token");
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE token_GetObjectToken(void *p, IUnknown **out)
{
    Engine *self = ENGINE_FROM_TOKEN(p);
    if (!out) return E_POINTER;
    *out = self->token;
    if (self->token) IUnknown_AddRef(self->token);
    return self->token ? S_OK : S_FALSE;
}

static const ISpTTSEngineVtbl g_engineVtbl = {
    engine_QueryInterface, engine_AddRef, engine_Release, engine_Speak, engine_GetOutputFormat
};
static const ISpObjectWithTokenVtbl g_tokenVtbl = {
    token_QueryInterface, token_AddRef, token_Release, token_SetObjectToken, token_GetObjectToken
};

/* ---- class factory ----------------------------------------------------------------- */

typedef struct { const IClassFactoryVtbl *lpVtbl; } Factory;

static HRESULT STDMETHODCALLTYPE factory_QueryInterface(IClassFactory *iface, REFIID riid, void **out)
{
    if (!out) return E_POINTER;
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IClassFactory)) { *out = iface; return S_OK; }
    *out = NULL;
    return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE factory_AddRef(IClassFactory *iface) { (void)iface; return 2; }
static ULONG STDMETHODCALLTYPE factory_Release(IClassFactory *iface) { (void)iface; return 1; }

static HRESULT STDMETHODCALLTYPE factory_CreateInstance(IClassFactory *iface, IUnknown *outer, REFIID riid, void **out)
{
    (void)iface;
    if (!out) return E_POINTER;
    *out = NULL;
    if (outer) return CLASS_E_NOAGGREGATION;
    Engine *e = (Engine *)calloc(1, sizeof *e);
    if (!e) return E_OUTOFMEMORY;
    e->engineVtbl = &g_engineVtbl;
    e->tokenVtbl = &g_tokenVtbl;
    e->refs = 1;
    InterlockedIncrement(&g_objects);
    ensureStarted();
    logLine("# engine instance created");
    HRESULT hr = engine_QueryInterface(e, riid, out);
    engine_Release(e);
    return hr;
}

static HRESULT STDMETHODCALLTYPE factory_LockServer(IClassFactory *iface, BOOL lock) { (void)iface; (void)lock; return S_OK; }

static const IClassFactoryVtbl g_factoryVtbl = {
    factory_QueryInterface, factory_AddRef, factory_Release, factory_CreateInstance, factory_LockServer
};
static Factory g_factory = { &g_factoryVtbl };

/* ---- exports ------------------------------------------------------------------------ */

__declspec(dllexport) HRESULT WINAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, void **out)
{
    if (!IsEqualCLSID(rclsid, &CLSID_SapiBridge)) return CLASS_E_CLASSNOTAVAILABLE;
    return factory_QueryInterface((IClassFactory *)&g_factory, riid, out);
}

__declspec(dllexport) HRESULT WINAPI DllCanUnloadNow(void)
{
    return g_objects == 0 ? S_OK : S_FALSE;
}

/* Registry: the COM class, a voice token, and "this is the default voice". */

/* Two tokens, one per language, because a game may ask SAPI for a voice whose Language
   is exactly "409" (Diablo IV: "failed to find a voice that supports en-us") and the
   list form "809;409" real SAPI accepts is not matched under Wine. */
static const WCHAR *TOKEN_KEY = L"SOFTWARE\\Microsoft\\Speech\\Voices\\Tokens\\SpeechBridge";
static const WCHAR *TOKEN_ID  = L"HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Speech\\Voices\\Tokens\\SpeechBridge";
static const WCHAR *VOICE_NAME = L"SpeechBridge (Mac voice)";
static const WCHAR *TOKEN_KEY_GB = L"SOFTWARE\\Microsoft\\Speech\\Voices\\Tokens\\SpeechBridgeGB";
static const WCHAR *VOICE_NAME_GB = L"SpeechBridge (Mac voice, UK)";
static const WCHAR *CLSID_TEXT = L"{7B5D1A8E-2C3F-4E6A-9B01-5F0E1C2D3A4B}";

static LONG setValue(HKEY root, const WCHAR *key, const WCHAR *name, const WCHAR *value)
{
    HKEY h;
    LONG r = RegCreateKeyExW(root, key, 0, NULL, 0, KEY_SET_VALUE, NULL, &h, NULL);
    if (r != ERROR_SUCCESS) return r;
    r = RegSetValueExW(h, name, 0, REG_SZ, (const BYTE *)value, (DWORD)((wcslen(value) + 1) * sizeof(WCHAR)));
    RegCloseKey(h);
    return r;
}

static void registerToken(const WCHAR *tokenKey, const WCHAR *voiceName, const WCHAR *langId, const WCHAR *name)
{
    WCHAR key[256];
    setValue(HKEY_LOCAL_MACHINE, tokenKey, NULL, voiceName);
    setValue(HKEY_LOCAL_MACHINE, tokenKey, L"CLSID", CLSID_TEXT);
    setValue(HKEY_LOCAL_MACHINE, tokenKey, langId, voiceName);
    swprintf(key, 256, L"%ls\\Attributes", tokenKey);
    setValue(HKEY_LOCAL_MACHINE, key, L"Age", L"Adult");
    setValue(HKEY_LOCAL_MACHINE, key, L"Gender", L"Female");
    setValue(HKEY_LOCAL_MACHINE, key, L"Language", langId);
    setValue(HKEY_LOCAL_MACHINE, key, L"Name", name);
    setValue(HKEY_LOCAL_MACHINE, key, L"Vendor", L"SpeechBridge");
}

__declspec(dllexport) HRESULT WINAPI DllRegisterServer(void)
{
    WCHAR path[MAX_PATH];
    if (!GetModuleFileNameW(g_module, path, MAX_PATH)) return E_FAIL;

    WCHAR key[256];
    swprintf(key, 256, L"CLSID\\%ls", CLSID_TEXT);
    if (setValue(HKEY_CLASSES_ROOT, key, NULL, L"SpeechBridge TTS Engine") != ERROR_SUCCESS) return E_ACCESSDENIED;
    swprintf(key, 256, L"CLSID\\%ls\\InprocServer32", CLSID_TEXT);
    setValue(HKEY_CLASSES_ROOT, key, NULL, path);
    setValue(HKEY_CLASSES_ROOT, key, L"ThreadingModel", L"Both");

    registerToken(TOKEN_KEY, VOICE_NAME, L"409", L"SpeechBridge");
    registerToken(TOKEN_KEY_GB, VOICE_NAME_GB, L"809", L"SpeechBridge UK");

    /* The default voice, for games that never choose one. Both hives: SAPI reads the
       user's first and falls back to the machine's. */
    setValue(HKEY_CURRENT_USER, L"SOFTWARE\\Microsoft\\Speech\\Voices", L"DefaultTokenId", TOKEN_ID);
    setValue(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Microsoft\\Speech\\Voices", L"DefaultTokenId", TOKEN_ID);
    /* Wine reads this name instead (dlls/sapi/token.c, token_category_GetDefaultTokenId);
       without it every default-voice lookup fails with SPERR_NOT_FOUND. */
    setValue(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Microsoft\\Speech\\Voices", L"DefaultDefaultTokenId", TOKEN_ID);

    ensureStarted();
    logLine("# registered as the default SAPI voice");
    return S_OK;
}

__declspec(dllexport) HRESULT WINAPI DllUnregisterServer(void)
{
    WCHAR key[256];
    RegDeleteTreeW(HKEY_LOCAL_MACHINE, TOKEN_KEY);
    RegDeleteTreeW(HKEY_LOCAL_MACHINE, TOKEN_KEY_GB);
    swprintf(key, 256, L"CLSID\\%ls", CLSID_TEXT);
    RegDeleteTreeW(HKEY_CLASSES_ROOT, key);
    RegDeleteKeyValueW(HKEY_CURRENT_USER, L"SOFTWARE\\Microsoft\\Speech\\Voices", L"DefaultTokenId");
    RegDeleteKeyValueW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Microsoft\\Speech\\Voices", L"DefaultTokenId");
    RegDeleteKeyValueW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Microsoft\\Speech\\Voices", L"DefaultDefaultTokenId");
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
        /* Nothing else here: no threads, no Winsock inside the loader lock. */
    }
    return TRUE;
}
