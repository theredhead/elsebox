# Code organization

The source tree and Xcode groups use the same physical folders. All Swift source
files belong to both builds; `build.sh` discovers them recursively. The check
script verifies Xcode membership against the filesystem.

| Folder | Responsibility |
| --- | --- |
| `Sources/Domain` | Codable settings and manifests, guest presets, Windows answer-file rules, display geometry and activity calculations. Foundation only; no windows, hardware handles, Keychain or file access. |
| `Sources/Application` | Main-actor app/session orchestration, per-VM download coordination and network monitoring. Owns operation state and wires native adapters to presentation callbacks. |
| `Sources/Platform` | Storage formats, file leases, Keychain, installer transport/catalog resolution, native virtualization configuration, host network/process probes and screenshot capture. |
| `Sources/Presentation` | AppKit library/console windows, preference and creation sheets, and reusable display/input components. |
| `Resources/WindowsBootstrap` | Guest deployment scripts, pinned driver assets and their provenance. |
| `Tests` | Focused executable checks; fixtures use temporary bundles and injected transports. |

Keep domain rules independent of AppKit and Virtualization. Native C/Objective-C
calls stay private to focused adapters; consumers use Swift values and errors.
Application controllers can depend on presentation and platform types: this is a
single AppKit executable, not a framework with a dependency-injection container.
Add interfaces when there is a real substitution or testing requirement, rather
than making one protocol per concrete class.

MacVMConfiguration owns macOS identity preparation and virtual hardware;
EFIVMConfiguration owns Linux/Windows EFI hardware. VMResourceLimits is shared by
the macOS factory and preferences. VMSessionController binds console intent to VMExecutionController, which owns
hardware lifetime and the exclusive lease. VMBootCoordinator prepares one boot;
VMConsoleController, VMConsoleContentView and VMWindowPresentation own the window
and presentation lifecycle. VMDisplayFitter owns native display resize timing.

InstallerPreparation owns per-VM background jobs and merges completed media into
the latest saved VMSettings. InstallerMediaService resolves/downloads/verifies
media through an injected transport. Neither job completion nor moving source
files changes the `Resources.json` format or an existing VM's identity.

WindowsCulture and WindowsAnswerFile are domain rules. WindowsSetupSecret is the
Keychain adapter. NewVMController owns the create sheets and returns a bundle;
AppController registers it, selects it, and starts background preparation.

VMNetworkSnapshot is data. VMNetworkAddressParser interprets host records,
VMNetworkAddressSource owns passive host probing, VMNetworkSnapshotStore owns
JSON persistence, and VMNetworkMonitor coordinates polling and last-known state.

PreferencesEditor composes hardware, behavior, storage and shared-folder pages.
VMDetailsView composes a header, progress bar and independent media/network lists.
ApplicationMenus owns menu construction; VMSessionRegistry owns independent
sessions and projects their state to the library. Reusable resolution, shared-folder,
power-button and display-preview views have their own files. The old floating installer progress window has been removed;
progress is rendered by the selected VM details pane.

Run `./scripts/check.sh` for architecture checks, strict format/lint, regression
checks and the Xcode build. Run `./build.sh` for the standalone app. Runtime guest
verification remains separate from source organization; refactoring must not
silently change working Windows boot hardware or provisioning.

Every class has a purpose/ownership comment. Declaration whitespace and comment
presence are checked by `scripts/check-readability.py`; prose quality and class
cohesion still require review. Around 200 code lines is a review signal, not a
quota. See AGENTS.md for the project-specific readability rules.

After source-tree changes, run `python3 scripts/sync-xcode-sources.py` to update
real Xcode groups without replacing existing file identities. The architecture
check rejects missing, duplicate or incorrectly grouped source files.

The default preference checks do not open windows. The optional
`build/PreferencesChecks --native-ui` smoke test constructs offscreen library and
console windows and exercises native menu routing; run it with normal macOS
service access, outside a restrictive sandbox. It never starts a guest.
