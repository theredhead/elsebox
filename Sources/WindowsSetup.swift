import Foundation
import Security

/// Cultures with matching Microsoft ARM64 installation media.
enum WindowsCulture: String, CaseIterable {
    case englishUS = "en-US"
    case englishUK = "en-GB"
    case dutch = "nl-NL"
    case german = "de-DE"
    case french = "fr-FR"

    var title: String {
        switch self {
        case .englishUS: return "English (United States)"
        case .englishUK: return "English (United Kingdom)"
        case .dutch: return "Nederlands (Nederland)"
        case .german: return "Deutsch (Deutschland)"
        case .french: return "Français (France)"
        }
    }

    var microsoftLanguage: String {
        switch self {
        case .englishUS: return "English"
        case .englishUK: return "English International"
        case .dutch: return "Dutch"
        case .german: return "German"
        case .french: return "French"
        }
    }

    var cacheKey: String {
        self == .englishUS ? "windows-11-arm64-english" : "windows-11-arm64-\(rawValue.lowercased())"
    }
}

/// Passwords live in the login Keychain until WinPE has deployed the answer file.
enum WindowsSetupSecret {
    private static let service = "nl.theredhead.virtualmac.windows-setup"

    static func save(_ password: String, for id: UUID) throws {
        let query = key(id)
        let value = Data(password.utf8)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData: value] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw error(updated) }
        var item = query
        item[kSecValueData] = value
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw error(status) }
    }

    static func read(for id: UUID) throws -> String {
        var query = key(id)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
            let password = String(data: data, encoding: .utf8)
        else { throw settingsError("The Windows setup password is unavailable in Keychain.") }
        return password
    }

    static func remove(for id: UUID) throws {
        let status = SecItemDelete(key(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
    }

    private static func key(_ id: UUID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id.uuidString]
    }

    private static func error(_ status: OSStatus) -> NSError {
        settingsError("Could not access the Windows setup password in Keychain (\(status)).")
    }
}

/// Builds an ARM64 answer file without embedding credentials in commands or preferences.
enum WindowsAnswerFile {
    static func validateUsername(_ username: String) throws {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard (1...20).contains(username.count), username.unicodeScalars.allSatisfy({ allowed.contains($0) }),
            !["administrator", "guest", "defaultaccount", "wdagutilityaccount"].contains(
                username.lowercased()),
            username != ".", username != "..", !username.hasSuffix(".")
        else {
            throw settingsError(
                "Use a local username of 1–20 letters, numbers, dots, hyphens or underscores.")
        }
    }

    static func make(username: String, password: String, culture: WindowsCulture, enableRDP: Bool = false)
        throws -> String
    {
        try validateUsername(username)
        let remoteDesktop =
            enableRDP
            ? """
            <component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><fDenyTSConnections>false</fDenyTSConnections></component>
            <component name="Microsoft-Windows-TerminalServices-RDP-WinStationExtensions" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><UserAuthentication>1</UserAuthentication></component>
            """ : ""
        return """
            <?xml version="1.0" encoding="utf-8"?>
            <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
              <settings pass="specialize">
                \(remoteDesktop)
                <component name="Microsoft-Windows-Deployment" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
                  <RunSynchronous><RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\ProgramData\\VirtualMac\\Setup\\Prepare-Windows.ps1</Path></RunSynchronousCommand></RunSynchronous>
                </component>
              </settings>
              <settings pass="oobeSystem">
                <component name="Microsoft-Windows-International-Core" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
                  <InputLocale>\(culture.rawValue)</InputLocale><SystemLocale>\(culture.rawValue)</SystemLocale><UILanguage>\(culture.rawValue)</UILanguage><UserLocale>\(culture.rawValue)</UserLocale>
                </component>
                <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
                  <OOBE><HideEULAPage>true</HideEULAPage><HideOEMRegistrationScreen>true</HideOEMRegistrationScreen><HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE><ProtectYourPC>3</ProtectYourPC></OOBE>
                  <FirstLogonCommands><SynchronousCommand wcm:action="add"><Order>1</Order><CommandLine>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\ProgramData\\VirtualMac\\Setup\\Finalize-Windows.ps1</CommandLine><Description>Remove temporary setup files</Description></SynchronousCommand></FirstLogonCommands>
                  <UserAccounts><LocalAccounts><LocalAccount wcm:action="add"><Name>\(xml(username))</Name><DisplayName>\(xml(username))</DisplayName><Group>Administrators</Group><Password><Value>\(xml(password))</Value><PlainText>true</PlainText></Password></LocalAccount></LocalAccounts></UserAccounts>
                </component>
              </settings>
            </unattend>
            """
    }

    private static func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
