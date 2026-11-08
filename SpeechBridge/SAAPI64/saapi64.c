/*
 * SAAPI64.dll — a System Access screen-reader stand-in for games that speak
 * through Tolk (Diablo IV's "third-party screen reader" mode among them).
 *
 * Tolk's System Access driver loads SAAPI64.dll from the game's folder and calls
 * four exports: SA_IsRunning, SA_SayW, SA_StopAudio, SA_BrlShowTextW. This DLL
 * answers them by
 *   1. appending every call to SAAPI64.log beside the DLL (proof of life, no
 *      listener needed), and
 *   2. forwarding speech over TCP to 127.0.0.1:52134 as a line protocol:
 *        S <utf-8 text>\n   speak this
 *        X\n                stop speaking, drop anything queued
 *      A Mac process (SpeechBridge/listener) reads those lines and speaks them
 *      through VoiceOver or the system voice.
 *
 * Nothing here blocks the game's UI thread: calls are queued and a worker thread
 * owns the socket. Winsock runs on the host's loopback under Wine, so the
 * listener is an ordinary Mac process.
 *
 * Build on a Mac (brew install mingw-w64) or Linux (apt install mingw-w64):
 *   x86_64-w64-mingw32-gcc -shared -O2 -Wall -o SAAPI64.dll saapi64.c saapi64.def -lws2_32
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
static HANDLE g_wake;            /* auto-reset event: something queued */
static HANDLE g_worker;
static volatile LONG g_started;

typedef struct Item {
    struct Item *next;
    char *line;                  /* including trailing \n */
    int cancel;                  /* X line: also flushes queued S lines */
} Item;

static Item *g_head, *g_tail;

/* ---- log file (never load-bearing, never fatal) ---------------------------- */

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
    wcscat(g_logPath, L"SAAPI64.log");
}

/* ---- queue ---------------------------------------------------------------- */

static void enqueue(char *line, int cancel)
{
    Item *it = (Item *)malloc(sizeof *it);
    if (!it) { free(line); return; }
    it->next = NULL;
    it->line = line;
    it->cancel = cancel;

    EnterCriticalSection(&g_lock);
    if (cancel) {
        /* A stop makes everything still waiting to be spoken stale. */
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

/* ---- worker: owns the socket, reconnects, never blocks the caller --------- */

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
    logLine("# SpeechBridge SAAPI64 loaded");
    g_worker = CreateThread(NULL, 0, worker, NULL, 0, NULL);
}

/* ---- text ------------------------------------------------------------------ */

/* UTF-16 → UTF-8 with the line protocol's prefix, newlines folded to spaces. */
static char *lineFor(const WCHAR *text)
{
    int n = WideCharToMultiByte(CP_UTF8, 0, text, -1, NULL, 0, NULL, NULL);
    if (n <= 0) return NULL;
    char *line = (char *)malloc(2 + n + 1);
    if (!line) return NULL;
    line[0] = 'S'; line[1] = ' ';
    WideCharToMultiByte(CP_UTF8, 0, text, -1, line + 2, n, NULL, NULL);
    int len = 2 + n - 1;               /* drop the NUL */
    for (int i = 2; i < len; i++) if (line[i] == '\r' || line[i] == '\n') line[i] = ' ';
    line[len] = '\n';
    line[len + 1] = 0;
    return line;
}

/* ---- the four exports Tolk asks for ---------------------------------------- */

__declspec(dllexport) BOOL WINAPI SA_IsRunning(void)
{
    ensureStarted();
    return TRUE;
}

__declspec(dllexport) BOOL WINAPI SA_SayW(const WCHAR *text)
{
    ensureStarted();
    if (!text) return FALSE;
    char *line = lineFor(text);
    if (!line) return FALSE;
    /* log without the trailing newline */
    size_t len = strlen(line);
    line[len - 1] = 0; logLine(line); line[len - 1] = '\n';
    enqueue(line, 0);
    return TRUE;
}

__declspec(dllexport) BOOL WINAPI SA_StopAudio(void)
{
    ensureStarted();
    logLine("X");
    char *line = _strdup("X\n");
    if (line) enqueue(line, 1);
    return TRUE;
}

__declspec(dllexport) BOOL WINAPI SA_BrlShowTextW(const WCHAR *text)
{
    ensureStarted();
    (void)text;                        /* no braille display on this side */
    return TRUE;
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
