UEFI helpers from Fred78290/caker, commit fc1f4279a5db563c2710c8c085971097522ddb94,
https://github.com/Fred78290/caker/tree/fc1f4279a5db563c2710c8c085971097522ddb94/Tools/WindowsEFI

Licensed under AGPL-3.0; LICENSE and corresponding source are included here and in the app resources.
The EFI programs execute separately inside the guest; they are not linked into the Swift host.
The ARM64 binaries were decoded from that commit's WindowsEFIBinaries.swift. The upstream
Makefile documents reproduction using clang and lld-link. Source is unchanged.

framebuffer.efi SHA-256: 4f8c0253c412c952d01fd0a3015c64411c653f817393d961bd2cfcaca9b35186
BOOTAA64.EFI SHA-256: 6dacdb1eefa3eb525422f0217025218d8a96b676f32e199879a454b14a6dbf1e
