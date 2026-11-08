/* Loads SAAPI64.dll the way Tolk does and calls its four exports.
 * Build: x86_64-w64-mingw32-gcc -O2 -o satest.exe satest.c
 * Run under Wine beside SAAPI64.dll with a listener up on 52134. */
#include <windows.h>
#include <stdio.h>
typedef BOOL (WINAPI *fn_v)(void);
typedef BOOL (WINAPI *fn_w)(const WCHAR *);
int main(void)
{
    HMODULE m = LoadLibraryW(L"SAAPI64.dll");
    if (!m) { printf("LoadLibrary failed: %lu\n", GetLastError()); return 1; }
    fn_v isRunning = (fn_v)GetProcAddress(m, "SA_IsRunning");
    fn_w sayW = (fn_w)GetProcAddress(m, "SA_SayW");
    fn_v stop = (fn_v)GetProcAddress(m, "SA_StopAudio");
    fn_w brl = (fn_w)GetProcAddress(m, "SA_BrlShowTextW");
    printf("exports: %p %p %p %p\n", (void*)isRunning, (void*)sayW, (void*)stop, (void*)brl);
    if (!isRunning || !sayW || !stop || !brl) return 2;
    printf("SA_IsRunning -> %d\n", isRunning());
    printf("SA_SayW -> %d\n", sayW(L"Hello from Tolk. Line one."));
    Sleep(300);
    printf("SA_StopAudio -> %d\n", stop());
    printf("SA_SayW -> %d\n", sayW(L"Line two, with a é and a\r\nnewline folded."));
    printf("SA_BrlShowTextW -> %d\n", brl(L"braille"));
    Sleep(1500);
    return 0;
}
