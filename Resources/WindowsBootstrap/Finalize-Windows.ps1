$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'RegistryPolicy.ps1')
$options = Get-Content (Join-Path $PSScriptRoot 'Options.json') -Raw | ConvertFrom-Json
try {
if ($options.enableRDP) {
    Set-Policy 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections' 0
    Set-Policy 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' 'UserAuthentication' 1
    foreach ($name in @('RemoteDesktop-UserMode-In-TCP', 'RemoteDesktop-UserMode-In-UDP')) {
        Set-NetFirewallRule -Name $name -Enabled True -Profile Any -RemoteAddress LocalSubnet
    }
    Start-Service -Name TermService
}
} finally {
foreach ($path in @("$env:WINDIR\Panther\unattend.xml", "$env:WINDIR\Panther\Unattend\unattend.xml")) {
    if (Test-Path $path) { Remove-Item -LiteralPath $path -Force }
}
}
New-Item -Path 'C:\ProgramData\VirtualMac\Provisioned' -ItemType File -Force | Out-Null
Remove-Item -LiteralPath $PSScriptRoot -Recurse -Force
