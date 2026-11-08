/* cfgmgr32.dll shim for Steam under Wine: tells SDL's hidapi which bus a controller is on.
 *
 * SDL (inside Steam) works out whether a HID device is USB or Bluetooth by asking the device
 * manager for the device's *parent* and reading the parent's compatible ids ("USB..." or
 * "BTHENUM..."). Wine's CM_Get_Parent answers CR_NO_SUCH_DEVNODE, so the bus stays unknown,
 * SDL treats every controller as wired, and a DualSense on Bluetooth is sent USB-format
 * output reports (id 0x02) that it ignores: no rumble, no lights.
 *
 * Placed beside steam.exe as cfgmgr32.dll this DLL is loaded ahead of Wine's own. Every
 * export passes straight through to C:\windows\system32\cfgmgr32.dll (thunks.h, generated
 * from Wine's export list) except:
 *   CM_Get_Parent            when Wine has no answer, finds winebus's own device for the HID
 *                            child in the registry (Enum\USB\... or Enum\BTHENUM\...) and hands
 *                            back a stand-in parent node that remembers the bus
 *   CM_Get_DevNode_PropertyW answers DEVPKEY_Device_CompatibleIds for a stand-in parent with
 *                            "USB\Class_03" or "BTHENUM\Bluetooth"; everything else passes through
 * Log: C:\SpeechBridge\bustype.log
 */
#include <windows.h>
#include <cfgmgr32.h>
#include <devpropdef.h>
#include <stdio.h>
#include <wchar.h>

static HMODULE g_real;
static HINSTANCE g_self;
static CRITICAL_SECTION g_cs;

static void shimlog(const char *fmt, ...) {
    FILE *f = fopen("C:\\SpeechBridge\\bustype.log", "a");
    if (!f) return;
    SYSTEMTIME t; GetLocalTime(&t);
    fprintf(f, "[%02d:%02d:%02d.%03d pid %lu] ", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds, GetCurrentProcessId());
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fputc('\n', f); fclose(f);
}

FARPROC shim_real(const char *name) {
    if (!g_real) {
        WCHAR path[MAX_PATH]; GetSystemDirectoryW(path, MAX_PATH); wcscat(path, L"\\cfgmgr32.dll");
        HMODULE m = LoadLibraryW(path);
        if (m == g_self) {
            /* the override that put this shim in front applies to the name, so ask for Wine's
               own copy by the path of the file it is built from */
            FreeLibrary(m); m = NULL;
            WCHAR wine[MAX_PATH] = L"";
            if (GetEnvironmentVariableW(L"WINEBUILDDIR", wine, MAX_PATH) == 0)
                GetEnvironmentVariableW(L"WINEDLLDIR0", wine, MAX_PATH);
            if (wine[0]) { wcscat(wine, L"\\cfgmgr32.dll"); m = LoadLibraryW(wine); }
            if (m == g_self) { FreeLibrary(m); m = NULL; }
            shimlog("system path resolved to this shim; Wine's own copy via %ls: %s", wine, m ? "loaded" : "NOT loaded");
        }
        g_real = m;
        shimlog("Wine's cfgmgr32 %s (%p)", m ? "loaded" : "NOT FOUND — every call fails", m);
    }
    return g_real ? GetProcAddress(g_real, name) : NULL;
}



/* stand-in parents: the low 16 bits are the child's node, the upper bits mark ours */
#define STANDIN_MARK 0x5A5A0000u
#define MAX_STANDIN 32
static struct { DEVINST child; const WCHAR *bus; } g_standin[MAX_STANDIN];
static int g_nstandin;

static const DEVPROPKEY KEY_CompatibleIds = {{0xa45c254e,0xdf1c,0x4efd,{0x80,0x20,0x67,0xd1,0x46,0xa8,0x50,0xe0}}, 4};

static BOOL enum_key_exists(const WCHAR *bus, const WCHAR *rest) {
    WCHAR key[600]; _snwprintf(key, 600, L"System\\CurrentControlSet\\Enum\\%s\\%s", bus, rest);
    HKEY h; if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, key, 0, KEY_READ, &h) != ERROR_SUCCESS) return FALSE;
    RegCloseKey(h); return TRUE;
}

typedef CONFIGRET (WINAPI *fn_parent)(PDEVINST, DEVINST, ULONG);
typedef CONFIGRET (WINAPI *fn_parent_ex)(PDEVINST, DEVINST, ULONG, HMACHINE);
typedef CONFIGRET (WINAPI *fn_devid)(DEVINST, PWSTR, ULONG, ULONG);
typedef CONFIGRET (WINAPI *fn_nodeprop)(DEVINST, const DEVPROPKEY*, DEVPROPTYPE*, PBYTE, PULONG, ULONG);
typedef CONFIGRET (WINAPI *fn_nodeprop_ex)(DEVINST, const DEVPROPKEY*, DEVPROPTYPE*, PBYTE, PULONG, ULONG, HMACHINE);

static CONFIGRET standin_parent(PDEVINST out, DEVINST child, CONFIGRET wine_answer) {
    WCHAR id[MAX_DEVICE_ID_LEN] = L"";
    fn_devid getid = (fn_devid)shim_real("CM_Get_Device_IDW");
    if (!getid || getid(child, id, MAX_DEVICE_ID_LEN, 0) != CR_SUCCESS) return wine_answer;
    if (_wcsnicmp(id, L"HID\\", 4)) return wine_answer;
    const WCHAR *rest = id + 4, *bus = NULL;
    if (enum_key_exists(L"USB", rest)) bus = L"USB";              /* a wired pad has a USB key with this exact id */
    else if (enum_key_exists(L"BTHENUM", rest)) bus = L"BTHENUM";
    if (!bus) { shimlog("no winebus device for %ls; leaving Wine's answer %lu", id, wine_answer); return wine_answer; }
    EnterCriticalSection(&g_cs);
    int i; for (i = 0; i < g_nstandin && g_standin[i].child != child; i++);
    if (i == g_nstandin && g_nstandin < MAX_STANDIN) g_nstandin++;
    if (i < MAX_STANDIN) { g_standin[i].child = child; g_standin[i].bus = bus; }
    LeaveCriticalSection(&g_cs);
    if (i >= MAX_STANDIN) return wine_answer;
    *out = STANDIN_MARK | (DEVINST)(i << 8) | (child & 0xFF);
    shimlog("parent of %ls -> %s (stand-in %#lx)", id, wcscmp(bus, L"USB") == 0 ? "USB" : "Bluetooth", (unsigned long)*out);
    return CR_SUCCESS;
}

static const WCHAR *standin_bus(DEVINST node) {
    if ((node & 0xFFFF0000u) != STANDIN_MARK) return NULL;
    int i = (node >> 8) & 0xFF;
    return i < g_nstandin ? g_standin[i].bus : NULL;
}

CONFIGRET WINAPI CM_Get_Parent(PDEVINST out, DEVINST child, ULONG flags) {
    fn_parent f = (fn_parent)shim_real("CM_Get_Parent");
    if (standin_bus(child)) return CR_NO_SUCH_DEVNODE;        /* stand-ins have no parent of their own */
    CONFIGRET cr = f ? f(out, child, flags) : CR_NO_SUCH_DEVNODE;
    return cr == CR_SUCCESS ? cr : standin_parent(out, child, cr);
}

CONFIGRET WINAPI CM_Get_Parent_Ex(PDEVINST out, DEVINST child, ULONG flags, HMACHINE machine) {
    fn_parent_ex f = (fn_parent_ex)shim_real("CM_Get_Parent_Ex");
    if (standin_bus(child)) return CR_NO_SUCH_DEVNODE;
    CONFIGRET cr = f ? f(out, child, flags, machine) : CR_NO_SUCH_DEVNODE;
    return cr == CR_SUCCESS ? cr : standin_parent(out, child, cr);
}

static CONFIGRET standin_property(const WCHAR *bus, const DEVPROPKEY *key, DEVPROPTYPE *type, PBYTE buf, PULONG len) {
    if (memcmp(key, &KEY_CompatibleIds, sizeof *key)) return CR_NO_SUCH_VALUE;
    const WCHAR *list = wcscmp(bus, L"USB") == 0 ? L"USB\\Class_03\0" : L"BTHENUM\\Bluetooth\0";
    ULONG need = (ULONG)((wcslen(list) + 2) * sizeof(WCHAR));
    if (type) *type = DEVPROP_TYPE_STRING_LIST;
    if (!buf || *len < need) { *len = need; return CR_BUFFER_SMALL; }
    memcpy(buf, list, need); *len = need;
    return CR_SUCCESS;
}

CONFIGRET WINAPI CM_Get_DevNode_PropertyW(DEVINST node, const DEVPROPKEY *key, DEVPROPTYPE *type, PBYTE buf, PULONG len, ULONG flags) {
    const WCHAR *bus = standin_bus(node);
    if (bus) return standin_property(bus, key, type, buf, len);
    fn_nodeprop f = (fn_nodeprop)shim_real("CM_Get_DevNode_PropertyW");
    return f ? f(node, key, type, buf, len, flags) : CR_CALL_NOT_IMPLEMENTED;
}

CONFIGRET WINAPI CM_Get_DevNode_Property_ExW(DEVINST node, const DEVPROPKEY *key, DEVPROPTYPE *type, PBYTE buf, PULONG len, ULONG flags, HMACHINE machine) {
    const WCHAR *bus = standin_bus(node);
    if (bus) return standin_property(bus, key, type, buf, len);
    fn_nodeprop_ex f = (fn_nodeprop_ex)shim_real("CM_Get_DevNode_Property_ExW");
    return f ? f(node, key, type, buf, len, flags, machine) : CR_CALL_NOT_IMPLEMENTED;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) { g_self = inst; InitializeCriticalSection(&g_cs); DisableThreadLibraryCalls(inst); shimlog("SpeechBridge bus-type shim loaded"); }
    return TRUE;
}
