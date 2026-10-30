"""Check class purpose comments and whitespace between Swift members; --fix inserts missing whitespace only."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parent.parent
fix = '--fix' in sys.argv
errors = []
method = re.compile(r'^\s*(?:(?:@objc|private|public|internal|fileprivate|override|static|class|final|required|convenience|mutating)\s+)*(func|init|deinit)\b')
nominal = re.compile(r'^\s*(?:(?:private|public|internal|fileprivate|final)\s+)*class\s+(?!var\b|func\b)(\w+)\b')
property_member = re.compile(r'^\s*(?:(?:private|public|internal|fileprivate|override|static|class|final|lazy|weak)\s+)*(let|var)\s+')
for source in sorted((root / 'Sources').rglob('*.swift')):
    lines = source.read_text().splitlines()
    insertions = set()
    for index, line in enumerate(lines):
        match = nominal.match(line)
        if match:
            previous = index - 1
            while previous >= 0 and lines[previous].lstrip().startswith('@'):
                previous -= 1
            if previous < 0 or not lines[previous].lstrip().startswith('///'):
                errors.append(f'{source.relative_to(root)}:{index + 1}: {match[1]} needs a purpose doc comment')
        is_computed = property_member.match(line) and '{' in line and '=' not in line.split('{', 1)[0]
        after_block = property_member.match(line) and index > 0 and lines[index - 1].rstrip().endswith('}')
        if method.match(line) or is_computed or after_block or match:
            anchor = index
            while anchor > 0 and lines[anchor - 1].lstrip().startswith(('///', '@')):
                anchor -= 1
            if anchor > 0 and lines[anchor - 1].strip() and not lines[anchor - 1].rstrip().endswith('{'):
                insertions.add(anchor)
    if insertions and fix:
        source.write_text('\n'.join(('\n' if index in insertions else '') + line for index, line in enumerate(lines)) + '\n')
    elif insertions:
        errors.extend(f'{source.relative_to(root)}:{index + 1}: separate declarations with a blank line' for index in sorted(insertions))
if errors:
    print('\n'.join(errors))
    sys.exit(1)
print('Passed: class purpose comments and declaration whitespace (class size remains a review judgment)')
