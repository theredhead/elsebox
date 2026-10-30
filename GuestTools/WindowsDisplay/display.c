/* WinPE display handoff using documented Win32 APIs. Built without a C runtime. */
typedef unsigned int DWORD;
typedef unsigned short WORD;
typedef unsigned short WCHAR;
typedef int BOOL;
typedef int LONG;
typedef void *HANDLE;
typedef struct {
    DWORD size;
    WCHAR name[32], description[128];
    DWORD flags;
    WCHAR id[128], key[128];
} Display;
typedef struct {
    WCHAR name[32];
    WORD spec, driver, size, extra;
    DWORD fields;
    LONG x, y;
    DWORD orientation, fixedOutput;
    short color, duplex, yResolution, ttOption, collate;
    WCHAR form[32];
    WORD logPixels;
    DWORD bits, width, height, flags, frequency, icmMethod, icmIntent, mediaType, dither, reserved1,
        reserved2, panningWidth, panningHeight;
} Mode;
_Static_assert(sizeof(Display) == 840, "DISPLAY_DEVICEW layout");
_Static_assert(sizeof(Mode) == 220, "DEVMODEW layout");
__declspec(dllimport) BOOL EnumDisplayDevicesW(const WCHAR *, DWORD, Display *, DWORD);
__declspec(dllimport) BOOL EnumDisplaySettingsExW(const WCHAR *, DWORD, Mode *, DWORD);
__declspec(dllimport) LONG ChangeDisplaySettingsExW(const WCHAR *, Mode *, HANDLE, DWORD, void *);
__declspec(dllimport) LONG SetDisplayConfig(DWORD, void *, DWORD, void *, DWORD);
__declspec(dllimport) HANDLE GetStdHandle(DWORD);
__declspec(dllimport) BOOL WriteFile(HANDLE, const void *, DWORD, DWORD *, void *);
__declspec(dllimport) void ExitProcess(DWORD);
__declspec(dllimport) void Sleep(DWORD);
void *memset(void *dst, int value, unsigned long long count) {
    unsigned char *p = dst;
    while (count--)
        *p++ = value;
    return dst;
}
void *memcpy(void *dst, const void *src, unsigned long long count) {
    unsigned char *d = dst;
    const unsigned char *s = src;
    while (count--)
        *d++ = *s++;
    return dst;
}
static void text(const char *s) {
    DWORD n = 0, written;
    while (s[n])
        n++;
    WriteFile(GetStdHandle((DWORD)-11), s, n, &written, 0);
}
static void wide(const WCHAR *s) {
    char buf[256];
    DWORD i = 0;
    while (s[i] && i < 255) {
        buf[i] = (s[i] < 128) ? s[i] : '?';
        i++;
    }
    buf[i] = 0;
    text(buf);
}
static void number(LONG value) {
    char b[16];
    unsigned int n = value < 0 ? -value : value;
    int i = 15;
    b[i] = 0;
    do {
        b[--i] = '0' + n % 10;
        n /= 10;
    } while (n);
    if (value < 0)
        b[--i] = '-';
    text(b + i);
}
static int virtio(const WCHAR *s) {
    const char *word = "virtio";
    for (int i = 0; s[i]; i++) {
        int j = 0;
        while (word[j] && ((s[i + j] | 32) == word[j]))
            j++;
        if (!word[j])
            return 1;
    }
    return 0;
}
void mainCRTStartup(void) {
    Sleep(2000);
    Display target = {0};
    for (DWORD i = 0; i < 32; i++) {
        Display d = {0};
        d.size = sizeof(d);
        if (!EnumDisplayDevicesW(0, i, &d, 0))
            break;
        text("Display: ");
        wide(d.name);
        text(" / ");
        wide(d.description);
        text(" flags=");
        number(d.flags);
        text("\r\n");
        if (virtio(d.description))
            target = d;
    }
    if (!target.size) {
        text("No VirtIO display adapter enumerated\r\n");
        ExitProcess(2);
    }
    Mode mode = {0};
    mode.size = sizeof(mode);
    int found = 0;
    for (DWORD i = 0; i < 128; i++) {
        mode.size = sizeof(mode);
        if (!EnumDisplaySettingsExW(target.name, i, &mode, 0))
            break;
        if (mode.width == 1024 && mode.height == 768 && mode.bits == 32) {
            found = 1;
            break;
        }
    }
    if (!found) {
        memset(&mode, 0, sizeof(mode));
        mode.size = sizeof(mode);
        mode.width = 1024;
        mode.height = 768;
        mode.bits = 32;
    }
    mode.x = 0;
    mode.y = 0;
    mode.fields = 0x20 | 0x40000 | 0x80000 | 0x100000;
    LONG result = ChangeDisplaySettingsExW(target.name, &mode, 0, 0x11, 0);
    text("Set VirtIO primary: ");
    number(result);
    text("\r\n");
    result = SetDisplayConfig(0, 0, 0, 0, 0x88);
    text("External display topology: ");
    number(result);
    text("\r\n");
    Sleep(1000);
    ExitProcess(0);
}
