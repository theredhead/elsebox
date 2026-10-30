"""Verify the actual shipped driver bytes, not just installer orchestration fixtures."""
from pathlib import Path
import hashlib
import json
import struct

root = Path(__file__).resolve().parent.parent / "Resources/WindowsBootstrap/VirtIODrivers"
provenance = json.loads((root / "Provenance.json").read_text())
for name, expected in provenance["files"].items():
    data = (root / name).read_bytes()
    assert data and hashlib.sha256(data).hexdigest() == expected, name
    if name.endswith((".sys", ".exe")):
        assert data[:2] == b"MZ", name
        offset = struct.unpack_from("<I", data, 0x3C)[0]
        assert data[offset:offset + 4] == b"PE\0\0", name
        assert struct.unpack_from("<H", data, offset + 4)[0] == 0xAA64, name
for folder in ("viogpudo", "NetKVM", "viostor"):
    assert list((root / folder).glob("*.inf")) and list((root / folder).glob("*.cat")), folder
assert "PCI\\VEN_1AF4&DEV_1050" in (root / "viogpudo/viogpudo.inf").read_text()
print("Passed: bundled VirtIO driver checksums, ARM64 binaries, INF/catalog packages and Apple GPU match")
