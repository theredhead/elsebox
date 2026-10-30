#!/bin/zsh
set -euo pipefail
work=$(/usr/bin/mktemp -d)
device=""
cleanup() {
    if [[ -n "$device" ]]; then /usr/bin/hdiutil detach "$device" >/dev/null 2>&1 || true; fi
    /bin/rm -rf "$work"
}
trap cleanup EXIT
/usr/bin/hdiutil attach -readonly -nobrowse -plist "$1" > "$work/mount.plist"
first=$(/usr/libexec/PlistBuddy -c 'Print :system-entities:0:dev-entry' "$work/mount.plist")
device="${first%%s<->}"
/usr/sbin/diskutil info -plist "${device}s3" > "$work/info.plist"
mount=$(/usr/libexec/PlistBuddy -c 'Print :MountPoint' "$work/info.plist")
if [[ -f "$mount/VirtualMac/installed" ]]; then
    print installed
elif [[ -f "$mount/VirtualMac/WinPE.log" ]]; then
    /usr/bin/tail -c 8192 "$mount/VirtualMac/WinPE.log"
fi
