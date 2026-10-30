"""Keep domain code host-independent and Xcode's real groups aligned with disk."""
from pathlib import Path
import re

root = Path(__file__).resolve().parent.parent
for source in (root / "Sources/Domain").rglob("*.swift"):
    imports = re.findall(r"^import (\w+)", source.read_text(), re.M)
    assert set(imports) <= {"Foundation"}, (source, imports)

project = (root / "VirtualMac.xcodeproj/project.pbxproj").read_text()
groups = {}
references = {}
for line in project.splitlines():
    group = re.match(r'\s*(A\w+) = \{isa = PBXGroup; children = \((.*?)\); path = ([^;]+);', line)
    if group:
        groups[group[1]] = (group[3].strip('"'), [part.strip() for part in group[2].split(",") if part.strip()])
    reference = re.match(r'\s*(A\w+) = \{isa = PBXFileReference; .*?path = ([^;]+);', line)
    if reference:
        references[reference[1]] = reference[2].strip('"')

source_group = next(key for key, value in groups.items() if value[0] == "Sources")
resolved = {}
def walk(key, parent):
    if key in groups:
        folder, children = groups[key]
        for child in children:
            walk(child, parent / folder)
    else:
        resolved[key] = parent / references[key]
walk(source_group, root)
actual = set((root / "Sources").rglob("*.swift"))
assert set(resolved.values()) == actual, "Xcode groups differ from the source tree"
assert len(resolved) == len(actual), "Duplicate Xcode source references"
build_files = dict(re.findall(r'(A\w+) = \{isa = PBXBuildFile; fileRef = (A\w+);', project))
phase = re.search(r'isa = PBXSourcesBuildPhase; .*?files = \((.*?)\);', project)[1]
built = [resolved[build_files[key.strip()]] for key in phase.split(",") if key.strip()]
assert set(built) == actual and len(built) == len(actual), "Xcode build sources differ from disk"
print("Passed: Foundation-only domain and complete, unique Xcode groups/build membership")
