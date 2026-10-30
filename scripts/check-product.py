"""Verify built product metadata after branding/version changes."""
from pathlib import Path
import plistlib
import sys

for name in sys.argv[1:]:
    info = plistlib.loads(Path(name).read_bytes())
    expected = {
        'CFBundleName': 'ElseBox',
        'CFBundleDisplayName': 'ElseBox',
        'CFBundleExecutable': 'ElseBox',
        'CFBundleIdentifier': 'nl.theredhead.elsebox',
        'CFBundleShortVersionString': '0.1.0',
        'CFBundleVersion': '1',
    }
    for key, value in expected.items():
        assert info.get(key) == value, (name, key, info.get(key), value)
    print(f'Passed: ElseBox 0.1.0 product metadata ({name})')
