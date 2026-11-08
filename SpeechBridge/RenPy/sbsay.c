/*
 * sbsay.exe — "say this" for Ren'Py games under Wine.
 *
 * Ren'Py's self-voicing on Windows runs `wscript say.vbs <text> <voice>`, and that
 * script walks SAPI's voice list (GetVoices), which hangs under Wine's script host —
 * measured 28 Sep 2026 — so a Ren'Py game runs and says nothing. Ren'Py checks the
 * environment first: with RENPY_TTS_COMMAND set it runs that program with the text as
 * its one argument, and terminates it when the next line comes or when it wants
 * silence. This program sends the SpeechBridge listener an X (drop what is queued)
 * and then "S <text>", and exits. Set in the bottle's registry, HKCU\Environment:
 *     RENPY_TTS_COMMAND = C:\SpeechBridge\sbsay.exe
 *
 *   x86_64-w64-mingw32-gcc -O2 -Wall -mwindows -o sbsay.exe sbsay.c -lws2_32 -lshell32 -static-libgcc
 */
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <shellapi.h>
#include <string.h>
#include <stdlib.h>

#define BRIDGE_PORT 52134

static int sendAll(SOCKET s, const char *p, int n)
{
    while (n > 0) { int k = send(s, p, n, 0); if (k <= 0) return 0; p += k; n -= k; }
    return 1;
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmdline, int show)
{
    (void)inst; (void)prev; (void)cmdline; (void)show;
    int argc = 0;
    WCHAR **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv || argc < 2) return 0;

    /* Join every argument after the program name with spaces. */
    size_t total = 0;
    for (int i = 1; i < argc; i++) total += wcslen(argv[i]) + 1;
    WCHAR *text = (WCHAR *)calloc(total + 1, sizeof(WCHAR));
    if (!text) return 0;
    for (int i = 1; i < argc; i++) { if (i > 1) wcscat(text, L" "); wcscat(text, argv[i]); }
    for (WCHAR *p = text; *p; p++) if (*p == L'\r' || *p == L'\n') *p = L' ';

    int n = WideCharToMultiByte(CP_UTF8, 0, text, -1, NULL, 0, NULL, NULL);
    if (n <= 1) return 0;
    char *line = (char *)malloc(4 + n + 1);
    if (!line) return 0;
    memcpy(line, "X\nS ", 4);
    WideCharToMultiByte(CP_UTF8, 0, text, -1, line + 4, n, NULL, NULL);
    int len = 4 + n - 1;
    line[len] = '\n'; line[len + 1] = 0;

    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s != INVALID_SOCKET) {
        struct sockaddr_in a; memset(&a, 0, sizeof a);
        a.sin_family = AF_INET; a.sin_port = htons(BRIDGE_PORT); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (connect(s, (struct sockaddr *)&a, sizeof a) == 0) sendAll(s, line, len + 1);
        closesocket(s);
    }
    WSACleanup();
    return 0;
}
