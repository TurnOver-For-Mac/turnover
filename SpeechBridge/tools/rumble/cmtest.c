/* cmtest: repeats the exact device-manager chain SDL's hidapi uses on Windows to work out a
 * HID device's bus (USB / Bluetooth), and prints where it gets to under Wine. */
#include <windows.h>
#include <setupapi.h>
#include <hidsdi.h>
#include <cfgmgr32.h>
#include <devpropdef.h>
#include <stdio.h>

typedef CONFIGRET (WINAPI *CMGDIP)(LPCWSTR, const DEVPROPKEY*, DEVPROPTYPE*, PBYTE, PULONG, ULONG);
typedef CONFIGRET (WINAPI *CMGDNP)(DEVINST, const DEVPROPKEY*, DEVPROPTYPE*, PBYTE, PULONG, ULONG);
typedef CONFIGRET (WINAPI *CMLDN)(PDEVINST, DEVINSTID_W, ULONG);
typedef CONFIGRET (WINAPI *CMGP)(PDEVINST, DEVINST, ULONG);
typedef CONFIGRET (WINAPI *CMGDIDW)(DEVINST, PWSTR, ULONG, ULONG);

static const DEVPROPKEY KEY_InstanceId = {{0x78c34fc8,0x104a,0x4aca,{0x9e,0xa4,0x52,0x4d,0x52,0x99,0x6e,0x57}}, 256};
static const DEVPROPKEY KEY_CompatibleIds = {{0xa45c254e,0xdf1c,0x4efd,{0x80,0x20,0x67,0xd1,0x46,0xa8,0x50,0xe0}}, 4};
static const DEVPROPKEY KEY_HardwareIds = {{0xa45c254e,0xdf1c,0x4efd,{0x80,0x20,0x67,0xd1,0x46,0xa8,0x50,0xe0}}, 3};

static void print_list(const wchar_t *list) { for (const wchar_t *p = list; *p; p += wcslen(p) + 1) printf("    '%ls'\n", p); }

int main(void) {
    HMODULE cm = LoadLibraryA("cfgmgr32.dll");
    CMGDIP GetIfProp = (CMGDIP)GetProcAddress(cm, "CM_Get_Device_Interface_PropertyW");
    CMGDNP GetNodeProp = (CMGDNP)GetProcAddress(cm, "CM_Get_DevNode_PropertyW");
    CMLDN Locate = (CMLDN)GetProcAddress(cm, "CM_Locate_DevNodeW");
    CMGP GetParent = (CMGP)GetProcAddress(cm, "CM_Get_Parent");
    CMGDIDW GetId = (CMGDIDW)GetProcAddress(cm, "CM_Get_Device_IDW");
    { WCHAR mp[MAX_PATH]; GetModuleFileNameW(cm, mp, MAX_PATH); printf("cfgmgr32 module: %ls\n", mp); }
    printf("cfgmgr32: IfProp %p NodeProp %p Locate %p Parent %p GetId %p\n", GetIfProp, GetNodeProp, Locate, GetParent, GetId);

    GUID guid; HidD_GetHidGuid(&guid);
    HDEVINFO set = SetupDiGetClassDevsW(&guid, NULL, NULL, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    SP_DEVICE_INTERFACE_DATA ifd = { sizeof ifd };
    for (DWORD i = 0; SetupDiEnumDeviceInterfaces(set, NULL, &guid, i, &ifd); i++) {
        DWORD need = 0; SetupDiGetDeviceInterfaceDetailW(set, &ifd, NULL, 0, &need, NULL);
        PSP_DEVICE_INTERFACE_DETAIL_DATA_W det = malloc(need); det->cbSize = sizeof *det;
        if (!SetupDiGetDeviceInterfaceDetailW(set, &ifd, det, need, NULL, NULL)) { free(det); continue; }
        if (!wcsstr(det->DevicePath, L"vid_054c")) { free(det); continue; }
        printf("\ninterface: %ls\n", det->DevicePath);
        wchar_t id[512]; ULONG len = sizeof id; DEVPROPTYPE type = 0;
        CONFIGRET cr = GetIfProp ? GetIfProp(det->DevicePath, &KEY_InstanceId, &type, (PBYTE)id, &len, 0) : CR_FAILURE;
        printf("  InstanceId via interface property: cr=%lu type=%#lx '%ls'\n", cr, type, cr ? L"" : id);
        if (cr) { free(det); continue; }
        DEVINST node = 0; cr = Locate(&node, id, CM_LOCATE_DEVNODE_NORMAL);
        printf("  CM_Locate_DevNodeW: cr=%lu node=%#lx\n", cr, node);
        if (cr) { free(det); continue; }
        wchar_t buf[2048]; len = sizeof buf; type = 0;
        cr = GetNodeProp(node, &KEY_CompatibleIds, &type, (PBYTE)buf, &len, 0);
        printf("  child CompatibleIds: cr=%lu type=%#lx\n", cr, type); if (!cr) print_list(buf);
        DEVINST parent = 0; cr = GetParent(&parent, node, 0);
        printf("  CM_Get_Parent: cr=%lu parent=%#lx\n", cr, parent);
        if (cr) { free(det); continue; }
        if (GetId && GetId(parent, buf, 1024, 0) == CR_SUCCESS) printf("  parent id: '%ls'\n", buf);
        len = sizeof buf; type = 0; cr = GetNodeProp(parent, &KEY_CompatibleIds, &type, (PBYTE)buf, &len, 0);
        printf("  parent CompatibleIds: cr=%lu type=%#lx\n", cr, type); if (!cr) print_list(buf);
        len = sizeof buf; type = 0; cr = GetNodeProp(parent, &KEY_HardwareIds, &type, (PBYTE)buf, &len, 0);
        printf("  parent HardwareIds: cr=%lu type=%#lx\n", cr, type); if (!cr) print_list(buf);
        free(det);
    }
    SetupDiDestroyDeviceInfoList(set);
    return 0;
}
