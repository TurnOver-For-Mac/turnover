/*
 * WindowsTTS.dll — a stand-in for the Unity Accessibility Plugin's Windows
 * text-to-speech plugin (the WindowsTTS.dll that ships inside Bits & Bops and
 * other UAP games).
 *
 * The real plugin speaks through Windows.Media.SpeechSynthesis, the WinRT API,
 * which Wine only partly implements: on 28 September 2026 Bits & Bops crashed
 * inside WindowsTTS.dll at start-up, before its first line, every time — even
 * with NVDA "present", because the game initialises the plugin regardless.
 * This DLL has the same nine exports and none of the WinRT. Speech goes to the
 * SpeechBridge listener on 127.0.0.1:52134 with the usual line protocol
 * (S <text> / X), and every call is logged to WindowsTTS.log beside the DLL.
 *
 * Exports and what the game expects of them (from UAP's C# side):
 *   Initialize()                       set up; nothing to do here
 *   DestroySpeech()                    tear down
 *   AddToSpeechQueue(text)             speak; a wide string in UAP, but the first
 *                                      bytes are checked so a UTF-8 caller works too
 *   StopSpeech()                       stop and drop the queue
 *   IsVoiceSpeaking() -> bool          the plugin's own voice is never speaking
 *   IsScreenReaderActive() -> bool     Windows reports a screen reader; we say yes
 *   SetRate(int) / SetVolume(int)      ignored
 *   SetCultureInfo(text)               ignored
 *   SetVoiceSAPI(voice)                ignored (older plugin generation)
 *
 * Put it in place of the game's copy (keep the original as .orig; a Steam
 * "verify integrity" restores it).
 *
 *   x86_64-w64-mingw32-gcc -shared -O2 -Wall -o WindowsTTS64.dll windowstts.c windowstts.def -lws2_32 -static-libgcc
 *   i686-w64-mingw32-gcc   -shared -O2 -Wall -o WindowsTTS32.dll windowstts.c windowstts.def -lws2_32 -static-libgcc
 */

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdio.h>
#include <string.h>

#define BRIDGE_PORT 52134
#define RECONNECT_MS 2000

static HMODULE g_module;
static WCHAR g_logPath[MAX_PATH];
static CRITICAL_SECTION g_lock;
static HANDLE g_wake;
static HANDLE g_worker;
static volatile LONG g_started;

typedef struct Item { struct Item *next; char *line; int cancel; } Item;
static Item *g_head, *g_tail;

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
    wcscat(g_logPath, L"WindowsTTS.log");
}

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
    logLine("# SpeechBridge WindowsTTS stand-in loaded");
    g_worker = CreateThread(NULL, 0, worker, NULL, 0, NULL);
}

/* "S ...\n" from either a wide or a UTF-8 string: a wide string's second byte is
   zero for any character below U+0100, which every real sentence starts with. */
static char *lineFor(const void *text)
{
    const unsigned char *b = (const unsigned char *)text;
    int wide = b[0] != 0 && b[1] == 0;
    int n;
    if (wide) n = WideCharToMultiByte(CP_UTF8, 0, (const WCHAR *)text, -1, NULL, 0, NULL, NULL);
    else n = (int)strlen((const char *)text) + 1;
    if (n <= 0) return NULL;
    char *line = (char *)malloc(2 + n + 1);
    if (!line) return NULL;
    line[0] = 'S'; line[1] = ' ';
    if (wide) WideCharToMultiByte(CP_UTF8, 0, (const WCHAR *)text, -1, line + 2, n, NULL, NULL);
    else memcpy(line + 2, text, n);
    int len = 2 + n - 1;
    for (int i = 2; i < len; i++) if (line[i] == '\r' || line[i] == '\n') line[i] = ' ';
    line[len] = '\n';
    line[len + 1] = 0;
    return line;
}

/* ---- the plugin's exports ---------------------------------------------------- */

__declspec(dllexport) void __stdcall Initialize(void)
{
    ensureStarted();
    logLine("# Initialize");
}

__declspec(dllexport) void __stdcall DestroySpeech(void)
{
    ensureStarted();
    logLine("# DestroySpeech");
}

__declspec(dllexport) void __stdcall AddToSpeechQueue(const void *text)
{
    ensureStarted();
    if (!text) return;
    char *line = lineFor(text);
    if (!line) return;
    size_t len = strlen(line);
    line[len - 1] = 0; logLine(line); line[len - 1] = '\n';
    enqueue(line, 0);
}

__declspec(dllexport) void __stdcall StopSpeech(void)
{
    ensureStarted();
    logLine("X");
    char *line = _strdup("X\n");
    if (line) enqueue(line, 1);
}

__declspec(dllexport) BOOL __stdcall IsVoiceSpeaking(void)
{
    ensureStarted();
    return FALSE;
}

__declspec(dllexport) BOOL __stdcall IsScreenReaderActive(void)
{
    ensureStarted();
    logLine("# IsScreenReaderActive -> yes");
    return TRUE;
}

__declspec(dllexport) void __stdcall SetRate(int rate)
{
    ensureStarted();
    char msg[48];
    snprintf(msg, sizeof msg, "# SetRate %d (ignored)", rate);
    logLine(msg);
}

__declspec(dllexport) void __stdcall SetVolume(int volume)
{
    ensureStarted();
    char msg[48];
    snprintf(msg, sizeof msg, "# SetVolume %d (ignored)", volume);
    logLine(msg);
}

__declspec(dllexport) void __stdcall SetCultureInfo(const void *culture)
{
    ensureStarted();
    (void)culture;
    logLine("# SetCultureInfo (ignored)");
}

/* The older SAPI-based generation of the plugin (Rhythm Doctor's, 17 KB) exports this
   instead of IsScreenReaderActive/SetCultureInfo; a missing export would be a managed
   EntryPointNotFoundException, so it is here as a no-op. */
__declspec(dllexport) void __stdcall SetVoiceSAPI(const void *voice)
{
    ensureStarted();
    (void)voice;
    logLine("# SetVoiceSAPI (ignored)");
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
