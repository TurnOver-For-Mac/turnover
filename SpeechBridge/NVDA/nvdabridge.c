/*
 * nvdaControllerClient.dll — an NVDA stand-in for games that ship NVDA's
 * controller client (Bits & Bops, and everything built on Tolk or UAP).
 *
 * A game asks nvdaController_testIfRunning; 0 means "NVDA is here", and from
 * then on it sends its speech to nvdaController_speakText and its stops to
 * nvdaController_cancelSpeech. Real NVDA answers those over RPC; this DLL
 * answers them the way SAAPI64.dll answers Tolk's System Access calls:
 *   1. every call is appended to nvdaControllerClient.log beside the DLL, and
 *   2. speech is forwarded to 127.0.0.1:52134 as the SpeechBridge line protocol
 *        S <utf-8 text>\n   speak
 *        X\n                stop, drop anything queued
 *      for SpeechBridge/listener to speak through VoiceOver or the system voice.
 *
 * It goes in place of the game's own copy (keep the original as .orig; a Steam
 * "verify integrity" puts the original back). A 32-bit game needs the 32-bit
 * build. The four exports are NVDA's, with NVDA's calling convention and
 * return type (error_status_t, 0 on success).
 *
 *   x86_64-w64-mingw32-gcc -shared -O2 -Wall -o nvdaControllerClient64.dll nvdabridge.c nvdabridge.def -lws2_32 -static-libgcc
 *   i686-w64-mingw32-gcc   -shared -O2 -Wall -o nvdaControllerClient32.dll nvdabridge.c nvdabridge.def -lws2_32 -static-libgcc
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
    wcscat(g_logPath, L"nvdaControllerClient.log");
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
    logLine("# SpeechBridge NVDA stand-in loaded");
    g_worker = CreateThread(NULL, 0, worker, NULL, 0, NULL);
}

static char *lineFor(const WCHAR *text)
{
    int n = WideCharToMultiByte(CP_UTF8, 0, text, -1, NULL, 0, NULL, NULL);
    if (n <= 0) return NULL;
    char *line = (char *)malloc(2 + n + 1);
    if (!line) return NULL;
    line[0] = 'S'; line[1] = ' ';
    WideCharToMultiByte(CP_UTF8, 0, text, -1, line + 2, n, NULL, NULL);
    int len = 2 + n - 1;
    for (int i = 2; i < len; i++) if (line[i] == '\r' || line[i] == '\n') line[i] = ' ';
    line[len] = '\n';
    line[len + 1] = 0;
    return line;
}

/* ---- NVDA's controller client API ------------------------------------------ */

typedef unsigned long error_status_t;

__declspec(dllexport) error_status_t __stdcall nvdaController_testIfRunning(void)
{
    ensureStarted();
    return 0;                          /* 0: NVDA is running */
}

__declspec(dllexport) error_status_t __stdcall nvdaController_speakText(const wchar_t *text)
{
    ensureStarted();
    if (!text) return 1;
    char *line = lineFor(text);
    if (!line) return 1;
    size_t len = strlen(line);
    line[len - 1] = 0; logLine(line); line[len - 1] = '\n';
    enqueue(line, 0);
    return 0;
}

__declspec(dllexport) error_status_t __stdcall nvdaController_cancelSpeech(void)
{
    ensureStarted();
    logLine("X");
    char *line = _strdup("X\n");
    if (line) enqueue(line, 1);
    return 0;
}

__declspec(dllexport) error_status_t __stdcall nvdaController_brailleMessage(const wchar_t *text)
{
    ensureStarted();
    (void)text;
    return 0;
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
