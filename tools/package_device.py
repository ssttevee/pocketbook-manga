#!/usr/bin/env python3
"""Build-time bundler. The delivered application needs no computer or service."""
import argparse, hashlib, json, pathlib, shutil, subprocess, tarfile, tempfile, urllib.request
from release_manifest import PROFILES, digest
ROOT = pathlib.Path(__file__).resolve().parent.parent
LOCK = json.loads((ROOT / 'tools/runtime-packages.json').read_text())

def fetch(name, cache, lock=LOCK):
    entry = lock['packages'][name]
    target = cache / pathlib.Path(entry['Filename']).name
    if not target.exists():
        print('Downloading', name, flush=True)
        part = target.with_suffix('.part')
        with urllib.request.urlopen(lock['base_url'] + entry['Filename'], timeout=60) as response, part.open('wb') as out:
            shutil.copyfileobj(response, out)
        part.replace(target)
    if hashlib.sha256(target.read_bytes()).hexdigest() != entry['SHA256']:
        raise RuntimeError(f'SHA256 mismatch for {target}; remove it and retry')
    return target

def extract(deb, directory):
    directory.mkdir(parents=True, exist_ok=True)
    member = next(n for n in subprocess.check_output(['ar', 't', str(deb)], text=True).splitlines() if n.startswith('data.tar'))
    with tempfile.TemporaryFile() as stream:
        subprocess.run(['ar', 'p', str(deb), member], stdout=stream, check=True)
        stream.seek(0)
        with tarfile.open(fileobj=stream, mode='r:*') as tar:
            # Packages are hash-pinned upstream archives, not user-supplied files.
            tar.extractall(directory, filter='tar')

def write_archive(output, archive):
    # Ship application files only. A reused staging folder may contain user
    # data; including it could overwrite another reader's database on upgrade.
    with tarfile.open(archive, 'w:gz') as tar:
        for relative in ('pocketmanga.app', 'pocketmanga-log.app',
                         'pocketmanga/bin', 'pocketmanga/runtime'):
            tar.add(output / 'applications' / relative,
                    arcname='applications/' + relative)


def validate_profile(glibc, lock, target):
    expected = PROFILES[glibc]
    if any(target.get(key) != expected[key] for key in ('cpu', 'abi', 'glibc')):
        raise ValueError('Native build target does not match the selected runtime; rebuild with -Dglibc=' + glibc)
    if lock.get('profile') != expected:
        raise ValueError('Runtime manifest does not match the selected firmware profile')
    for component in ('jre', 'images'):
        if lock[component].get('Glibc') != glibc:
            raise ValueError(component + ' runtime has the wrong glibc profile')


def runtime_lock(glibc, manifest):
    if manifest:
        return json.loads(manifest.read_text())
    entries = LOCK.get('profiles', {}).get(glibc)
    if entries is None:
        if glibc != '2.23':
            raise ValueError('No reviewed runtime pins for glibc ' + glibc + '; provide --runtime-manifest from the trusted runtime build')
        entries = {key: dict(LOCK[key], Glibc=glibc) for key in ('jre', 'images')}
    return dict(LOCK, **entries, profile=PROFILES[glibc])


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--glibc', choices=PROFILES, default='2.23')
    parser.add_argument('--runtime-manifest', type=pathlib.Path, help='Trusted release build manifest with runtime integrity values')
    parser.add_argument('--cache', type=pathlib.Path, default=ROOT / '.runtime-cache')
    parser.add_argument('--output', type=pathlib.Path, default=ROOT / 'dist')
    parser.add_argument('--host-jar', type=pathlib.Path, default=ROOT / 'zig-out/lib/tachi-host.jar')
    parser.add_argument('--ui-binary', type=pathlib.Path, default=ROOT / 'zig-out/bin/pocketmanga.app')
    parser.add_argument('--worker-binary', type=pathlib.Path, default=ROOT / 'zig-out/bin/pocketmanga-worker')
    parser.add_argument('--target-metadata', type=pathlib.Path, default=ROOT / 'zig-out/share/pocketmanga/build-target.json')
    parser.add_argument('--zstd-library', type=pathlib.Path, help='Source-built JNI decoder (default: zig-out/lib from zig build device)')
    parser.add_argument('--zstd-license', type=pathlib.Path, help='License accompanying the source-built JNI decoder')
    parser.add_argument('--images', type=pathlib.Path, help='Decoder runtime from tools/build_images.py')
    parser.add_argument('--jre', type=pathlib.Path, help='Java runtime from tools/build_jre.py')
    args=parser.parse_args()
    suffix = '' if args.glibc == '2.23' else '-glibc-' + args.glibc
    args.images = args.images or ROOT / ('.runtime-cache/image' + suffix) / 'pocketmanga-image.tar'
    args.jre = args.jre or ROOT / ('.runtime-cache/jre' + suffix) / 'pocketmanga-jre.tar'
    try:
        lock = runtime_lock(args.glibc, args.runtime_manifest)
        target = json.loads(args.target_metadata.read_text())
        validate_profile(args.glibc, lock, target)
    except (ValueError, OSError, KeyError) as error:
        raise SystemExit(str(error))
    args.cache.mkdir(parents=True, exist_ok=True)
    if not args.host_jar.is_file(): raise SystemExit('Build the host jar first: zig build host')
    if not args.jre.is_file(): raise SystemExit('Build the Java runtime first: tools/build_jre.py')
    if not args.images.is_file(): raise SystemExit('Build the image runtime first: tools/build_images.py')
    image_lock = json.loads((ROOT / 'tools/image/sources.json').read_text())
    if digest(args.images) != lock['images']['SHA256']:
        raise SystemExit('Image runtime differs from pinned build; rerun tools/build_images.py')
    if digest(args.jre) != lock['jre']['SHA256']:
        raise SystemExit(f'{args.jre} is not the pinned runtime build; rerun tools/build_jre.py')
    if 'CDS_SHA256' in lock['jre'] and digest(args.jre.parent / 'classes.jsa') != lock['jre']['CDS_SHA256']:
        raise SystemExit('The class-data archive does not match the runtime manifest')
    zstd = args.zstd_library or ROOT / 'zig-out/lib/libpocketmanga-zstd.so'
    if not zstd.is_file(): raise SystemExit('Run zig build device first: '+str(zstd))
    app=args.output / 'applications' / 'pocketmanga'
    runtime=app / 'runtime'
    # Preserve any existing user library when rebuilding a staging directory.
    if runtime.exists(): shutil.rmtree(runtime)
    runtime.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix='pocketmanga-runtime-') as tmp:
        extracted=pathlib.Path(tmp)
        extract(fetch('ca-certificates',args.cache,lock),extracted)
        with tarfile.open(args.jre) as tar:
            # The runtime is a pinned build of ours, not a user-supplied file.
            tar.extractall(runtime, filter='tar')
        # The base CDS archive built with it; the VM rejects it if it does not match.
        shutil.copy2(args.jre.parent / 'classes.jsa', runtime / 'jre/lib/client/classes.jsa')
        (runtime / 'lib').mkdir()
        image_runtime = runtime / 'image'
        image_runtime.mkdir()
        with tarfile.open(args.images) as tar:
            tar.extractall(image_runtime, filter='tar')
        (image_runtime / 'sources.json').write_text(json.dumps(image_lock, indent=2) + '\n')
        certs=extracted / 'usr/share/ca-certificates'
        (runtime / 'ca.pem').write_bytes(b'\n'.join(p.read_bytes() for p in sorted(certs.rglob('*.crt'))))
        cacerts=runtime / 'jre/lib/security/cacerts'
        subprocess.run(['java', str(ROOT/'tools/BuildTrustStore.java'),str(certs),str(cacerts)],check=True)
        shutil.copytree(extracted / 'usr/share/doc', runtime / 'licenses', dirs_exist_ok=True, symlinks=True)
        shutil.copy2(ROOT / 'tools/RUNTIME-NOTICE', runtime / 'licenses/RUNTIME-NOTICE')
        shutil.copytree(ROOT / 'tools/runtime-licenses', runtime / 'licenses/gcc-runtime')
    shutil.copy2(args.host_jar,runtime/'tachi-host.jar')
    shutil.copy2(zstd, runtime/'lib/libpocketmanga-zstd.so')
    shutil.copy2(args.zstd_license or zstd.parent.parent/'share/licenses/zstd-LICENSE.txt', runtime/'licenses/zstd-LICENSE.txt')
    binary=args.ui_binary
    if not binary.is_file(): raise SystemExit('Run zig build device -Doptimize=ReleaseSmall first')
    (app/'bin').mkdir(exist_ok=True)
    shutil.copy2(binary, app/'bin/pocketmanga')
    shutil.copy2(args.worker_binary, app/'bin/pocketmanga-worker')
    shutil.copy2(ROOT/'tools/pocketmanga.app',args.output/'applications/pocketmanga.app')
    shutil.copy2(ROOT/'tools/pocketmanga-log.app',args.output/'applications/pocketmanga-log.app')
    (runtime/'packages.json').write_text(json.dumps(lock,indent=2)+'\n')
    (args.output/'runtime-manifest.json').write_text(json.dumps(lock,indent=2)+'\n')
    archive=args.output/f'pocketmanga-armv7-softfp-glibc-{args.glibc}.tar.gz'
    write_archive(args.output, archive)
    checksum = digest(archive)
    (args.output/(archive.name+'.sha256')).write_text(f'{checksum}  {archive.name}\n')
    print('Bundle bytes:', sum(p.stat().st_size for p in (args.output/'applications').rglob('*') if p.is_file()), flush=True)
    print('Archive bytes:', archive.stat().st_size, flush=True)
    print('Archive:',archive,flush=True)
    print('Ready:',args.output/'applications',flush=True)
    print('Copy this applications/ folder to the Verse once; all browsing and downloads then run on the reader.')
if __name__=='__main__': main()
