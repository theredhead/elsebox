# ElseBox

[Source repository](https://github.com/theredhead/elsebox)

An AppKit VM library for Apple silicon. Each virtual machine is a portable **`.asvm`** (Apple Silicon Virtual Machine) bundle with its own configuration, disk, firmware, and identity. Requires macOS Sonoma 14+; live removable disks require Sequoia 15+.

## Run

Open `ElseBox.xcodeproj`, select **ElseBox → My Mac**, and run. Local builds use ad-hoc signing with the virtualization entitlement; no development team is needed.

```sh
./build.sh
open build/ElseBox.app
```

Launch opens the **VM Library**, with nothing running automatically. Create or open bundles, select a VM, and choose **Start**, **Configure**, or **Show Window**. Multiple VM windows and running sessions are independent. **File → Show VM Library** (Command-L) returns to the list. A stopped VM displays its system icon, specs, and Start/Configure buttons.

## Starters

New VM offers macOS, Debian, Ubuntu, Fedora, Arch Linux ARM, and custom Linux, with minimal/CLI, server, and desktop resource presets for Linux. These set hardware defaults; they do not perform unattended package installation.

| Preset | CPU cores | RAM | Sparse disk |
| --- | ---: | ---: | ---: |
| macOS | 4 | 4 GiB | 50 GB |
| Linux minimal / CLI | 2 | 2 GiB | 16 GB |
| Linux server | 2 | 4 GiB | 32 GB |
| Linux desktop | 4 | 8 GiB | 64 GB |

Arch minimal defaults to 4 GiB for custom installation media. Counts are constrained to the host/framework limits at boot. New VMs start with an empty shared-folder list. Disk capacities use decimal GB and can be customized from 8 to 4096 GB; the guest OS's own space requirements still apply.

### macOS

Create/Save prepares Apple's compatible restore image in the shared media cache, or imports a selected local IPSW into that cache. First start installs macOS from it. Complete macOS Setup Assistant in the guest. Subsequent starts reuse the saved hardware model, machine identifier, auxiliary storage, and disk.

### Linux

Create automatically downloads the matching **ARM64/aarch64 EFI installer ISO** for Debian, Ubuntu, or Fedora. Save does the same when **Use Automatic** is selected and installer boot is enabled. Ubuntu defaults to the current published LTS; Fedora uses netinst for CLI, Server DVD for server, and Workstation Live for desktop. Existing media is reused, and downloads have progress and cancellation. Local ISO selection overrides automatic selection. Arch/custom Linux require local compatible media. Installer files are shared centrally, never copied into each new VM bundle. The VM uses EFI, a persistent generic machine identifier and variable store, virtio storage/network/graphics, USB keyboard/pointer, entropy, and a memory balloon.

Install the selected distro in the guest. After shutting it down, choose **Virtual Machine → Boot from Startup Disk**, or clear **Boot installer ISO** in Configuration, then start again. The CLI/server/desktop package selection is made in the installer; the preset is a hardware starting point.

Official sources:

- [Debian ARM64 netinst](https://www.debian.org/CD/netinst/) supports minimal, server, and desktop package selections.
- [Ubuntu ARM server](https://ubuntu.com/download/server/arm) and [Ubuntu Desktop](https://ubuntu.com/download/desktop) offer ARM64 images.
- [Fedora Server](https://fedoraproject.org/server/download/) and [Workstation](https://fedoraproject.org/workstation/download/) offer aarch64 media.
- **Arch Linux ARM is an advanced custom-media starter.** Its [generic download](https://archlinuxarm.org/platforms/armv8/generic) is a root filesystem, not a drop-in EFI installer ISO. A compatible kernel/boot image must be prepared separately. The standard Arch x86_64 ISO is incompatible; [Archboot currently documents an Apple Virtualization limitation](https://archboot.com/). This preset is not a claim that those stock images boot here.

This app's Linux implementation follows Apple's [EFI GUI Linux sample](https://developer.apple.com/documentation/virtualization/running-gui-linux-in-a-virtual-machine-on-a-mac). Individual distro installations have not been end-to-end boot-tested here. An experimental Windows ARM EFI configuration is also available; see its limitations below.

## Bundles and registry

Default storage:

```text
~/Library/Application Support/nl.theredhead.elsebox/
    Registry.json
    Install Media/
        Index/                           # Preset-to-media references
        Locks/                           # Coordinates simultaneous requests
        <sha256>/Installer.iso           # Or Installer.ipsw
    Virtual Machines/
        Example.asvm/
            VM.json
            Resources.json
            Disk.img
            ManagedDisk
            Shared/
            HardwareModel                # macOS
            MachineIdentifier
            AuxiliaryStorage             # macOS
            EFIVariableStore             # Linux
            MinimumResources.json        # macOS restore requirements
            Installed                    # Completed macOS installation
```

`VM.json` contains the bundle UUID, name, distro, and preset. Disk and firmware paths in `Resources.json` are relative, so moving the entire bundle preserves them. Installer paths use `media://` content references into the central cache; VMs using the same installer share one file. Linux downloads are checked against publisher SHA-256 manifests before they become available. Interrupted downloads do not become selected media, and concurrent requests for one image wait for the same completed download. The cache remains after a VM is removed from the registry. Older bundle-local media remains readable and is imported centrally on Save; existing backup copies are retained. Moving a bundle to another Mac does not copy the shared cache—Save can prepare required automatic media there. Additional startup disks and their identities stay under `Disks/` inside the bundle. Explicit shared folders remain references to host directories; live removable images are external session devices.

The central registry stores known absolute bundle paths. On launch and when returning to the library, unavailable, moved, renamed, invalid, or unreadable entries are pruned **without deleting bundle files**. Open a moved bundle again to register its new location. **Remove from Library** also leaves files intact. Opening a bundle registers/selects it without starting it. Finder `.asvm` associations are declared in the app's Info.plist.

Bundles carry stable identity; opening a filesystem copy with the same UUID while the original remains registered is rejected. Cloning with a new guest identity, snapshots, and automatic disposal are not implemented yet. A per-bundle advisory lease prevents starting the same VM in two app processes, and disk import requires a stopped source.

### Existing single-VM setup

On first launch, the previous selected disk and settings are imported to `Virtual Machines/ElseBox.asvm`. Hardware identity and installation state are preserved. APFS copy-on-write is used when available, and the original files remain as a backup. If an older app instance or the disk is still in use, migration is deferred; close that instance after guest shutdown and use **File → Import Previous VM…**. Migration is tracked in the registry and does not repeat after success.

## Configuration and display

All VM settings are independent and apply on that VM's next Start. A reboot inside a running guest does not rebuild its configuration.

- **Hardware:** CPU, memory, resolution slider, and host-aspect matching. macOS also has display density (default **72 PPI**) and USB mouse/native trackpad selection. The USB mode works around reported trackpad scrolling delays and normalizes secondary-button events. Linux uses its supported USB pointer and guest-side display scaling.
- **Storage & Installation:** Create another startup disk inside this bundle, import a stopped compatible-family disk with its identity, select local or automatic IPSW/ISO media, and select Linux installer/disk boot. Existing disks are never resized or overwritten. Creation writes a new sparse image immediately even if Configuration is canceled; importing or downloading installation media into the shared cache occurs on Create/Save.
- **Shared Folders:** A list of guest names, host directories, and per-folder read-only controls. Names must be unique. Empty means no sharing. macOS uses guest automount. Linux uses virtiofs tag `shared`; on a supporting kernel, mount it with `sudo mount -t virtiofs shared /mnt/host` after creating `/mnt/host`.

**View → Show Status Bar** toggles immediately and is saved per VM. **View → Use Entire Display** is borderless edge-to-edge presentation, including the notch strip; toggle it again to restore the window. Standard full screen is also available. With host-aspect matching enabled at boot, full-screen fitting follows the actual viewport and status-bar visibility, preserving the selected width where possible. The guest must honor display reconfiguration.

## Devices → Disks

For the focused running VM, **Mount Disk Image…** connects a RAW image or ISO as virtual USB mass storage on macOS 15+. Read-only is the default. Compressed DMGs require conversion to RAW. Connected images appear as Unmount actions; eject their volumes inside the guest before disconnecting. Images are not deleted or automatically reattached on later boots. The initial Linux installer is controlled by the saved boot option, rather than this runtime device list.

Closing a running console offers Go Headless, Shut Down, Force Stop and Cancel. Shut down guests before quitting the app. Running guests remain independent when you return to the library. VM memory state is not saved. Networking uses NAT; no clipboard or microphone sharing is enabled by default.

## Development checks

The project adopts the workspace's Swift formatting and focused lint baseline. Generated bundles and build products are excluded.

```sh
./scripts/format.sh
./scripts/check.sh
```

Checks include strict swift-format/SwiftLint, legacy migration and backup, registry pruning/relocation, independent settings and session locks, shared installer references/imports, concurrent download deduplication, cancellation and checksum rejection, live vendor-catalog resolution, no-overwrite storage creation, Linux configuration structure and optional hardware validation, input-event preservation, display sizing, an Xcode build, and signature verification. Hardware validation is explicitly skipped when the execution environment reports virtualization unavailable. UI smoke checks use separate temporary app/bundle fixtures, never the existing guest disk.

Sources separate the app/library UI, per-VM session controller, portable bundle/registry storage, native filesystem adapter, Linux configuration, presets, stopped view, and runtime removable-device handling. The app is intentionally not sandboxed; adding App Sandbox requires a separate persistent-access design.

## Experimental Windows ARM

The Windows preset uses 4 CPUs, 8 GiB RAM and a 64 GB sparse NVMe disk. Create/Save obtains
Microsoft's selected-language ARM64 ISO, verifies its checksum and stores it centrally. Tested
VirtIO-Win 0.1.302 ARM64 driver packages ship with the app; no driver ISO download is required. Microsoft's normal download page may require session verification. Local ISOs
remain selectable in Configuration. No further Microsoft download is needed for cached media.

The stock WinPE Setup UI does not take over the virtual display on this backend. Instead, the
bootstrap applies the Windows Pro image (selected by edition metadata), installs ARM64 drivers
and EFI boot files, then boots into Windows' first-run setup. Automatic setup creates the local
account and applies the options chosen on the Mac; manual first-run setup remains available. A fresh empty NVMe disk is required; existing partitioned
disks are refused. Windows licensing remains part of the user's normal setup.

Boot preparation uses persistent generic EFI/NVRAM, runtime-checked PMU/trap emulation, and
separately licensed EFI framebuffer helpers. Windows boots at 1024×768 using virtio graphics,
NAT networking and USB input. Bundled driver folders are injected into WinPE and installed offline.
Only explicitly selected custom driver ISOs attach through virtio block during installation. A shared prepared boot image is cloned per VM
before WinPE edits it; the original installer ISO remains unchanged. WinPE records progress in
`VirtualMac/WinPE.log` on its installer data partition. Deployment success selects startup-disk
boot automatically. The tooling and corresponding third-party sources/licenses are bundled under
`WindowsBootstrap`; see `Vendor/WindowsEFI` and `Vendor/wimlib`.

Windows support remains experimental. No virtual TPM, configurable Secure Boot, shared folders,
or ballooning is supplied. Optional experimental audio uses the bundled test-signed driver package;
see Automatic Windows setup below. Guest compatibility still needs testing for each change.

Temporary GUI probes must include `scripts/HelperAppLifecycle.swift` and call
`HelperAppLifecycle.install(name:)` before showing windows. This supplies Quit/⌘Q and exits
when the last visible window closes. Automated probes should also exit when their work finishes;
close any interactive preview after checking it.

## Live activity

Each VM status bar shows two-minute CPU, host-memory-footprint and physical disk I/O histories,
sampled once per second. 100% CPU means one host core. RAM is the VM service process's physical
footprint, not memory usage reported by the guest. Disk counters are host physical I/O attributed
to that process; cached guest reads can remain zero. A checked private process-identifier lookup
is required; if unavailable the UI says so. Histories reset on stop, restart or counter reset.


## Audio

Audio preferences enable guest playback through the host default output (enabled for existing
and new VMs unless disabled). Changes apply at next VM start. No microphone is exposed.
macOS and Linux guests use a VirtIO sound device; Linux requires a kernel with snd_virtio support.
Windows excludes the unsupported native sound device. Its Remote Desktop configuration tab saves
an address and username and opens an RDP connection in an installed client, with host audio playback
enabled and microphone/clipboard redirection disabled. Enable Remote Desktop inside the Windows
guest separately. No credentials are stored by ElseBox.

Installed Windows VMs keep startup disk/media/driver choices fixed in Configuration. CPU and RAM
have Windows minimums (2 cores, 4 GiB); the proven local display/input configuration stays fixed.
Automatic driver updates no longer trigger a repair boot of an installed guest.

## Automatic Windows setup

New Windows VMs offer a separate setup sheet: installer language/region, local administrator
username, password confirmation, Remote Desktop, and optional experimental audio. English US
is the default; English UK, Dutch, German and French select distinct matching Microsoft media
and cache keys. Existing English US installer cache entries remain reusable. A local ISO must
match the selected language. The user must accept Windows license terms on the Mac before
automatic setup is used. Manual first-run setup remains available.

Setup uses a password-backed local account, with no Microsoft account and no automatic login.
The pending password is stored in login Keychain by VM UUID. A private temporary answer file
is copied only to that VM's working boot disk, never the shared media or saved preferences.
WinPE moves it to Windows Panther and deletes its boot-media copy before shutdown; the host
then deletes the Keychain item. Windows sanitizes cached answers during setup, and a first-login
command removes remaining answer/setup files. File deletion is not a secure-erasure guarantee.

Remote Desktop retains NLA and limits its enabled firewall rules to LocalSubnet. Updates,
Defender and UAC remain enabled. Privacy defaults request Required diagnostic data (the Windows
Pro minimum), disable advertising ID, tailored experiences, activity publishing and location,
and suppress consumer suggestions where Windows supports the relevant policy. They do not
promise that Windows sends no telemetry or that all preinstalled apps are removed.

Experimental audio uses the pinned, BSD-licensed ARM64 viosnd package verified in Windows Audio
Lab. Selecting it enables Windows test-signing and trusts its test certificate inside the new
guest. It is off by default and cannot be enabled by the ordinary installed-VM hardware UI.
See GuestTools/WindowsAudio/Provenance.json for the package/source revision and checksums.
Existing Windows boot profiles and credentials are not changed by this creation workflow.

## Android exploration

Android is a future experimental guest; it is not currently supported or verified in ElseBox.
Start by evaluating ARM64 Linux with Waydroid, including the required Binder kernel support
and software rendering. A longer-term option is a tailored ARM64 Android image booted directly
through Virtualization.framework, using AOSP Cuttlefish as a reference rather than assuming its
images work unchanged with Apple's virtual hardware.

The initial milestone is a usable Android desktop with input, networking and audio. Investigate
accelerated graphics and Google Play availability/licensing separately before promising either.
Keep any prototype in disposable .asvm bundles and leave existing guest boot profiles unchanged.

References: [Waydroid in a VM](https://docs.waydro.id/faq/get-waydroid-to-work-through-a-vm),
[AOSP Cuttlefish](https://source.android.com/docs/devices/cuttlefish/get-started).

## VM library and thumbnails

The library presents OS marks, VM names, configured CPU cores/RAM, logical disk capacity and state
in a resizable, single-column collection sidebar. Selecting a VM shows its details and controls
in the same window. Clicking empty sidebar space clears selection and shows the library overview:
allocated VM-file storage plus the shared installer cache, and combined two-minute CPU, RAM and
physical disk-I/O histories for running VM host processes. Storage is refreshed every 30 seconds;
activity every second. Sparse-file allocation is used, and APFS clone-shared extents may be counted
in more than one file. Unavailable process counters are identified rather than assumed to be zero.
Scrollbars follow macOS settings. The install-media total opens a popover for individual cached
ISO, IPSW and Windows boot-image cleanup. Files referenced by known VMs and files involved in
media preparation are protected. Cleanup moves media to Trash; cache lookup will ignore missing
files and redownload them if needed.
The toolbar's plus icon creates a VM; Open remains available in the File menu. The detail pane's
trash button offers Remove from list, Also delete files (move the bundle to Trash), or Cancel.
Stopped VM details show the last saved screenshot when available.
On macOS 14.4 or later, each visible running VM window is captured after five seconds and every
30 seconds thereafter, using only this app's own windows. The guest viewport is saved as a JPEG
with a 256-pixel longest edge and preserved aspect ratio. `Thumbnail.jpg` in the .asvm bundle is
replaced on each successful capture; no screenshot history is kept. Minimized windows retain
the previous thumbnail. VMs without a saved thumbnail retain their OS artwork.


Shared-media cleanup protects unknown/local imports without an automatic source. Generated Windows
boot media is removable only while its source ISO remains available. Popover actions share a
trailing column and rows highlight on hover. The tested custom audio-driver ISO ships as
`WindowsBootstrap/GuestTools.iso`, outside shared-media accounting and cleanup. A verified obsolete
cache copy is removed at launch only when no known VM references it; the app asset remains intact.
Devices → Disks offers Mount Windows Guest Tools for Windows guests.

Devices → Disks also lists recent successful mounts (up to ten, with their read-only setting).
Dropping ISO/IMG/RAW files onto a running VM mounts them as read-only virtual USB storage; the
mount dialog can request writable access. Runtime USB mounting requires macOS 15 or later.
Windows deployment and macOS installation release their installer references on success; subsequent
Windows disk boots exclude the driver ISO. For Linux, use Eject Installation Media when its
installer requests removal; it disconnects the installer USB and saves startup-disk boot for the
next run. Boot from Startup Disk does the same for a stopped EFI guest. Generic Linux installers
do not expose a common installation-complete notification, so media is not detached speculatively.

The machine detail pane lists connected removable media with per-image eject controls; before a
VM starts, it also shows its configured installer. These controls and Devices → Disks share the
same runtime USB state. Installer ejection persists startup-disk boot and releases shared-media
references. The custom audio image is bundled with the app and excluded from shared-media cleanup.


## Bundled Windows VirtIO drivers

Windows setup uses the tested VirtIO-Win 0.1.302 ARM64 viogpudo (graphics), NetKVM (network) and
viostor (storage) packages in `WindowsBootstrap/VirtIODrivers`. These approximately 2.6 MB of
runtime files are bundled with the app, with upstream license, provenance and per-file SHA-256
checksums; debugging symbols and the full ISO are omitted. WinPE verifies and injects them,
then DISM installs them into Windows. Automatic driver mode makes no driver download and attaches
no driver ISO. Windows installer ISO downloads remain separate. Configuration offers an explicit
custom driver ISO mode when needed. Audio continues to use its existing bundled, tested package.
Run `python3 scripts/check-bundled-drivers.py` to verify the shipped driver binaries and hashes.

## Guest IP addresses and compact activity

The details pane shows discovered IPv4/IPv6 addresses for the running VM, refreshed every five
seconds by passively matching its configured MAC addresses against host DHCP/ARP/NDP records.
No guest agent or network scan is used. Addresses are selectable; stopped VMs show an explicitly
labeled last-known snapshot stored in their bundle. Unavailable addresses are not guessed.
Status bars use a fixed-width right-aligned CPU/RAM/disk icon-and-graph group, with 12-point gaps
between groups. Numeric values remain in tooltips and accessibility labels.

Manual verification (30 October 2026): the full Windows installation with bundled VirtIO drivers
completed successfully. Extended black-screen periods during installation were observed.


RDP provisioning correction (30 October 2026): earlier setup scripts used PowerShell New-Item
-Force for existing registry keys, which can erase their values and subkeys, including the RDP
listener configuration. New provisioning uses a non-destructive CreateSubKey/SetValue adapter,
Windows' native unattended RDP/NLA settings, and first-login service/firewall activation. Setup
transcripts remain under ProgramData/VirtualMac/Logs without account passwords. Answer-file
cleanup runs even if first-login RDP activation fails. Previously provisioned guests require a
fresh installation to validate this correction; no registry reconstruction is attempted.

Headless boot: select a VM in the library and choose **Virtual Machine → Start Headless**
(⌥⌘R). The VM runs without a display window; the library still provides resource
graphs, IP addresses and shutdown controls. **Show VM Window** opens its console
without restarting it. Closing a running VM console offers **Go Headless** by default, alongside
shutdown, force stop and cancel. Headless mode does not change the guest hardware or RDP settings.

The details pane includes a display-only live preview while visible, even when
the VM console is closed. It detaches when the library is hidden or another VM
is selected; it never changes the guest resolution. The last 256-pixel thumbnail
is retained when the VM is stopped. The power control uses the VM’s default startup mode and
requests shutdown when running; IP addresses have individual copy buttons.

Installer downloads run per VM in the background. Settings are saved immediately
and remain editable while media is prepared; completion merges only the media
selection into the latest settings. Power stays disabled until that VM is ready.
A thin progress bar occupies the top boundary of its details pane; hover for
progress, or use its context menu to cancel/retry. Missing automatic installers
resume preparation when the app opens. The details pane respects the unified
titlebar's safe area.

Each VM has a **Startup → Default startup mode** preference: **Always open the
display** (the default, including existing VMs) or **Always start headless**.
The power button and normal Start command follow this preference; the explicit
Start Headless command overrides it for that boot. Showing an already-running
VM never restarts it.

Source layout and dependency boundaries are documented in [ARCHITECTURE.md](ARCHITECTURE.md).

ElseBox is version **0.1.0**, bundle identifier **`nl.theredhead.elsebox`**.
This development build uses a fresh namespace and does not migrate data from
the former VirtualMac app. Existing throwaway data is left untouched.
