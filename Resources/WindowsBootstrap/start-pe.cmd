@echo off
setlocal EnableExtensions EnableDelayedExpansion
wpeinit
set MEDIA=
set BOOT=
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if exist %%D:\VirtualMac\media.tag set MEDIA=%%D:
    if exist %%D:\EFI\caker\framebuffer.efi if exist %%D:\sources\boot.wim set BOOT=%%D:
)
if not defined MEDIA exit /b 1
set LOG=%MEDIA%\VirtualMac\WinPE.log
if exist "%MEDIA%\VirtualMac\installed" goto complete
if exist "%MEDIA%\VirtualMac\base-deployed" goto existing
echo WinPE deployment started > "%LOG%"
ver >> "%LOG%"
if not defined BOOT goto failed
X:\VirtualMac\disk-target.exe > X:\target.txt 2>> "%LOG%"
if errorlevel 1 (
    echo No unique empty NVMe system disk found. >> "%LOG%"
    goto failed
)
set TARGET=
set /p TARGET=<X:\target.txt
if not defined TARGET goto failed
echo Partitioning NVMe system disk !TARGET! >> "%LOG%"
> X:\partition.txt echo select disk !TARGET!
>> X:\partition.txt echo clean
>> X:\partition.txt echo convert gpt
>> X:\partition.txt echo create partition efi size=260
>> X:\partition.txt echo format quick fs=fat32 label=System
>> X:\partition.txt echo assign letter=S
>> X:\partition.txt echo create partition msr size=16
>> X:\partition.txt echo create partition primary
>> X:\partition.txt echo format quick fs=ntfs label=Windows
>> X:\partition.txt echo assign letter=W
diskpart /s X:\partition.txt >> "%LOG%" 2>&1
if not exist W:\ goto failed
call X:\VirtualMac\install-index.cmd
echo Applying Windows 11 Pro image >> "%LOG%"
dism /Apply-Image /ImageFile:"%MEDIA%\sources\install.wim" /Index:%INSTALL_INDEX% /ApplyDir:W:\ >> "%LOG%" 2>&1
if errorlevel 1 goto failed
echo ready > "%MEDIA%\VirtualMac\base-deployed"
echo Installing ARM64 guest drivers >> "%LOG%"
dism /Image:W:\ /Add-Driver /Driver:X:\VirtualMac\Drivers /Recurse >> "%LOG%" 2>&1
if errorlevel 1 goto failed
bcdboot W:\Windows /s S: /f UEFI >> "%LOG%" 2>&1
if errorlevel 1 goto failed
mkdir S:\EFI\BOOT 2>nul
mkdir S:\EFI\caker 2>nul
copy /y S:\EFI\Microsoft\Boot\bootmgfw.efi S:\EFI\BOOT\windows.efi >> "%LOG%"
if errorlevel 1 goto failed
copy /y "%BOOT%\EFI\BOOT\BOOTAA64.EFI" S:\EFI\BOOT\BOOTAA64.EFI >> "%LOG%"
if errorlevel 1 goto failed
copy /y "%BOOT%\EFI\caker\framebuffer.efi" S:\EFI\caker\framebuffer.efi >> "%LOG%"
if errorlevel 1 goto failed
if exist "%MEDIA%\VirtualMac\Provisioning\Unattend.xml" (
    echo Preparing local account and Windows settings >> "%LOG%"
    mkdir W:\Windows\Panther 2>nul
    mkdir W:\ProgramData\VirtualMac\Setup 2>nul
    copy /y "%MEDIA%\VirtualMac\Provisioning\*" W:\ProgramData\VirtualMac\Setup\ >> "%LOG%"
    if errorlevel 1 goto failed
    copy /y "%MEDIA%\VirtualMac\Provisioning\Unattend.xml" W:\Windows\Panther\unattend.xml >> "%LOG%"
    if errorlevel 1 goto failed
    del W:\ProgramData\VirtualMac\Setup\Unattend.xml
    del "%MEDIA%\VirtualMac\Provisioning\Unattend.xml"
    if exist "%MEDIA%\VirtualMac\Provisioning\EnableAudio" (
        bcdedit /store S:\EFI\Microsoft\Boot\BCD /set {default} testsigning on >> "%LOG%" 2>&1
        if errorlevel 1 goto failed
    )
)
echo Windows deployed; interactive first-run setup is next. >> "%LOG%"
echo installed > "%MEDIA%\VirtualMac\installed"
goto complete
:existing
echo DEPLOYMENT FAILED: Existing partial deployment; create a new Windows VM. > "%LOG%"
goto failed
:complete
if exist "%MEDIA%\VirtualMac\Provisioning\Unattend.xml" del "%MEDIA%\VirtualMac\Provisioning\Unattend.xml"
wpeutil shutdown
exit /b 0
:failed
echo DEPLOYMENT FAILED: %ERRORLEVEL% >> "%LOG%"
wpeutil shutdown
exit /b 1
