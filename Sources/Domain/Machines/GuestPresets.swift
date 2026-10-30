import Foundation

enum GuestDistribution: String, Codable, CaseIterable {
    case macOS
    case debian
    case ubuntu
    case fedora
    case arch
    case windows
    case customLinux

    var title: String {
        switch self {
        case .macOS: return "macOS"
        case .debian: return "Debian"
        case .ubuntu: return "Ubuntu"
        case .fedora: return "Fedora"
        case .arch: return "Arch Linux ARM"
        case .windows: return "Windows 11 ARM (experimental)"
        case .customLinux: return "Linux"
        }
    }

    var usesEFI: Bool { return self != .macOS }

    var isLinux: Bool { return usesEFI && self != .windows }

    var hasAutomaticInstaller: Bool { return self != .arch && self != .customLinux }

    var installerSelectionTitle: String {
        if self == .macOS { return "Choose macOS Restore Image (.ipsw)" }
        if self == .windows { return "Choose Windows 11 ARM64 Installer (.iso)" }
        return "Choose \(title) ARM64 Installer (.iso)"
    }

    var installerSelectionMessage: String {
        if self == .macOS {
            return "Select a macOS restore image (.ipsw) for Apple silicon."
        }
        if self == .windows {
            return
                "Select the Windows 11 Arm64 installer ISO downloaded from Microsoft (for example, Win11_…_Arm64.iso). Choose the Windows installer here; VirtIO drivers are configured separately."
        }
        return "Select a bootable \(title) installer ISO for ARM64 / AArch64."
    }

    func downloadURL(role: GuestRole) -> URL? {
        let address: String
        switch self {
        case .macOS, .customLinux: return nil
        case .debian: address = "https://www.debian.org/CD/netinst/"
        case .ubuntu:
            address =
                role == .desktop
                ? "https://ubuntu.com/download/desktop" : "https://ubuntu.com/download/server/arm"
        case .fedora:
            address =
                role == .desktop
                ? "https://fedoraproject.org/workstation/download"
                : "https://fedoraproject.org/server/download"
        case .windows: address = "https://www.microsoft.com/software-download/windows11arm64"
        case .arch: address = "https://archlinuxarm.org/platforms/armv8/generic"
        }
        return URL(string: address)
    }
}

enum GuestRole: String, Codable, CaseIterable {
    case minimal
    case server
    case desktop

    var title: String {
        switch self {
        case .minimal: return "Minimal / CLI"
        case .server: return "Server"
        case .desktop: return "Desktop"
        }
    }
}

struct VMStarterPreset {
    var distribution: GuestDistribution
    var role: GuestRole

    static var macOS: VMStarterPreset { return VMStarterPreset(distribution: .macOS, role: .desktop) }

    var cpu: Int { return role == .desktop ? 4 : 2 }

    var memoryGiB: Int {
        if distribution == .macOS { return 4 }
        switch role {
        case .minimal: return distribution == .arch ? 4 : 2
        case .server: return 4
        case .desktop: return 8
        }
    }

    var diskGB: Int {
        if distribution == .macOS { return 50 }
        switch role {
        case .minimal: return 16
        case .server: return 32
        case .desktop: return 64
        }
    }

    var title: String { return distribution == .macOS ? "macOS" : "\(distribution.title) — \(role.title)" }
}
