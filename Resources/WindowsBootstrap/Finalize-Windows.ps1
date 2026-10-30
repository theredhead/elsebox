$ErrorActionPreference = 'Stop'
foreach ($path in @("$env:WINDIR\Panther\unattend.xml", "$env:WINDIR\Panther\Unattend\unattend.xml")) {
    if (Test-Path $path) { Remove-Item -LiteralPath $path -Force }
}
New-Item -Path 'C:\ProgramData\VirtualMac\Provisioned' -ItemType File -Force | Out-Null
Remove-Item -LiteralPath $PSScriptRoot -Recurse -Force
