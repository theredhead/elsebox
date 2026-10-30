$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$options = Get-Content (Join-Path $root 'Options.json') -Raw | ConvertFrom-Json
. (Join-Path $root 'RegistryPolicy.ps1')
$logs = Join-Path $env:ProgramData 'VirtualMac\Logs'
New-Item -Path $logs -ItemType Directory -Force | Out-Null
Start-Transcript -Path (Join-Path $logs 'Provisioning.log') -Append | Out-Null
try {
# Windows Pro supports Required diagnostic data; do not claim the Enterprise-only zero level.
Set-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 1
Set-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 1
Set-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1
Set-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableTailoredExperiencesWithDiagnosticData' 1
Set-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
Set-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0
Set-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0
Set-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 0
Set-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors' 'DisableLocation' 1
Set-Policy 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE' 'DisablePrivacyExperience' 1
if ($options.enableRDP) {
    Set-Policy 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections' 0
    Set-Policy 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' 'UserAuthentication' 1
    foreach ($name in @('RemoteDesktop-UserMode-In-TCP', 'RemoteDesktop-UserMode-In-UDP')) {
        Set-NetFirewallRule -Name $name -Enabled True -Profile Any -RemoteAddress LocalSubnet
    }
}
if ($options.enableAudio) {
    $manifest = Get-Content (Join-Path $root 'Provenance.json') -Raw | ConvertFrom-Json
    foreach ($entry in $manifest.files.PSObject.Properties) {
        if ((Get-FileHash (Join-Path $root $entry.Name) -Algorithm SHA256).Hash -ne $entry.Value) {
            throw "Driver checksum mismatch: $($entry.Name)"
        }
    }
    $certificate = Join-Path $root 'DroidVM_Test.cer'
    $hash = (Get-FileHash $certificate -Algorithm SHA256).Hash
    if ($hash -ne 'DA88F450DBD881C91511C5B801295CD9CC0D3CA84EA9D3DC08EFF9481EED64B3') {
        throw 'Unexpected audio test certificate.'
    }
    foreach ($store in @('Cert:\LocalMachine\Root','Cert:\LocalMachine\TrustedPublisher')) {
        Import-Certificate -FilePath $certificate -CertStoreLocation $store | Out-Null
    }
    & pnputil.exe /add-driver (Join-Path $root 'viosnd.inf') /install
    if ($LASTEXITCODE -notin @(0,3010)) { throw "Audio driver installation failed: $LASTEXITCODE" }
}

} finally {
    Stop-Transcript | Out-Null
}
