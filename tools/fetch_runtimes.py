#!/usr/bin/env python3
"""Download reviewed ARM runtime artifacts from immutable public registry images.

Images are copied from stopped containers; no foreign-architecture code runs.
Archive digests must match runtime-packages.json before release provenance is
written. Building or updating runtime pins is a separate, explicit operation.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

from build_jre import verify_runtime
from release_manifest import create_manifest, immutable_image

ROOT = Path(__file__).resolve().parent.parent
PLATFORM = 'linux/arm64'


def image_references(lock, glibc):
    """Validate the complete trust boundary before contacting a registry."""
    try:
        builder = immutable_image(lock['builders'][glibc])
        images = {component: immutable_image(lock['runtime_images'][glibc][component])
                  for component in ('jre', 'images')}
    except KeyError as error:
        raise ValueError(f'No reviewed runtime image configuration for glibc {glibc}: missing {error}') from error
    return builder, images


def extract_artifacts(image, destination):
    destination.mkdir(parents=True, exist_ok=True)
    subprocess.run(['docker', 'pull', '--platform', PLATFORM, image], check=True)
    container = subprocess.check_output(
        ['docker', 'create', '--platform', PLATFORM, image], text=True).strip()
    try:
        subprocess.run(['docker', 'cp', f'{container}:/artifacts/.', str(destination)], check=True)
    finally:
        subprocess.run(['docker', 'rm', container], check=True, stdout=subprocess.DEVNULL)


def fetch(glibc, output):
    lock = json.loads((ROOT / 'tools/runtime-packages.json').read_text())
    builder, references = image_references(lock, glibc)
    output.parent.mkdir(parents=True, exist_ok=True)
    # Failed downloads or a bad pin leave any previously verified cache alone.
    with tempfile.TemporaryDirectory(prefix='pocketmanga-runtimes-', dir=output.parent) as temporary:
        staging = Path(temporary)
        for component, archive in (('jre', 'pocketmanga-jre.tar'), ('images', 'pocketmanga-image.tar')):
            extract_artifacts(references[component], staging / component)
            verify_runtime(staging / component / archive, glibc, component, False)
        manifest = create_manifest(glibc, staging / 'jre', staging / 'images', builder,
                                   references['jre'], references['images'])
        for component in ('jre', 'images'):
            shutil.copytree(staging / component, output / component, dirs_exist_ok=True)
        destination = output / 'runtime-manifest.json'
        staged_manifest = staging / 'runtime-manifest.json'
        staged_manifest.write_text(json.dumps(manifest, indent=2) + '\n')
        staged_manifest.replace(destination)
    print(f'Verified glibc {glibc} runtimes and provenance: {destination}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--glibc', choices=('2.23', '2.39'), default='2.23')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    output = args.output or ROOT / '.runtime-cache' / f'published-{args.glibc}'
    try:
        fetch(args.glibc, output)
    except (ValueError, argparse.ArgumentTypeError) as error:
        parser.error(str(error))


if __name__ == '__main__':
    main()
