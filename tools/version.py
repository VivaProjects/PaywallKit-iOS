#!/usr/bin/env python3
"""Manage and tag only the current repository's release version."""
import argparse
from datetime import date
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
FLUTTER = (ROOT / 'pubspec.yaml').exists()
SOURCE = ROOT / ('pubspec.yaml' if FLUTTER else 'VERSION')


def version():
    text = SOURCE.read_text().strip()
    if FLUTTER:
        matches = re.findall(r'^version: (\S+)$', text, re.M)
        if len(matches) != 1:
            raise ValueError('Expected one pubspec version')
        text = matches[0]
    if not re.fullmatch(r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', text):
        raise ValueError('Expected MAJOR.MINOR.PATCH')
    return text


def check():
    value = version()
    if not re.search(rf'^## \[{re.escape(value)}\](?: |$)', (ROOT / 'CHANGELOG.md').read_text(), re.M):
        raise ValueError('Current version missing from CHANGELOG.md')
    if FLUTTER:
        podspec = (ROOT / 'ios/native_paywall.podspec').read_text()
        if re.findall(r"s\.version\s*=\s*'([^']+)'", podspec) != [value]:
            raise ValueError('Flutter pubspec and podspec versions differ')
    return value


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args], text=True).strip()


def bump(part, note):
    old = check()
    numbers = list(map(int, old.split('.')))
    index = ['major', 'minor', 'patch'].index(part)
    numbers[index] += 1
    numbers[index + 1:] = [0] * (2 - index)
    new = '.'.join(map(str, numbers))
    updates = {SOURCE: new + '\n'}
    if FLUTTER:
        updates[SOURCE] = re.sub(r'^version: \S+$', f'version: {new}', SOURCE.read_text(), flags=re.M)
        podspec = ROOT / 'ios/native_paywall.podspec'
        updates[podspec] = re.sub(r"s\.version\s*=\s*'[^']+'", f"s.version = '{new}'", podspec.read_text())
    changelog = ROOT / 'CHANGELOG.md'
    text = changelog.read_text()
    position = text.index('\n## [')
    updates[changelog] = text[:position] + f'\n## [{new}] - {date.today().isoformat()}\n\n- {note.strip()}\n' + text[position:]
    for path, content in updates.items():
        path.write_text(content)
    check()
    print(f'{old} -> {new}; not committed, tagged or published')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ['show', 'check', 'tag']:
        commands.add_parser(name)
    command = commands.add_parser('bump')
    command.add_argument('part', choices=['major', 'minor', 'patch'])
    command.add_argument('--note', required=True)
    args = parser.parse_args()
    try:
        if args.command == 'bump':
            if not args.note.strip() or '\n' in args.note or '\r' in args.note:
                raise ValueError('Release note must be a nonempty single line')
            bump(args.part, args.note)
        else:
            value = check()
            if args.command == 'tag':
                if Path(git('rev-parse', '--show-toplevel')).resolve() != ROOT:
                    raise ValueError('This directory must be its own Git repository')
                if git('status', '--porcelain'):
                    raise ValueError('Commit reviewed changes before tagging; working tree must be clean')
                if git('tag', '--list', value):
                    raise ValueError(f'Tag already exists: {value}')
                git('tag', '-a', value, '-m', f'Release {value}')
                print(f'Created local tag {value}; no push performed')
            else:
                print(value if args.command == 'show' else f'PASS version {value}')
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.error(str(error))


if __name__ == '__main__':
    main()
