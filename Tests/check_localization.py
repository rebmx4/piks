"""Validate RU/EN resource syntax and coverage without requiring Xcode."""
import json
from pathlib import Path
import plistlib
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
ASSIGNMENT = re.compile(r'\s*("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*")\s*;\s*')


def read_strings(path):
    source = re.sub(r'/\*.*?\*/', '', path.read_text(encoding='utf-8'), flags=re.S)
    values = {}
    for line in source.splitlines():
        if not line.strip():
            continue
        match = ASSIGNMENT.fullmatch(line)
        assert match, (path, 'invalid strings syntax', line)
        key, value = map(json.loads, match.groups())
        assert key not in values, (path, 'duplicate key', key)
        assert key.count('%@') == value.count('%@'), (path, 'format placeholders', key)
        values[key] = value
    return values


def check_target(target):
    root = ROOT / target
    info = plistlib.loads((root / 'Info.plist').read_bytes())
    assert info['CFBundleDevelopmentRegion'] == 'en'
    assert info['CFBundleLocalizations'] == ['ru', 'en']
    ru = read_strings(root / 'ru.lproj/Localizable.strings')
    en = read_strings(root / 'en.lproj/Localizable.strings')
    assert ru.keys() == en.keys(), (target, 'RU/EN key coverage')
    source = '\n'.join(file.read_text(encoding='utf-8') for file in root.glob('*.swift'))
    used = {json.loads('"' + key + '"') for key in
            re.findall(r'NSLocalizedString\("((?:[^"\\]|\\.)*)"', source)}
    assert used == en.keys(), (target, 'native labels missing translations', used ^ en.keys())
    if target == 'App':
        prompts = {'NSCameraUsageDescription', 'NSMicrophoneUsageDescription',
                   'NSPhotoLibraryUsageDescription', 'NSPhotoLibraryAddUsageDescription'}
        for lang in ['ru', 'en']:
            labels = read_strings(root / (lang + '.lproj/InfoPlist.strings'))
            assert prompts <= labels.keys(), (lang, 'permission prompt coverage')
            assert labels['CFBundleDisplayName'] == info['CFBundleDisplayName']
        ET.parse(root / 'Base.lproj/LaunchScreen.storyboard')
    print(target + ': plist, RU/EN keys, placeholders and permission prompts OK')


if __name__ == '__main__':
    check_target('App')
    check_target('ShareExtension')
