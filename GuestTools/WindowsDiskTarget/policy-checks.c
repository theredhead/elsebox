#define VM_DISK_TEST
#include "disk-target.c"
#include <assert.h>
#include <string.h>
static int mode;
static int atEnd;
HANDLE CreateFileW(const WCHAR *path, DWORD access, DWORD share, void *security,
                   DWORD disposition, DWORD flags, HANDLE template) {
    (void)access; (void)share; (void)security; (void)disposition; (void)flags; (void)template;
    int index = path[18] ? (path[17] - '0') * 10 + path[18] - '0' : path[17] - '0';
    if (index == 0) atEnd = 0;
    if (index == 0 || (mode == 3 && index == 1)) return (HANDLE)(long long)(index + 1);
    return INVALID_HANDLE;
}
BOOL DeviceIoControl(HANDLE disk, DWORD code, void *input, DWORD inputSize, void *output,
                     DWORD size, DWORD *returned, void *overlapped) {
    (void)disk; (void)input; (void)inputSize; (void)size; (void)overlapped;
    DWORD *data = output;
    memset(data, 0, size);
    *returned = size;
    if (code == 0x002d1400u) data[7] = mode == 4 ? 7 : 17;
    else { *(long long *)output = mode == 6 ? 0 : 50LL * 1024 * 1024 * 1024; }
    return mode != 5;
}
BOOL ReadFile(HANDLE disk, void *output, DWORD size, DWORD *returned, void *overlapped) {
    (void)disk; (void)overlapped;
    memset(output, 0, size);
    if ((mode == 10 && !atEnd) || (mode == 11 && atEnd)) {
        ((unsigned char *)output)[440] = 0x12;
        ((unsigned char *)output)[443] = 0x34;
    }
    if (mode == 1 || mode == 2 || (mode == 8 && atEnd)) ((unsigned char *)output)[512] = 1;
    *returned = mode == 9 ? size - 1 : size;
    return 1;
}
BOOL SetFilePointerEx(HANDLE disk, long long offset, long long *result, DWORD method) {
    (void)disk; (void)offset; (void)result; (void)method;
    atEnd = 1;
    return mode != 7;
}
BOOL CloseHandle(HANDLE disk) { (void)disk; return 1; }
DWORD GetLastError(void) { return 1; }
int main(void) {
    mode = 0; assert(findTarget() == 0);
    for (mode = 1; mode <= 9; mode++) assert(findTarget() == -1);
    mode = 10; assert(findTarget() == 0); /* WinPE's disk signature is not a partition. */
    mode = 11; assert(findTarget() == -1); /* The same bytes at the tail are not exempt. */
    return 0;
}
