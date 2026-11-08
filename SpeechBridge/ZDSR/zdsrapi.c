/* ZDSRAPI stand-in: the client library of the ZDSR screen reader, as programs built on the
 * Prism speech library (Fallout 4 Access, for one) call it. Under Wine the screen-reader
 * routes Prism prefers are out of reach — NVDA is spoken to over RPC with no DLL to replace,
 * and SAPI is probed on a thread without COM — so ZDSR is the door that opens: Prism looks
 * for the ZDSR registry key (older builds) or a ZDSR process (newer), then calls this API.
 * Speech goes to the SpeechBridge listener on 127.0.0.1:52134 as "S <text>", "X" to stop.
 *
 *   InitTTS(type, channel, keyInterrupt)  -> 0 ready
 *   Speak(text, interrupt)                -> 0 accepted
 *   GetSpeakState()                       -> 3 speaking, 4 idle   (1/2 not available)
 *   StopSpeak()
 *   Braille(text, flash)                  -> 0
 * Log: C:\SpeechBridge\ZDSRAPI.log
 */
#include <winsock2.h>
#include <windows.h>
#include <stdio.h>

static CRITICAL_SECTION cs;
static SOCKET sock = INVALID_SOCKET;
static ULONGLONG speakingUntil;

static void logLine(const char *fmt, const wchar_t *w) {
    FILE *f = fopen("C:\\SpeechBridge\\ZDSRAPI.log", "a");
    if (!f) return;
    SYSTEMTIME t; GetLocalTime(&t);
    fprintf(f, "%02d:%02d:%02d.%03d ", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
    if (w) { char buf[512]; WideCharToMultiByte(CP_UTF8, 0, w, -1, buf, sizeof buf, NULL, NULL); buf[sizeof buf - 1] = 0; fprintf(f, fmt, buf); }
    else fputs(fmt, f);
    fputc('\n', f); fclose(f);
}

static BOOL connectListener(void) {
    if (sock != INVALID_SOCKET) return TRUE;
    WSADATA wsa; if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return FALSE;
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) return FALSE;
    struct sockaddr_in a; memset(&a, 0, sizeof a); a.sin_family = AF_INET; a.sin_port = htons(52134); a.sin_addr.s_addr = htonl(0x7F000001);
    if (connect(s, (struct sockaddr *)&a, sizeof a) != 0) { closesocket(s); return FALSE; }
    BOOL nd = TRUE; setsockopt(s, IPPROTO_TCP, TCP_NODELAY, (const char *)&nd, sizeof nd);
    sock = s; return TRUE;
}

static void sendLine(const char *line) {   /* caller holds cs */
    if (!connectListener()) return;
    int n = (int)strlen(line);
    if (send(sock, line, n, 0) != n) { closesocket(sock); sock = INVALID_SOCKET; if (connectListener()) send(sock, line, n, 0); }
}

__declspec(dllexport) int WINAPI InitTTS(int type, const WCHAR *channelName, BOOL bKeyDownInterrupt) {
    (void)type; (void)channelName; (void)bKeyDownInterrupt;
    logLine("# InitTTS", NULL);
    EnterCriticalSection(&cs); connectListener(); LeaveCriticalSection(&cs);
    return 0;
}

__declspec(dllexport) int WINAPI Speak(const WCHAR *text, BOOL bInterrupt) {
    if (!text) return 0;
    int len = WideCharToMultiByte(CP_UTF8, 0, text, -1, NULL, 0, NULL, NULL);
    char *buf = malloc(len + 4); if (!buf) return 1;
    buf[0] = 'S'; buf[1] = ' ';
    WideCharToMultiByte(CP_UTF8, 0, text, -1, buf + 2, len, NULL, NULL);
    for (char *p = buf + 2; *p; p++) if (*p == '\n' || *p == '\r') *p = ' ';
    strcat(buf, "\n");
    EnterCriticalSection(&cs);
    if (bInterrupt) sendLine("X\n");
    sendLine(buf);
    speakingUntil = GetTickCount64() + 60 * (ULONGLONG)(len > 1 ? len : 1) + 300;   /* a rough guess at how long it takes to say */
    LeaveCriticalSection(&cs);
    logLine("S %s", text);
    free(buf);
    return 0;
}

__declspec(dllexport) int WINAPI GetSpeakState(void) {
    return GetTickCount64() < speakingUntil ? 3 : 4;
}

__declspec(dllexport) void WINAPI StopSpeak(void) {
    EnterCriticalSection(&cs); sendLine("X\n"); speakingUntil = 0; LeaveCriticalSection(&cs);
}

__declspec(dllexport) int WINAPI Braille(const WCHAR *text, BOOL bFlashMessage) { (void)text; (void)bFlashMessage; return 0; }

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) { InitializeCriticalSection(&cs); DisableThreadLibraryCalls(inst); logLine("# SpeechBridge ZDSRAPI loaded", NULL); }
    return TRUE;
}
