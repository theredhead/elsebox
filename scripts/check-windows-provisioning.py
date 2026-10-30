"""Reject registry-key replacement: it can destroy Windows' built-in RDP listener."""
from pathlib import Path
import re

root = Path(__file__).resolve().parent.parent / "Resources/WindowsBootstrap"
for script in root.glob("*.ps1"):
    for line in script.read_text().splitlines():
        if re.search(r"\bNew-Item(?![-\w])", line, re.I) and re.search(r"-Force\b", line, re.I):
            assert re.search(r"-ItemType\s+(Directory|File)\b", line, re.I), (script.name, line)
helper = (root / "RegistryPolicy.ps1").read_text()
assert "CreateSubKey" in helper and ".SetValue(" in helper and ".Dispose()" in helper
for name in ("Prepare-Windows.ps1", "Finalize-Windows.ps1"):
    assert "RegistryPolicy.ps1" in (root / name).read_text(), name
print("Passed: no destructive forced registry-key creation; setup and finalization share the safe registry adapter")
