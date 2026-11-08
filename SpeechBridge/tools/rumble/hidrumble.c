/* hidrumble: opens the DualSense through Windows' HID API (as Steam does) and rumbles it.
 *   hidrumble usb          write a USB-format output report (id 0x02)
 *   hidrumble bt           write a Bluetooth-format report (id 0x31, CRC32) ourselves
 *   hidrumble feature-usb  read feature report 0x05 first (as SDL/Steam do), then write 0x02
 * Prints what the HID stack says about the device: report lengths, serial, product.
 */
#include <windows.h>
#include <setupapi.h>
#include <hidsdi.h>
#include <stdio.h>
#include <string.h>

static unsigned int crc32_step(unsigned int crc, const unsigned char *d, int n) {
    for (int i = 0; i < n; i++) { crc ^= d[i]; for (int k = 0; k < 8; k++) crc = (crc >> 1) ^ (0xEDB88320u & -(crc & 1)); }
    return crc;
}

static void fill_common(unsigned char *p) {       /* the 47-byte payload shared by 0x02 and 0x31 */
    p[0] = 0x03;        /* valid_flag0: compatible vibration + haptics select */
    p[1] = 0x00;        /* valid_flag1 */
    p[2] = 0xFF;        /* right motor */
    p[3] = 0xFF;        /* left motor */
    p[36] = 0x04;       /* valid_flag2: compatible vibration 2 (newer firmware) */
}

int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "usb";
    GUID guid; HidD_GetHidGuid(&guid);
    HDEVINFO set = SetupDiGetClassDevsA(&guid, NULL, NULL, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    SP_DEVICE_INTERFACE_DATA ifd = { sizeof ifd };
    HANDLE h = INVALID_HANDLE_VALUE; HIDP_CAPS caps = {0};
    for (DWORD i = 0; SetupDiEnumDeviceInterfaces(set, NULL, &guid, i, &ifd); i++) {
        DWORD need = 0; SetupDiGetDeviceInterfaceDetailA(set, &ifd, NULL, 0, &need, NULL);
        PSP_DEVICE_INTERFACE_DETAIL_DATA_A det = malloc(need); det->cbSize = sizeof *det;
        if (!SetupDiGetDeviceInterfaceDetailA(set, &ifd, det, need, NULL, NULL)) { free(det); continue; }
        HANDLE t = CreateFileA(det->DevicePath, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
        if (t == INVALID_HANDLE_VALUE) { printf("skip (open failed %lu): %s\n", GetLastError(), det->DevicePath); free(det); continue; }
        HIDD_ATTRIBUTES a = { sizeof a }; HidD_GetAttributes(t, &a);
        if (a.VendorID == 0x054C && a.ProductID == 0x0CE6) {
            printf("device: %s\n", det->DevicePath);
            wchar_t s[128] = L""; HidD_GetSerialNumberString(t, s, sizeof s); printf("serial: '%ls' (%d chars)\n", s, (int)wcslen(s));
            HidD_GetProductString(t, s, sizeof s); printf("product: '%ls'\n", s);
            PHIDP_PREPARSED_DATA pp; if (HidD_GetPreparsedData(t, &pp)) { HidP_GetCaps(pp, &caps); HidD_FreePreparsedData(pp); }
            printf("caps: input %u output %u feature %u bytes\n", caps.InputReportByteLength, caps.OutputReportByteLength, caps.FeatureReportByteLength);
            h = t; free(det); break;
        }
        CloseHandle(t); free(det);
    }
    SetupDiDestroyDeviceInfoList(set);
    if (h == INVALID_HANDLE_VALUE) { printf("no DualSense found\n"); return 1; }

    if (!strcmp(mode, "feature-usb")) {
        unsigned char f[128] = { 0x05 };
        BOOL ok = HidD_GetFeature(h, f, caps.FeatureReportByteLength ? caps.FeatureReportByteLength : 64);
        printf("feature 0x05 read: %s (err %lu) first bytes %02x %02x %02x %02x\n", ok ? "ok" : "FAILED", GetLastError(), f[0], f[1], f[2], f[3]);
        unsigned char m[128] = { 0x09 };
        ok = HidD_GetFeature(h, m, caps.FeatureReportByteLength ? caps.FeatureReportByteLength : 64);
        printf("feature 0x09 read: %s: %02x %02x:%02x:%02x:%02x:%02x:%02x\n", ok ? "ok" : "FAILED", m[0], m[6], m[5], m[4], m[3], m[2], m[1]);
    }
    unsigned int len = caps.OutputReportByteLength ? caps.OutputReportByteLength : 78;
    unsigned char *buf = calloc(len + 8, 1);
    for (int pass = 0; pass < 2; pass++) {              /* pass 0 rumbles, pass 1 stops */
        memset(buf, 0, len + 8);
        unsigned int n;
        if (!strcmp(mode, "bt")) {
            buf[0] = 0x31; buf[1] = 0x00 | (pass << 4); buf[2] = 0x10; fill_common(buf + 3);
            if (pass) { buf[5] = 0; buf[6] = 0; }
            unsigned char seed = 0xA2; unsigned int crc = 0xFFFFFFFFu;
            crc = crc32_step(crc, &seed, 1); crc = crc32_step(crc, buf, 74); crc ^= 0xFFFFFFFFu;
            buf[74] = crc; buf[75] = crc >> 8; buf[76] = crc >> 16; buf[77] = crc >> 24;
            n = 78;
        } else {
            buf[0] = 0x02; fill_common(buf + 1);
            if (pass) { buf[3] = 0; buf[4] = 0; }
            n = 48;
        }
        if (n < len) n = len;                            /* hidapi pads to the caps length */
        DWORD wrote = 0; BOOL ok = WriteFile(h, buf, n, &wrote, NULL);
        printf("%s report 0x%02x, %u bytes: %s (wrote %lu, err %lu)\n", pass ? "stop" : "rumble", buf[0], n, ok ? "ok" : "FAILED", wrote, GetLastError());
        fflush(stdout);
        Sleep(pass ? 100 : 1500);
    }
    CloseHandle(h);
    return 0;
}
