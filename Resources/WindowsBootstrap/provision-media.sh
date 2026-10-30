#!/bin/zsh
set -euo pipefail
image="$1"
payload="$2"
work=$(/usr/bin/mktemp -d)
device=""
cleanup() {
    if [[ -n "$device" ]]; then /usr/bin/hdiutil detach "$device" >/dev/null 2>&1 || true; fi
    /bin/rm -rf "$work"
}
trap cleanup EXIT
/usr/bin/hdiutil attach -nobrowse -plist "$image" > "$work/mount.plist"
first=$(/usr/libexec/PlistBuddy -c 'Print :system-entities:0:dev-entry' "$work/mount.plist")
device="${first%%s<->}"
[[ "$device" == /dev/disk<-> ]] || exit 1
/usr/sbin/diskutil info -plist "${device}s3" > "$work/info.plist"
mount=$(/usr/libexec/PlistBuddy -c 'Print :MountPoint' "$work/info.plist")
target="$mount/VirtualMac/Provisioning"
/bin/mkdir -p "$target"
/bin/cp -f "$payload/"* "$target/"
/bin/sync
