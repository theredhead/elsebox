#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p ../../build/WindowsDisplay
linker=/opt/homebrew/opt/lld/bin/lld-link
"$linker" /lib /def:user32.def /machine:arm64 /out:../../build/WindowsDisplay/user32.lib
"$linker" /lib /def:kernel32.def /machine:arm64 /out:../../build/WindowsDisplay/kernel32.lib
xcrun clang -target aarch64-unknown-windows -ffreestanding -fno-stack-protector -fno-builtin -O2 -c display.c -o ../../build/WindowsDisplay/display.obj
"$linker" /nologo /nodefaultlib /entry:mainCRTStartup /subsystem:console /machine:arm64 /out:../../Resources/WindowsBootstrap/display.exe ../../build/WindowsDisplay/display.obj ../../build/WindowsDisplay/user32.lib ../../build/WindowsDisplay/kernel32.lib
