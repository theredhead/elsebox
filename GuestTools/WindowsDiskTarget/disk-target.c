/* Read-only WinPE target selection using documented Win32 storage APIs. */
#ifdef VM_DISK_TEST
#define IMPORT
#else
#define IMPORT __declspec(dllimport)
#endif
typedef unsigned int DWORD;
typedef unsigned short WCHAR;
typedef int BOOL;
typedef void *HANDLE;
#define INVALID_HANDLE ((HANDLE)(long long)-1)
IMPORT HANDLE CreateFileW(const WCHAR *, DWORD, DWORD, void *, DWORD, DWORD, HANDLE);
IMPORT BOOL DeviceIoControl(HANDLE, DWORD, void *, DWORD, void *, DWORD, DWORD *, void *);
IMPORT BOOL ReadFile(HANDLE, void *, DWORD, DWORD *, void *);
IMPORT BOOL CloseHandle(HANDLE);
IMPORT BOOL SetFilePointerEx(HANDLE, long long, long long *, DWORD);
IMPORT HANDLE GetStdHandle(DWORD);
IMPORT BOOL WriteFile(HANDLE, const void *, DWORD, DWORD *, void *);
IMPORT void ExitProcess(DWORD);
IMPORT DWORD GetLastError(void);
static DWORD descriptor[1024];
static long long diskLength;
static unsigned char firstMegabyte[1048576];

/* Diagnostics use stderr so stdout remains an unambiguous disk number. */
static void diagnostic(const char *message, DWORD value) {
#ifndef VM_DISK_TEST
    DWORD count = 0;
    while (message[count]) count++;
    DWORD written;
    HANDLE output = GetStdHandle((DWORD)-12);
    WriteFile(output, message, count, &written, 0);
    char number[12];
    DWORD length = 0;
    do { number[length++] = (char)('0' + value % 10); value /= 10; } while (value);
    for (DWORD index = 0; index < length / 2; index++) {
        char temporary = number[index];
        number[index] = number[length - index - 1];
        number[length - index - 1] = temporary;
    }
    number[length++] = '\n';
    WriteFile(output, number, length, &written, 0);
#else
    (void)message; (void)value;
#endif
}

/* Check both disk boundaries directly: uninitialized disks need not expose a partition layout. */
static int emptyBoundary(HANDLE disk, int first) {
    DWORD returned = 0;
    if (!ReadFile(disk, firstMegabyte, sizeof(firstMegabyte), &returned, 0) ||
        returned != sizeof(firstMegabyte)) { diagnostic("Boundary read failed, error=", GetLastError()); return 0; }
    for (DWORD byte = 0; byte < sizeof(firstMegabyte); byte++) {
        /* WinPE assigns an MBR disk signature even before the disk is initialized. */
        if (first && byte >= 440 && byte < 444) continue;
        if (firstMegabyte[byte] != 0) { diagnostic("Nonzero boundary byte at offset=", byte); return 0; }
    }
    return 1;
}

/* Return a unique NVMe disk with empty first/last MiB. Never write a disk. */
static int findTarget(void) {
    int target = -1;
    for (DWORD index = 0; index < 32; index++) {
        WCHAR path[] = {'\\', '\\', '.', '\\', 'P', 'h', 'y', 's', 'i', 'c', 'a', 'l', 'D', 'r', 'i', 'v', 'e', 0, 0, 0};
        path[17] = (WCHAR)('0' + (index < 10 ? index : index / 10));
        if (index >= 10) path[18] = (WCHAR)('0' + index % 10);
        HANDLE disk = CreateFileW(path, 0x80000000u, 3, 0, 3, 0, 0);
        if (disk == INVALID_HANDLE) {
            if (index < 4) diagnostic("Open PhysicalDrive failed, error=", GetLastError());
            continue;
        }
        diagnostic("PhysicalDrive index=", index);
        DWORD query[3] = {0, 0, 0};
        DWORD returned = 0;
        BOOL described = DeviceIoControl(disk, 0x002d1400u, query, sizeof(query), descriptor,
                                        sizeof(descriptor), &returned, 0);
        if (!described) diagnostic("Storage descriptor failed, error=", GetLastError());
        else {
            diagnostic("Storage descriptor bytes=", returned);
            diagnostic("Storage bus type=", descriptor[7]);
        }
        if (!described || returned < 32 || descriptor[7] != 17) {
            CloseHandle(disk);
            continue;
        }
        if (target >= 0) {
            CloseHandle(disk);
            return -1; /* Ambiguous NVMe topology, even if only one disk is empty. */
        }
        BOOL sized = DeviceIoControl(disk, 0x0007405cu, 0, 0, &diskLength,
                                     sizeof(diskLength), &returned, 0);
        if (!sized) diagnostic("Disk length failed, error=", GetLastError());
        else diagnostic("Disk length returned bytes=", returned);
        if (!sized || returned < sizeof(diskLength) || diskLength < 2 * (long long)sizeof(firstMegabyte) ||
            !emptyBoundary(disk, 1) ||
            !SetFilePointerEx(disk, diskLength - sizeof(firstMegabyte), 0, 0) || !emptyBoundary(disk, 0)) {
            CloseHandle(disk);
            return -1;
        }
        CloseHandle(disk);
        target = (int)index;
    }
    return target;
}

#ifndef VM_DISK_TEST
void mainCRTStartup(void) {
    diagnostic("Disk selector version=", 12);
    int target = findTarget();
    if (target < 0) ExitProcess(1);
    char number[4];
    DWORD length = 0;
    if (target >= 10) number[length++] = (char)('0' + target / 10);
    number[length++] = (char)('0' + target % 10);
    number[length++] = '\n';
    DWORD written;
    if (!WriteFile(GetStdHandle((DWORD)-11), number, length, &written, 0) || written != length) ExitProcess(1);
    ExitProcess(0);
}
#endif
