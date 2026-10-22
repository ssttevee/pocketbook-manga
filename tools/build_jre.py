#!/usr/bin/env python3
"""Build the ARM worker JVM for a PocketBook glibc profile.

Normal builds verify the reviewed digest in runtime-packages.json. A new
profile can produce runtime-entry.json with --record-digest for review or
release packaging; this never changes the checked-in runtime manifest.
"""
import argparse
import hashlib
import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent


def runtime_entry(lock, glibc, component):
    entry = lock.get('profiles', {}).get(glibc, {}).get(component)
    if entry is None and glibc == '2.23':
        entry = lock.get(component)
    return entry


def verify_runtime(archive, glibc, component, record_digest):
    lock = json.loads((ROOT / 'tools/runtime-packages.json').read_text())
    entry = runtime_entry(lock, glibc, component)
    # A new profile shares source/version metadata, but never inherits the old
    # ABI's digest. The source lock is deliberately immutable during a build.
    metadata = {**lock.get(component, {}), **(entry or {})}
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    print(f'{digest}  {archive}')
    if record_digest:
        metadata['SHA256'] = digest
        metadata['Glibc'] = glibc
        destination = archive.parent / 'runtime-entry.json'
        destination.write_text(json.dumps({component: metadata}, indent=2) + '\n')
        print(f'Recorded build digest in {destination}; review before publishing.')
    elif entry is None or not entry.get('SHA256'):
        raise SystemExit(f'No reviewed {component} digest for glibc {glibc}; use --record-digest for a new trusted build')
    elif digest != entry['SHA256']:
        raise SystemExit(f"Runtime differs from the pinned build ({entry['SHA256']}); review the inputs or use --record-digest")
    else:
        print('Matches the pinned build.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--glibc', choices=('2.23', '2.39'), default='2.23')
    parser.add_argument('--output', type=pathlib.Path)
    parser.add_argument('--builder-image', help='Published deps-stage image (prefer an immutable registry digest)')
    parser.add_argument('--record-digest', action='store_true', help='Record a new runtime digest for review instead of comparing the lock')
    parser.add_argument('--no-cache', action='store_true', help='Rebuild every stage, including the toolchain')
    args = parser.parse_args()
    output = args.output or ROOT / '.runtime-cache' / ('jre' if args.glibc == '2.23' else f'jre-glibc-{args.glibc}')
    output.mkdir(parents=True, exist_ok=True)
    command = ['docker', 'build', '--target', 'export', '--build-arg', f'GLIBC_VERSION={args.glibc}', '--output', f'type=local,dest={output}']
    if args.builder_image:
        command += ['--build-arg', f'BUILDER_IMAGE={args.builder_image}']
    if args.no_cache:
        command.append('--no-cache')
    subprocess.run(command + [str(ROOT / 'tools/jre')], check=True)
    verify_runtime(output / 'pocketmanga-jre.tar', args.glibc, 'jre', args.record_digest)


if __name__ == '__main__':
    main()
