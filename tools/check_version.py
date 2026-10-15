#!/usr/bin/env python3
"""Verify this repository's release tooling in a disposable directory."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    with tempfile.TemporaryDirectory(prefix='paywall-version-') as folder:
        target = Path(folder)
        files = ['tools/version.py', 'CHANGELOG.md']
        flutter = (ROOT / 'pubspec.yaml').exists()
        files += ['pubspec.yaml', 'ios/native_paywall.podspec'] if flutter else ['VERSION']
        for name in files:
            destination = target / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, destination)
        def run(*args, success=True):
            result = subprocess.run([sys.executable, str(target/'tools/version.py'), *args],
                                    capture_output=True, text=True)
            assert (result.returncode == 0) == success, result.stderr
            return result.stdout.strip()
        old = run('show')
        major, minor, patch = map(int, old.split('.'))
        run('bump', 'patch', '--note', 'test release')
        assert run('show') == f'{major}.{minor}.{patch + 1}'
        run('bump', 'minor', '--note', 'test feature')
        assert run('show') == f'{major}.{minor + 1}.0'
        run('bump', 'major', '--note', 'test breaking change')
        assert run('show') == f'{major + 1}.0.0'
        run('check')
        before = {name: (target/name).read_bytes() for name in files}
        run('bump', 'patch', '--note', '', success=False)
        assert before == {name: (target/name).read_bytes() for name in files}
        run('tag', success=False)  # A parent checkout must never receive the tag.
        if flutter:
            (target/'ios/native_paywall.podspec').write_text("s.version = '999.0.0'\n")
            run('check', success=False)
        assert subprocess.check_output([sys.executable, str(ROOT/'tools/version.py'), 'show'],text=True).strip() == old
    print('PASS isolated bumps, reset rules, validation, tag guard and unchanged source version')


if __name__ == '__main__':
    main()
