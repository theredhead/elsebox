# WinPE disk target selection

`disk-target.exe` is an ARM64 console utility built without a C runtime. It opens PhysicalDrive0–31
read-only and queries documented STORAGE_DEVICE_DESCRIPTOR and GET_LENGTH_INFORMATION
structures. It selects exactly one NVMe disk and verifies the first and last MiB are all zero.
The only exception is the four-byte MBR disk signature at offset 440, which WinPE may assign
before initialization. Partition entries, boot code and any tail data still cause refusal.
It does not require an uninitialized disk to expose a partition layout. Ambiguous, partitioned, unreadable or nonempty media is
refused. It never writes storage. This avoids parsing localized diskpart output.

Build with `zsh GuestTools/WindowsDiskTarget/build.sh` (Xcode clang and Homebrew lld required).
The script also runs native mocked-API safety checks. The normal app ships the built executable
as a resource, so Xcode users need not install a Windows SDK or WDK.
