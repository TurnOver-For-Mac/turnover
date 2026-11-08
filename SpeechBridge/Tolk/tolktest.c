/*
 * tolktest.exe — drives a game's Tolk.dll the way the game would and logs what it
 * finds, to tolktest.log beside itself. Run it from the game's folder (so Tolk.dll
 * and the driver DLLs beside it are the ones loaded).
 *
 *   x86_64-w64-mingw32-gcc -O2 -Wall -o tolktest.exe tolktest.c -static-libgcc
 */
#include <windows.h>
#include <stdio.h>
#include <stdarg.h>

static FILE *g_log;
static void logf_(const char *fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    vfprintf(g_log, fmt, ap); fputc('\n', g_log); fflush(g_log);
    va_end(ap);
}

typedef void (__cdecl *pTolk_Load)(void);
typedef BOOL (__cdecl *pTolk_IsLoaded)(void);
typedef void (__cdecl *pTolk_Unload)(void);
typedef void (__cdecl *pTolk_TrySAPI)(BOOL);
typedef const wchar_t *(__cdecl *pTolk_DetectScreenReader)(void);
typedef BOOL (__cdecl *pTolk_HasSpeech)(void);
typedef BOOL (__cdecl *pTolk_Output)(const wchar_t *, BOOL);
typedef BOOL (__cdecl *pTolk_Speak)(const wchar_t *, BOOL);

int main(int argc, char **argv)
{
    (void)argc; (void)argv;
    char path[MAX_PATH]; GetModuleFileNameA(NULL, path, MAX_PATH);
    char *slash = strrchr(path, '\\'); if (slash) strcpy(slash + 1, "tolktest.log");
    g_log = fopen(path, "w"); if (!g_log) return 1;
    char cwd[MAX_PATH]; GetCurrentDirectoryA(MAX_PATH, cwd); logf_("cwd: %s", cwd);

    HMODULE tolk = LoadLibraryA("Tolk.dll");
    logf_("LoadLibrary(Tolk.dll): %p (error %lu)", (void *)tolk, GetLastError());
    if (!tolk) return 2;
    HMODULE sa = LoadLibraryA("SAAPI64.dll");
    logf_("LoadLibrary(SAAPI64.dll) by hand: %p (error %lu)", (void *)sa, GetLastError());
    HMODULE nv = LoadLibraryA("nvdaControllerClient64.dll");
    logf_("LoadLibrary(nvdaControllerClient64.dll) by hand: %p (error %lu)", (void *)nv, GetLastError());

    pTolk_Load Load = (pTolk_Load)GetProcAddress(tolk, "Tolk_Load");
    pTolk_IsLoaded IsLoaded = (pTolk_IsLoaded)GetProcAddress(tolk, "Tolk_IsLoaded");
    pTolk_Unload Unload = (pTolk_Unload)GetProcAddress(tolk, "Tolk_Unload");
    pTolk_TrySAPI TrySAPI = (pTolk_TrySAPI)GetProcAddress(tolk, "Tolk_TrySAPI");
    pTolk_DetectScreenReader Detect = (pTolk_DetectScreenReader)GetProcAddress(tolk, "Tolk_DetectScreenReader");
    pTolk_HasSpeech HasSpeech = (pTolk_HasSpeech)GetProcAddress(tolk, "Tolk_HasSpeech");
    pTolk_Output Output = (pTolk_Output)GetProcAddress(tolk, "Tolk_Output");
    pTolk_Speak Speak = (pTolk_Speak)GetProcAddress(tolk, "Tolk_Speak");
    logf_("exports: Load=%p IsLoaded=%p Detect=%p HasSpeech=%p Output=%p Speak=%p TrySAPI=%p",
          (void*)Load,(void*)IsLoaded,(void*)Detect,(void*)HasSpeech,(void*)Output,(void*)Speak,(void*)TrySAPI);

    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (TrySAPI) TrySAPI(TRUE);
    Load();
    logf_("Tolk_Load done; IsLoaded=%d", IsLoaded ? IsLoaded() : -1);
    const wchar_t *name = Detect ? Detect() : NULL;
    logf_("Tolk_DetectScreenReader: %ls", name ? name : L"(none)");
    logf_("Tolk_HasSpeech: %d", HasSpeech ? HasSpeech() : -1);
    BOOL ok = Output ? Output(L"Hello from the Tolk test in the Diablo folder", TRUE) : FALSE;
    logf_("Tolk_Output: %d", ok);
    Sleep(1500);
    ok = Speak ? Speak(L"Second line through Tolk Speak", TRUE) : FALSE;
    logf_("Tolk_Speak: %d", ok);
    Sleep(1500);
    Unload();
    logf_("done");
    fclose(g_log);
    return 0;
}
