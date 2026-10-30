#!/bin/zsh
set -eu
cd "${0:A:h}"
APP="$PWD/build/VirtualMac.app"
mkdir -p "$APP/Contents/MacOS" "$PWD/build/ModuleCache"
xcrun swiftc -module-cache-path "$PWD/build/ModuleCache" -swift-version 5 -target arm64-apple-macosx14.0 -framework AppKit -framework Virtualization Sources/**/*.swift -o "$APP/Contents/MacOS/VirtualMac"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -Rf Resources/WindowsBootstrap "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleExecutable -string VirtualMac "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string nl.theredhead.virtualmac "$APP/Contents/Info.plist"
codesign --force --sign - --entitlements VirtualMac.entitlements "$APP"
echo "Built $APP"
