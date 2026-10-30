import Foundation

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
