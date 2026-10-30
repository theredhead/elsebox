# Windows VirtIO audio lab

Experimental driver testing uses an APFS clone of the stopped Windows Fresh disk at
`build/Windows Audio Lab.asvm`. Never enable test-signing or install this package on the
original VM or the macOS host. The ordinary Windows configuration still excludes native audio.

The downloaded ARM64 package is recorded in Provenance.json, including its release tag object,
archive and individual driver SHA-256 hashes. It is signed by a self-signed DroidVM Test certificate,
not a Microsoft production certificate. ARM64 PE imports are ntoskrnl.exe, HAL.dll and portcls.sys.
The INF has a generic PCI VEN_1AF4 DEV_1059 match. Source includes a fallback to normal guest DMA
when the Gunyah RDMA pool device is absent; compatibility with Apple remains unverified.

The lab driver disk is `build/WindowsAudioDrivers.img` (MBR/FAT32, 128 MiB).
A plain ISO on a VirtIO block device was not mounted by Windows, so the FAT disk is used instead.
Its scripts only install viosnd, never
the unrelated drivers bundled in the upstream archive. Prepare.cmd imports the pinned certificate
and enables Windows test-signing (requires explicit user approval). Restart, then Install.cmd stages
the driver. Shut down before enabling the lab-only experimentalWindowsAudio flag together with
audioOutputEnabled. Neither switch is offered in the ordinary Windows UI. Remove.cmd uninstalls
the driver, removes that certificate and switches test-signing off; restart afterwards.

CMD launchers request an elevated Windows shell. ExecutionPolicy Bypass applies only to that PowerShell
process. No Secure Boot, NLA, HVCI or host security settings are changed by the scripts.

Verify playback, driver Device Manager status, host-service stability and repeated shutdown/boot.
This is not a production-ready audio implementation until those checks pass.

Observed before driver installation: Windows update restarts can crash the Apple VM service on
its gpio.pl061 queue. Restarting the lab allowed updates to finish and the desktop to load.
Do not attribute that pre-existing reset behavior to the sound driver.

## Verified result — 2026-10-30

Windows Audio Lab booted with the ARM64 test-signed package installed as oem5.inf and
`experimentalWindowsAudio: true`, `audioOutputEnabled: true`. Windows Sound lists
“Speakers — XCB VirtIO Audio Device” as its default playback endpoint. The classic Sound
panel’s Test action drove the output meter, and the user confirmed both left/right chimes
played clearly through the Mac. No RDP audio redirection was involved.

Production signing, sustained playback/latency, capture and repeat-boot endurance remain
unverified. Keep the ordinary Windows audio guard in place until an explicitly provisioned
experimental setup or a production-signed driver is available.

Media delivery: neither the ISO nor the read-only FAT disk appeared as a Windows volume on
the existing VirtIO block driver. The successful transfer used the VM private network:
`build/WindowsAudioHTTP/lab.zip` was served temporarily on 192.168.64.1:1080 and downloaded
with curl.exe, then extracted with tar. The server has been stopped. No host sharing or guest
remote-login service was needed. The driver scripts are at C:/Users/kris in the clone.

Actual sequence: Prepare.cmd -> approve UAC -> successful test-signing setup -> full shutdown
and boot -> Install.cmd -> approve UAC -> PnP driver package added -> full shutdown -> enable
both lab flags and remove the temporary driverMediaPath -> boot -> Windows detects speakers.
The first script revision printed an expected missing Media-class device after staging (because
the hardware was still off); its source now suppresses that informational query error.

Original Windows Fresh disk and its Windows security settings were not modified.
