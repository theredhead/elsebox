#!/bin/zsh
set -euo pipefail
iso="$1"
image="$2"
firmware="$3"
work=$(/usr/bin/mktemp -d)
source_device=""
image_device=""
cleanup() {
    if [[ -n "$source_device" ]]; then /usr/bin/hdiutil detach "$source_device" >/dev/null 2>&1 || true; fi
    if [[ -n "$image_device" ]]; then /usr/bin/hdiutil detach "$image_device" >/dev/null 2>&1 || true; fi
    /bin/rm -rf "$work"
}
trap cleanup EXIT
/usr/bin/hdiutil attach -readonly -nobrowse -plist "$iso" > "$work/source.plist"
source_device=$(/usr/libexec/PlistBuddy -c 'Print :system-entities:0:dev-entry' "$work/source.plist")
source_mount=""
for index in {0..15}; do
    candidate=$(/usr/libexec/PlistBuddy -c "Print :system-entities:$index:mount-point" "$work/source.plist" 2>/dev/null || true)
    if [[ -n "$candidate" && -f "$candidate/efi/boot/bootaa64.efi" ]]; then source_mount="$candidate"; break; fi
done
[[ -n "$source_mount" ]] || { print -u2 'The ISO has no ARM64 EFI boot loader.'; exit 1; }
/usr/sbin/mkfile -n 12g "$image"
/usr/bin/hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage -plist "$image" > "$work/image.plist"
image_device=$(/usr/libexec/PlistBuddy -c 'Print :system-entities:0:dev-entry' "$work/image.plist")
[[ "$image_device" == /dev/disk<-> ]] || { print -u2 'Invalid attached image device.'; exit 1; }
# This device is obtained only from attaching the newly created RAW image above.
/usr/sbin/diskutil partitionDisk "$image_device" GPT 'MS-DOS FAT32' VMBOOT 2g ExFAT VMINSTALL R >/dev/null
/usr/sbin/diskutil info -plist "${image_device}s2" > "$work/boot.plist"
/usr/sbin/diskutil info -plist "${image_device}s3" > "$work/install.plist"
boot_mount=$(/usr/libexec/PlistBuddy -c 'Print :MountPoint' "$work/boot.plist")
install_mount=$(/usr/libexec/PlistBuddy -c 'Print :MountPoint' "$work/install.plist")
/usr/bin/rsync -r --exclude='/sources/install.wim' --exclude='/sources/install.esd' "$source_mount/" "$boot_mount/"
/usr/bin/rsync -r "$source_mount/" "$install_mount/"
/bin/mkdir -p "$boot_mount/EFI/caker"
/bin/cp "$boot_mount/efi/boot/bootaa64.efi" "$boot_mount/efi/boot/windows.efi"
/bin/cp "$firmware/BOOTAA64.EFI" "$boot_mount/efi/boot/bootaa64.efi"
/bin/cp "$firmware/framebuffer.efi" "$boot_mount/EFI/caker/framebuffer.efi"
/bin/sync
/usr/bin/hdiutil detach "$image_device" >/dev/null
image_device=""
