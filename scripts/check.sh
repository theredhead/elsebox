#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p build/ModuleCache
python3 scripts/check-readability.py
python3 scripts/check-architecture.py
xcrun swiftc -module-cache-path build/ModuleCache -typecheck Sources/Domain/**/*.swift
python3 scripts/check-bundled-drivers.py
python3 scripts/check-windows-provisioning.py
xcrun swift-format lint --strict --configuration .swift-format --recursive Sources Tests scripts/HelperAppLifecycle.swift
swiftlint lint --strict --config .swiftlint.yml --no-cache
xcrun clang -Wall -Wextra -Werror GuestTools/WindowsDiskTarget/policy-checks.c -o build/DiskTargetChecks
build/DiskTargetChecks
model_sources=(Sources/Domain/Machines/VMHardwareSummary.swift Sources/Domain/Machines/VMManifest.swift Sources/Platform/Storage/InstallerMediaCache.swift Sources/Domain/Machines/GuestPresets.swift Sources/Domain/Machines/VMSettings.swift Sources/Domain/Windows/WindowsCulture.swift Sources/Domain/Windows/WindowsAnswerFile.swift Sources/Platform/Security/WindowsSetupSecret.swift Sources/Platform/Storage/VMDiskStore.swift Sources/Platform/Storage/HostFileOperations.swift Sources/Platform/Storage/VMBundle.swift Sources/Platform/Storage/VMLibrary.swift)
for check_name in SettingsChecks LibraryChecks WindowsSetupChecks; do
    xcrun swiftc -module-cache-path build/ModuleCache "${model_sources[@]}" "Tests/$check_name.swift" -o "build/$check_name"
    "build/$check_name"
done
xcrun swiftc -module-cache-path build/ModuleCache "${model_sources[@]}" Sources/Platform/Installers/InstallerCatalog.swift Sources/Platform/Installers/InstallerTransport.swift Sources/Platform/Installers/InstallerMediaService.swift Sources/Platform/Installers/WindowsInstallerResolver.swift Tests/InstallerChecks.swift -o build/InstallerChecks
build/InstallerChecks
xcrun swiftc -module-cache-path build/ModuleCache "${model_sources[@]}" Sources/Platform/Installers/InstallerCatalog.swift Sources/Platform/Installers/InstallerTransport.swift Sources/Platform/Installers/InstallerMediaService.swift Sources/Platform/Installers/WindowsInstallerResolver.swift Sources/Application/InstallerPreparation.swift Tests/PreparationChecks.swift -o build/PreparationChecks
build/PreparationChecks
xcrun swiftc -module-cache-path build/ModuleCache "${model_sources[@]}" Sources/Platform/Virtualization/EFIVMConfiguration.swift Sources/Platform/Virtualization/VMAudioConfiguration.swift Sources/Platform/Virtualization/WindowsBootMedia.swift Tests/GuestConfigurationChecks.swift -o build/GuestConfigurationChecks
codesign --force --sign - --entitlements ElseBox.entitlements build/GuestConfigurationChecks
build/GuestConfigurationChecks
xcrun swiftc -module-cache-path build/ModuleCache -swift-version 5 Sources/Presentation/Console/VMInputView.swift Tests/InputChecks.swift -o build/InputChecks
build/InputChecks
xcrun swiftc -module-cache-path build/ModuleCache Sources/Domain/Machines/DisplayLayout.swift Tests/DisplayLayoutChecks.swift -o build/DisplayLayoutChecks
build/DisplayLayoutChecks
xcrun swiftc -module-cache-path build/ModuleCache Sources/Domain/Monitoring/VMActivity.swift Tests/ActivityChecks.swift -o build/ActivityChecks
build/ActivityChecks
xcrun swiftc -module-cache-path build/ModuleCache Sources/Domain/Monitoring/VMActivity.swift Sources/Domain/Monitoring/VMLibraryActivity.swift Sources/Platform/Storage/VMLibraryStorage.swift Sources/Platform/Storage/InstallerMediaInventory.swift Sources/Platform/Storage/RecentDiskImages.swift Tests/LibraryOverviewChecks.swift -o build/LibraryOverviewChecks
build/LibraryOverviewChecks
xcrun swiftc -module-cache-path build/ModuleCache Sources/Domain/Monitoring/VMNetworkSnapshot.swift Sources/Platform/Monitoring/VMNetworkAddressParser.swift Sources/Platform/Monitoring/VMNetworkAddressSource.swift Tests/NetworkAddressChecks.swift -o build/NetworkAddressChecks
build/NetworkAddressChecks
ui_sources=(Sources/**/*.swift)
ui_sources=("${ui_sources[@]:#Sources/Application/ElseBoxApp.swift}")
xcrun swiftc -module-cache-path build/ModuleCache -swift-version 5 "${ui_sources[@]}" Tests/PreferencesChecks.swift -o build/PreferencesChecks
build/PreferencesChecks
for bootstrap_script in Resources/WindowsBootstrap/*.sh; do
    zsh -n "$bootstrap_script"
done
if ! xcodebuild -project ElseBox.xcodeproj -scheme ElseBox -configuration Debug -derivedDataPath build/Xcode build > build/xcodebuild.log 2>&1; then
    tail -n 60 build/xcodebuild.log
    exit 1
fi
codesign --verify --strict build/Xcode/Build/Products/Debug/ElseBox.app
plutil -lint Info.plist ElseBox.xcodeproj/project.pbxproj
python3 scripts/check-product.py build/Xcode/Build/Products/Debug/ElseBox.app/Contents/Info.plist
echo 'Xcode build and signature verification passed.'
