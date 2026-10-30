#!/bin/zsh
set -euo pipefail
image="$1"
drivers="$2"
resources="$3"
work=$(/usr/bin/mktemp -d)
image_device=""
driver_device=""
cleanup() {
    if [[ -n "$image_device" ]]; then /usr/bin/hdiutil detach "$image_device" >/dev/null 2>&1 || true; fi
    if [[ -n "$driver_device" ]]; then /usr/bin/hdiutil detach "$driver_device" >/dev/null 2>&1 || true; fi
    /bin/rm -rf "$work"
}
trap cleanup EXIT
/usr/bin/hdiutil attach -nobrowse -plist "$image" > "$work/image.plist"
first=$(/usr/libexec/PlistBuddy -c 'Print :system-entities:0:dev-entry' "$work/image.plist")
image_device="${first%%s<->}"
[[ "$image_device" == /dev/disk<-> ]] || exit 1
/usr/sbin/diskutil info -plist "${image_device}s2" > "$work/boot.plist"
/usr/sbin/diskutil info -plist "${image_device}s3" > "$work/install.plist"
boot_mount=$(/usr/libexec/PlistBuddy -c 'Print :MountPoint' "$work/boot.plist")
install_mount=$(/usr/libexec/PlistBuddy -c 'Print :MountPoint' "$work/install.plist")
/usr/bin/hdiutil attach -readonly -nobrowse -plist "$drivers" > "$work/drivers.plist"
driver_device=$(/usr/libexec/PlistBuddy -c 'Print :system-entities:0:dev-entry' "$work/drivers.plist")
driver_mount=$(/usr/libexec/PlistBuddy -c 'Print :system-entities:0:mount-point' "$work/drivers.plist")
/bin/mkdir -p "$work/payload/Drivers" "$install_mount/VirtualMac"
for driver in viostor viogpudo NetKVM; do
    /bin/mkdir -p "$work/payload/Drivers/$driver"
    /bin/cp -R "$driver_mount/$driver/w11/ARM64/" "$work/payload/Drivers/$driver/"
done
if ! /usr/bin/grep -Eiq 'PCI\\VEN_1AF4&DEV_1050[[:space:]]*$' "$work/payload/Drivers/viogpudo/viogpudo.inf"; then
    print -u2 'The ARM64 graphics driver does not match Apple virtual GPUs. Select a current VirtIO driver ISO.'
    exit 1
fi
"$resources/Tools/wimlib-imagex" info "$install_mount/sources/install.wim" --xml > "$work/images.xml"
index=$(/usr/bin/xmllint --xpath 'string(/WIM/IMAGE[WINDOWS/EDITIONID="Professional"]/@INDEX)' "$work/images.xml")
[[ "$index" == <-> ]] || { print -u2 'This media does not contain Windows Pro.'; exit 1; }
print "set INSTALL_INDEX=$index" > "$work/payload/install-index.cmd"
/bin/cp "$resources/start-pe.cmd" "$work/payload/start-pe.cmd"
/bin/cp "$resources/disk-target.exe" "$work/payload/disk-target.exe"
print ready > "$install_mount/VirtualMac/media.tag"
cat > "$work/update.txt" <<COMMANDS
add "$work/payload" /VirtualMac
add "$resources/winpeshl.ini" /Windows/System32/winpeshl.ini
COMMANDS
"$resources/Tools/wimlib-imagex" update "$boot_mount/sources/boot.wim" 2 < "$work/update.txt" >/dev/null
/bin/sync
/usr/bin/hdiutil detach "$image_device" >/dev/null
image_device=""
