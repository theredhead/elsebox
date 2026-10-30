#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p build/ModuleCache
xcrun swift-format lint --strict --configuration .swift-format --recursive Sources Tests scripts/HelperAppLifecycle.swift
swiftlint lint --strict --config .swiftlint.yml --no-cache
xcrun clang -Wall -Wextra -Werror GuestTools/WindowsDiskTarget/policy-checks.c -o build/DiskTargetChecks
build/DiskTargetChecks
model_sources=(Sources/InstallerMediaCache.swift Sources/GuestPresets.swift Sources/VMSettings.swift Sources/WindowsSetup.swift Sources/VMDiskStore.swift Sources/HostFileOperations.swift Sources/VMBundle.swift Sources/VMLibrary.swift)
for check_name in SettingsChecks LibraryChecks WindowsSetupChecks; do
    xcrun swiftc -module-cache-path build/ModuleCache "${model_sources[@]}" "Tests/$check_name.swift" -o "build/$check_name"
    "build/$check_name"
done
xcrun swiftc -module-cache-path build/ModuleCache "${model_sources[@]}" Sources/InstallerCatalog.swift Sources/InstallerTransport.swift Sources/InstallerMediaService.swift Sources/WindowsInstallerResolver.swift Tests/InstallerChecks.swift -o build/InstallerChecks
build/InstallerChecks
xcrun swiftc -module-cache-path build/ModuleCache "${model_sources[@]}" Sources/EFIVMConfiguration.swift Sources/VMAudioConfiguration.swift Sources/WindowsBootMedia.swift Tests/GuestConfigurationChecks.swift -o build/GuestConfigurationChecks
codesign --force --sign - --entitlements VirtualMac.entitlements build/GuestConfigurationChecks
build/GuestConfigurationChecks
xcrun swiftc -module-cache-path build/ModuleCache -swift-version 5 Sources/VMInputView.swift Tests/InputChecks.swift -o build/InputChecks
build/InputChecks
xcrun swiftc -module-cache-path build/ModuleCache Sources/DisplayLayout.swift Tests/DisplayLayoutChecks.swift -o build/DisplayLayoutChecks
build/DisplayLayoutChecks
xcrun swiftc -module-cache-path build/ModuleCache Sources/VMActivity.swift Tests/ActivityChecks.swift -o build/ActivityChecks
build/ActivityChecks
for bootstrap_script in Resources/WindowsBootstrap/*.sh; do
    zsh -n "$bootstrap_script"
done
if ! xcodebuild -project VirtualMac.xcodeproj -scheme VirtualMac -configuration Debug -derivedDataPath build/Xcode build > build/xcodebuild.log 2>&1; then
    tail -n 60 build/xcodebuild.log
    exit 1
fi
codesign --verify --strict build/Xcode/Build/Products/Debug/VirtualMac.app
plutil -lint Info.plist VirtualMac.xcodeproj/project.pbxproj
echo 'Xcode build and signature verification passed.'
