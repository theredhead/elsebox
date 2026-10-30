import Foundation

struct InstallerImage: Codable {
    let url: URL
    let sha256: String
}

/// Resolves current ARM64 installation media from publisher pages and checksum manifests.
struct InstallerCatalog {
    let fetch: (URL) async throws -> Data

    func resolve(_ preset: VMStarterPreset) async throws -> InstallerImage {
        switch preset.distribution {
        case .debian:
            let base = URL(string: "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/")!
            return try Self.selectChecksums(
                String(decoding: await fetch(base.appendingPathComponent("SHA256SUMS")), as: UTF8.self),
                base: base
            ) {
                $0.hasPrefix("debian-") && $0.hasSuffix("-arm64-netinst.iso")
            }
        case .ubuntu:
            let page = preset.distribution.downloadURL(role: preset.role)!
            let html = String(decoding: try await fetch(page), as: UTF8.self)
            let landing = try Self.ubuntuLandingPage(html: html, base: page)
            let landingHTML = String(decoding: try await fetch(landing), as: UTF8.self)
            let suffix = preset.role == .desktop ? "-desktop-arm64.iso" : "-live-server-arm64.iso"
            guard
                let iso = Self.links(in: landingHTML, base: landing).first(where: {
                    $0.lastPathComponent.hasSuffix(suffix) && $0.host == "cdimage.ubuntu.com"
                })
            else { throw settingsError("Ubuntu did not publish a matching ARM64 ISO link.") }

            let base = iso.deletingLastPathComponent()
            let sums = String(
                decoding: try await fetch(base.appendingPathComponent("SHA256SUMS")), as: UTF8.self)
            return try Self.selectChecksums(sums, base: base) { $0 == iso.lastPathComponent }
        case .fedora:
            let page = preset.distribution.downloadURL(role: preset.role)!
            let html = String(decoding: try await fetch(page), as: UTF8.self)
            let checksum = try Self.fedoraChecksumURL(html: html, base: page, role: preset.role)
            let sums = String(decoding: try await fetch(checksum), as: UTF8.self)
            return try Self.selectChecksums(sums, base: checksum.deletingLastPathComponent()) {
                let filename = $0.lowercased()
                guard filename.contains("aarch64"), filename.hasSuffix(".iso") else { return false }
                if preset.role == .desktop { return filename.contains("workstation-live") }
                if preset.role == .minimal { return filename.contains("server-netinst") }
                return filename.contains("server-dvd")
            }
        case .macOS, .arch, .customLinux, .windows:
            throw settingsError("Select local installation media for this guest.")
        }
    }

    static func links(in html: String, base: URL) -> [URL] {
        let pattern = #"href\s*=\s*["']([^"']+)["']"#
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let string = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: string.length)).compactMap {
            let href = string.substring(with: $0.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
            guard let url = URL(string: href, relativeTo: base)?.absoluteURL, url.scheme == "https" else {
                return nil
            }
            return url
        }
    }

    static func ubuntuLandingPage(html: String, base: URL) throws -> URL {
        let candidates = links(in: html, base: base).filter { url in
            guard url.host == "ubuntu.com", url.path.contains("/thank-you"),
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else { return false }
            return components.queryItems?.contains(where: { $0.name == "architecture" && $0.value == "arm64" }
            ) == true
        }
        guard
            let chosen = candidates.first(where: {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: {
                    $0.name == "lts" && $0.value == "true"
                }) == true
            }) ?? candidates.first
        else { throw settingsError("Ubuntu did not publish an ARM64 release link.") }
        return chosen
    }

    static func fedoraChecksumURL(html: String, base: URL, role: GuestRole) throws -> URL {
        let variant = role == .desktop ? "/Workstation/" : "/Server/"
        let candidates = links(in: html, base: base).filter {
            $0.host == "dl.fedoraproject.org" && $0.path.contains("/pub/fedora/linux/releases/")
                && !$0.path.contains("/test/") && $0.path.contains(variant)
                && $0.path.contains("/aarch64/iso/") && $0.lastPathComponent.hasSuffix("aarch64-CHECKSUM")
        }
        guard
            let chosen = candidates.sorted(by: {
                $0.path.compare($1.path, options: .numeric) == .orderedDescending
            }).first
        else {
            throw settingsError("Fedora did not publish a matching ARM64 checksum manifest.")
        }
        return chosen
    }

    static func selectChecksums(_ text: String, base: URL, matches: (String) -> Bool) throws -> InstallerImage
    {
        let gnu = try! NSRegularExpression(pattern: #"^([0-9a-fA-F]{64})\s+\*?([^\r\n]+?)\s*$"#)
        let bsd = try! NSRegularExpression(pattern: #"^SHA256\s*\(([^)]+)\)\s*=\s*([0-9a-fA-F]{64})\s*$"#)
        var images: [InstallerImage] = []
        for line in text.components(separatedBy: .newlines) {
            let string = line as NSString
            let range = NSRange(location: 0, length: string.length)
            let filename: String
            let hash: String
            if let match = gnu.firstMatch(in: line, range: range) {
                hash = string.substring(with: match.range(at: 1))
                filename = string.substring(with: match.range(at: 2))
            } else if let match = bsd.firstMatch(in: line, range: range) {
                filename = string.substring(with: match.range(at: 1))
                hash = string.substring(with: match.range(at: 2))
            } else {
                continue
            }
            guard !filename.contains("/"), !filename.contains("\\"), matches(filename) else { continue }
            images.append(
                InstallerImage(url: base.appendingPathComponent(filename), sha256: hash.lowercased()))
        }
        guard
            let chosen = images.sorted(by: {
                $0.url.lastPathComponent.compare($1.url.lastPathComponent, options: .numeric)
                    == .orderedDescending
            }).first
        else {
            throw settingsError("No matching ARM64 ISO was found in the publisher’s checksum manifest.")
        }
        return chosen
    }
}
