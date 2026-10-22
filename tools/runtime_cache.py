#!/usr/bin/env python3
"""Build runtime outputs for Zig's cache and verify them before consumption."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from build_jre import verify_runtime
from release_manifest import PROFILES, create_manifest, digest, immutable_image

ROOT = Path(__file__).resolve().parent.parent
PLATFORM = 'linux/arm64'


def producer_receipt(component, glibc, output, builder):
    archive = output / ('pocketmanga-jre.tar' if component == 'jre' else 'pocketmanga-image.tar')
    verify_runtime(archive, glibc, component, False)
    receipt = {'schema': 1, 'component': component, 'glibc': glibc,
               'builder': builder, 'archive_sha256': digest(archive)}
    if component == 'jre':
        receipt['cds_sha256'] = digest(output / 'classes.jsa')
    return receipt


def verify_producer(component, glibc, output, builder):
    recorded = json.loads((output / 'producer-receipt.json').read_text())
    if recorded != producer_receipt(component, glibc, output, builder):
        raise ValueError('Cached runtime differs from its producer receipt; remove the affected Zig cache entry and rebuild')


def builder_reference(glibc):
    lock = json.loads((ROOT / 'tools/runtime-packages.json').read_text())
    try:
        return immutable_image(lock['builders'][glibc])
    except KeyError as error:
        raise ValueError(f'No reviewed builder for glibc {glibc}') from error


def build(component, glibc, output):
    builder = builder_reference(glibc)
    # Zig 0.17 reruns Run steps after metadata-only input changes (including
    # cache restores), even though it selects the same content-keyed output.
    # Reuse only completed, verified outputs from that exact producer identity.
    if output.exists() and any(output.iterdir()):
        verify_producer(component, glibc, output, builder)
        print(f'Reusing verified {component} output for glibc {glibc}')
        return
    script, option = ('build_jre.py', '--builder-image') if component == 'jre' else ('build_images.py', '--toolchain-image')
    # Published builders are ARM64 even when a developer's Docker host is not.
    # Keep this controlled input in the helper rather than hashing CI's entire
    # volatile environment into every Zig cache entry.
    environment = dict(os.environ, DOCKER_DEFAULT_PLATFORM=PLATFORM)
    subprocess.run([sys.executable, str(ROOT / 'tools' / script), '--glibc', glibc,
                    option, builder, '--output', str(output)], env=environment, check=True)
    receipt = producer_receipt(component, glibc, output, builder)
    (output / 'producer-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')


def reviewed_manifest(glibc, jre, images):
    builder = builder_reference(glibc)
    verify_producer('jre', glibc, jre, builder)
    verify_producer('images', glibc, images, builder)
    return create_manifest(glibc, jre, images, builder)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    producer = sub.add_parser('build')
    producer.add_argument('--component', choices=('jre', 'images'), required=True)
    producer.add_argument('--output', type=Path, required=True)
    for name in ('manifest', 'verify'):
        command = sub.add_parser(name)
        command.add_argument('--jre', type=Path, required=True)
        command.add_argument('--images', type=Path, required=True)
        command.add_argument('--output' if name == 'manifest' else '--manifest', type=Path, required=True)
    for command in sub.choices.values():
        command.add_argument('--glibc', choices=PROFILES, required=True)
    args = parser.parse_args()
    try:
        if args.command == 'build':
            build(args.component, args.glibc, args.output)
        else:
            expected = reviewed_manifest(args.glibc, args.jre, args.images)
            if args.command == 'manifest':
                args.output.parent.mkdir(parents=True, exist_ok=True)
                if args.output.exists():
                    if json.loads(args.output.read_text()) != expected:
                        raise ValueError('Cached runtime manifest differs from its original snapshot; remove the affected Zig cache entry and rebuild')
                else:
                    args.output.write_text(json.dumps(expected, indent=2) + '\n')
            elif json.loads(args.manifest.read_text()) != expected:
                raise ValueError('Cached runtime manifest differs from reviewed profile, builder or runtime outputs; remove the affected Zig cache entry and rebuild')
    except (OSError, ValueError, argparse.ArgumentTypeError) as error:
        parser.error(str(error))


if __name__ == '__main__':
    main()
