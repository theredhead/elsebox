import Foundation

@main
struct WindowsSetupChecks {
    static func main() throws {
        let password = "test<&\"' >密码123"
        let xml = try WindowsAnswerFile.make(username: "test-user", password: password, culture: .dutch)
        let document = try XMLDocument(xmlString: xml, options: [])
        let values = try document.nodes(forXPath: "//*[local-name()='Password']/*[local-name()='Value']")
        precondition(values.count == 1 && values[0].stringValue == password)
        precondition(xml.contains("processorArchitecture=\"arm64\""))
        precondition(xml.contains("<UILanguage>nl-NL</UILanguage>"))
        precondition(xml.contains("<HideOnlineAccountScreens>true</HideOnlineAccountScreens>"))
        precondition(!xml.contains("AutoLogon"))
        precondition(!xml.contains("SkipMachineOOBE"))
        precondition(xml.contains("<ProtectYourPC>3</ProtectYourPC>"))
        precondition(xml.contains("FirstLogonCommands"))
        precondition(xml.contains("C:\\ProgramData\\VirtualMac\\Setup\\Finalize-Windows.ps1"))
        precondition(!xml.contains("cmd.exe /c net user"))
        for name in ["bad&name", "administrator", "..", "name.", "a\\b", ""] {
            do {
                try WindowsAnswerFile.validateUsername(name)
                fatalError("Unsafe name accepted")
            } catch {}
        }
        for unrestrictedPassword in ["", "a", "1234567", "12345678\n", "password\u{0}"] {
            _ = try WindowsAnswerFile.make(
                username: "test", password: unrestrictedPassword, culture: .englishUS)
        }
        precondition(WindowsCulture.englishUS.cacheKey == "windows-11-arm64-english")
        precondition(Set(WindowsCulture.allCases.map { $0.cacheKey }).count == WindowsCulture.allCases.count)
        for culture in WindowsCulture.allCases {
            _ = try XMLDocument(
                xmlString: WindowsAnswerFile.make(username: "tester", password: password, culture: culture),
                options: [])
        }
        let settings = Resources(
            cpu: 4, memory: 8_589_934_592, windowsCulture: "nl-NL", windowsUnattended: true,
            windowsUsername: "tester")
        let saved = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        precondition(!saved.lowercased().contains("password"))
        print(
            "Passed: ARM64 answer files, escaped Unicode credentials, no auto-login, username validation, unrestricted passwords, culture cache isolation, secret-free preferences"
        )
    }
}
