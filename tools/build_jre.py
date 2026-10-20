#!/usr/bin/env python3
"""Builds the worker's Java runtime from source in Docker (tools/jre/Dockerfile).

The result is checked against the digest pinned in tools/runtime-packages.json:
the build is reproducible, so a mismatch means an input or the build changed.
"""
import argparse, hashlib, json, pathlib, subprocess
ROOT = pathlib.Path(__file__).resolve().parent.parent
LOCK = json.loads((ROOT / 'tools/runtime-packages.json').read_text())

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=pathlib.Path, default=ROOT / '.runtime-cache/jre')
    parser.add_argument('--no-cache', action='store_true', help='Rebuild every stage, including the toolchain')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    command = ['docker', 'build', '--target', 'export', '--output', f'type=local,dest={args.output}']
    if args.no_cache: command.append('--no-cache')
    subprocess.run(command + [str(ROOT / 'tools/jre')], check=True)
    jre = args.output / 'pocketmanga-jre.tar'
    digest = hashlib.sha256(jre.read_bytes()).hexdigest()
    pinned = LOCK['jre']['SHA256']
    print(f'{digest}  {jre}')
    if digest != pinned:
        raise SystemExit(f'Runtime differs from the pinned build ({pinned}); if an input changed on purpose, update tools/runtime-packages.json')
    print('Matches the pinned build.')

if __name__ == '__main__': main()
