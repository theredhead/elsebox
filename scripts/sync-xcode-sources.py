"""Synchronize real Xcode source groups/build membership with Sources/, preserving existing file IDs."""
from pathlib import Path
import re

root = Path(__file__).resolve().parent.parent
project = root / "ElseBox.xcodeproj/project.pbxproj"
text = project.read_text()
groups, references, builds = {}, {}, {}
for line in text.splitlines():
    match = re.match(r'\s*(A\w+) = \{isa = PBXGroup; children = \((.*?)\); path = ([^;]+);', line)
    if match:
        groups[match[1]] = (match[3].strip('"'), [item.strip() for item in match[2].split(',') if item.strip()])
    match = re.match(r'\s*(A\w+) = \{isa = PBXFileReference; .*?path = ([^;]+);', line)
    if match:
        references[match[1]] = match[2].strip('"')
    match = re.match(r'\s*(A\w+) = \{isa = PBXBuildFile; fileRef = (A\w+);', line)
    if match:
        builds[match[2]] = match[1]

source_group = next(key for key, value in groups.items() if value[0] == 'Sources')
old_groups, old_files = {}, {}
def walk(key, parent):
    if key in groups:
        folder, children = groups[key]
        path = parent / folder
        old_groups[str(path)] = key
        for child in children:
            walk(child, path)
    else:
        old_files[references[key]] = key
walk(source_group, Path())

next_id = max(int(value[1:], 16) for value in re.findall(r'\bA[0-9A-F]{23}\b', text)) + 1
def allocate():
    global next_id
    result = 'A' + f'{next_id:023X}'
    next_id += 1
    return result

sources = sorted((root / 'Sources').rglob('*.swift'))
assert len({path.name for path in sources}) == len(sources), 'Swift basenames must be unique'
paths = [str(path.relative_to(root)) for path in sources]
folders = sorted({str(parent) for path in paths for parent in Path(path).parents if str(parent) != '.'})
folder_ids = {folder: old_groups.get(folder) or allocate() for folder in folders}
file_ids, build_ids, additions = {}, [], []
for path in paths:
    name = Path(path).name
    reference = old_files.get(name)
    if reference is None:
        reference = allocate()
        build = allocate()
        additions += [f'  {reference} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>";}};',
                      f'  {build} = {{isa = PBXBuildFile; fileRef = {reference};}};']
    else:
        build = builds[reference]
    file_ids[path] = reference
    build_ids.append(build)

def children(folder):
    result = [(Path(path).name, key) for path, key in folder_ids.items() if str(Path(path).parent) == folder]
    result += [(Path(path).name, key) for path, key in file_ids.items() if str(Path(path).parent) == folder]
    return ', '.join(key for _, key in sorted(result))

removed = set(old_groups.values())
for name, key in old_files.items():
    if name not in {path.name for path in sources}:
        removed.update([key, builds[key]])
text = '\n'.join(line for line in text.splitlines()
                 if not any(re.match(r'\s*' + key + r' = ', line) for key in removed)) + '\n'
for folder, key in folder_ids.items():
    additions.append(f'  {key} = {{isa = PBXGroup; children = ({children(folder)}); path = {Path(folder).name}; sourceTree = "<group>";}};')
text = re.sub(r'(isa = PBXSourcesBuildPhase; .*?files = )\([^\n]*?\)',
              lambda match: match[1] + '(' + ', '.join(build_ids) + ')', text)
text = text.replace('objects = {', 'objects = {\n' + '\n'.join(additions), 1)
project.write_text(text)
print(f'Synchronized {len(sources)} Swift sources and {len(folder_ids)} real Xcode groups')
