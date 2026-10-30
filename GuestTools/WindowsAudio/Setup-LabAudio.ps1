param([ValidateSet('Prepare','Install','Remove')][string]$Stage = 'Prepare')
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script in an elevated PowerShell window in Windows Audio Lab.'
}
$package = Join-Path $PSScriptRoot 'viosnd'
$manifest = Get-Content (Join-Path $PSScriptRoot 'Provenance.json') -Raw | ConvertFrom-Json
foreach ($entry in $manifest.files.PSObject.Properties) {
    $actual = (Get-FileHash (Join-Path $package $entry.Name) -Algorithm SHA256).Hash
    if ($actual -ne $entry.Value) { throw "Driver checksum mismatch: $($entry.Name)" }
}
$cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2(
    (Join-Path $PSScriptRoot 'DroidVM_Test.cer'))
$sha = [Security.Cryptography.SHA256]::Create()
$certHash = ([BitConverter]::ToString($sha.ComputeHash($cert.RawData))).Replace('-','')
$sha.Dispose()
if ($certHash -ne 'DA88F450DBD881C91511C5B801295CD9CC0D3CA84EA9D3DC08EFF9481EED64B3') {
    throw 'Unexpected test certificate.'
}
if ($Stage -eq 'Prepare') {
    foreach ($store in @('Cert:\LocalMachine\Root','Cert:\LocalMachine\TrustedPublisher')) {
        Import-Certificate -FilePath (Join-Path $PSScriptRoot 'DroidVM_Test.cer') -CertStoreLocation $store | Out-Null
    }
    & bcdedit.exe /set testsigning on
    if ($LASTEXITCODE -ne 0) { throw 'Windows refused test-signing mode. No other security settings were changed.' }
    Write-Host 'Restart the lab VM, then run Install.cmd.'
} elseif ($Stage -eq 'Install') {
    & pnputil.exe /add-driver (Join-Path $package 'viosnd.inf') /install
    if ($LASTEXITCODE -notin @(0,3010)) { throw "Driver installation failed: $LASTEXITCODE" }
    Get-PnpDevice -Class Media -ErrorAction SilentlyContinue | Format-Table Status,FriendlyName,InstanceId -AutoSize
    Write-Host 'Driver staged. Shut down the lab so its experimental audio device can be enabled.'
} else {
    $drivers = Get-WindowsDriver -Online | Where-Object { $_.OriginalFileName -match '\\viosnd\.inf$' }
    foreach ($driver in $drivers) {
        & pnputil.exe /delete-driver $driver.Driver /uninstall
        if ($LASTEXITCODE -notin @(0,3010)) { throw 'Driver removal failed; test-signing stays enabled.' }
    }
    foreach ($store in @('Cert:\LocalMachine\Root','Cert:\LocalMachine\TrustedPublisher')) {
        $path = Join-Path $store $cert.Thumbprint
        if (Test-Path $path) { Remove-Item $path }
    }
    & bcdedit.exe /set testsigning off
    if ($LASTEXITCODE -ne 0) { throw 'Could not turn test-signing off.' }
    Write-Host 'Restart the lab VM to finish removal.'
}
