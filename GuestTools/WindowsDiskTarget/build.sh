#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p ../../build/WindowsDiskTarget
linker=/opt/homebrew/opt/lld/bin/lld-link
"$linker" /lib /def:kernel32.def /machine:arm64 /out:../../build/WindowsDiskTarget/kernel32.lib
xcrun clang -target aarch64-unknown-windows -ffreestanding -fno-stack-protector -fno-builtin -O2 -c disk-target.c -o ../../build/WindowsDiskTarget/disk-target.obj
"$linker" /nologo /nodefaultlib /entry:mainCRTStartup /subsystem:console /machine:arm64 /out:../../Resources/WindowsBootstrap/disk-target.exe ../../build/WindowsDiskTarget/disk-target.obj ../../build/WindowsDiskTarget/kernel32.lib
xcrun clang -Wall -Wextra -Werror policy-checks.c -o ../../build/WindowsDiskTarget/policy-checks
../../build/WindowsDiskTarget/policy-checks
