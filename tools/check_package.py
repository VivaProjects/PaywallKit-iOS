#!/usr/bin/env python3
"""Check that this SDK can be shipped without a parent or sibling repository."""
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
IGNORED = {'.git', '.build', '.swiftpm', '.dart_tool', 'build', '__pycache__'}
IOS = (ROOT / 'Package.swift').exists()
RESOURCES = ROOT / ('Sources/PaywallKit/Resources' if IOS else 'assets')


def main():
    for name, source in [('paywall.schema.json', 'protocol/paywall.schema.json'),
                         ('component-catalog.json', 'protocol/component-catalog.json'),
                         ('onboarding.json', 'protocol/examples/onboarding.json')]:
        assert json.loads((RESOURCES / name).read_text()) == json.loads((ROOT / source).read_text()), name
    entries = ['Package.swift', 'Sources/PaywallKit'] if IOS else [
        'pubspec.yaml', 'lib/native_paywall.dart', 'ios/native_paywall.podspec',
        'ios/Classes/PaywallResourcesPlugin.swift', 'android/build.gradle',
        'android/src/main/AndroidManifest.xml',
        'android/src/main/java/com/paywallkit/native_paywall/PaywallResourcesPlugin.java']
    for entry in entries + ['README.md', 'CHANGELOG.md', 'protocol/web-paywall.schema.json']:
        assert (ROOT / entry).exists(), f'Missing package entry: {entry}'
    for path in ROOT.rglob('*'):
        relative = path.relative_to(ROOT)
        if any(part in IGNORED for part in relative.parts):
            continue
        assert not path.is_symlink(), f'SDK symlink dependency: {relative}'
        if not path.is_file() or path.suffix not in {'.swift', '.dart', '.json', '.md', '.yaml'}:
            continue
        text = path.read_text()
        assert not re.search(r'com\.viva\.|chair[-_ ]?yoga|/Users/chen/', text, re.I), f'Business content: {relative}'
        if path.suffix == '.json':
            json.loads(text)
        if path.suffix == '.md':
            for target in re.findall(r'\]\(([^)]+)\)', text):
                if '://' in target or target.startswith('#'):
                    continue
                resolved = (path.parent / target.split('#')[0]).resolve()
                assert resolved.is_relative_to(ROOT) and resolved.exists(), f'External/broken link: {relative}: {target}'
    print('PASS standalone package entries, local resources, document links and business boundary')


if __name__ == '__main__':
    main()
