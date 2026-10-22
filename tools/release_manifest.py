#!/usr/bin/env python3
"""Record trusted runtime build outputs for one release's CPU/ABI/libc profile.

Run after building or extracting images by immutable registry digest. This is
provenance for a specific build, not a signature or a firmware compatibility test.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent
PROFILES = {
    '2.23': {'cpu': 'armv7', 'abi': 'softfp', 'glibc': '2.23', 'firmware': '6.8–6.9'},
    '2.39': {'cpu': 'armv7', 'abi': 'softfp', 'glibc': '2.39', 'firmware': '6.10'},
}


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def immutable_image(value):
    if not re.fullmatch(r'[^\s]+@sha256:[0-9a-f]{64}', value):
        raise argparse.ArgumentTypeError('Use an immutable registry reference: image@sha256:…')
    return value


def create_manifest(glibc, jre, images, builder, jvm_image=None, image_runtime_image=None):
    lock = json.loads((ROOT / 'tools/runtime-packages.json').read_text())
    manifest = {'schema': 1, 'profile': dict(PROFILES[glibc]),
                'base_url': lock['base_url'], 'packages': lock['packages'],
                'builder': immutable_image(builder)}
    for component, directory, name, image in (
        ('jre', jre, 'pocketmanga-jre.tar', jvm_image),
        ('images', images, 'pocketmanga-image.tar', image_runtime_image),
    ):
        entry = dict(lock[component])
        entry.update(Glibc=glibc, SHA256=digest(directory / name))
        if image:
            entry['Image'] = immutable_image(image)
        if component == 'jre':
            entry['CDS_SHA256'] = digest(directory / 'classes.jsa')
        manifest[component] = entry
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--glibc', choices=PROFILES, required=True)
    parser.add_argument('--jre', type=Path, required=True, help='Directory containing JVM tar and classes.jsa')
    parser.add_argument('--images', type=Path, required=True)
    parser.add_argument('--builder', type=immutable_image, required=True)
    parser.add_argument('--jvm-image', type=immutable_image)
    parser.add_argument('--image-runtime-image', type=immutable_image)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    manifest = create_manifest(args.glibc, args.jre, args.images, args.builder,
                               args.jvm_image, args.image_runtime_image)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(manifest, indent=2) + '\n')


if __name__ == '__main__':
    main()
