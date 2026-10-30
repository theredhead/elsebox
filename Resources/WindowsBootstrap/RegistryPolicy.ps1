# CreateSubKey opens existing keys without replacing their values or subkeys.
function Set-Policy([string]$Path, [string]$Name, [int]$Value) {
    if (-not $Path.StartsWith('HKLM:\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Only machine registry policy paths are supported.'
    }
    $key = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($Path.Substring(6))
    try {
        $key.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]::DWord)
    } finally {
        $key.Dispose()
    }
}
