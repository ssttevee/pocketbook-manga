#!/usr/bin/env python3
"""Build-time bundler. The delivered application needs no computer or service."""
import argparse, hashlib, json, os, pathlib, shutil, subprocess, tarfile, tempfile, urllib.request
ROOT = pathlib.Path(__file__).resolve().parent.parent
LOCK = json.loads((ROOT / 'tools/runtime-packages.json').read_text())

def fetch(name, cache):
    entry = LOCK['packages'][name]
    target = cache / pathlib.Path(entry['Filename']).name
    if not target.exists():
        print('Downloading', name, flush=True)
        part = target.with_suffix('.part')
        with urllib.request.urlopen(LOCK['base_url'] + entry['Filename'], timeout=60) as response, part.open('wb') as out:
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

def materialize(source, target, extracted, seen=0):
    if seen > 16: raise RuntimeError(f'Symlink loop: {source}')
    if source.is_symlink():
        link = pathlib.Path(os.readlink(source))
        resolved = extracted / str(link).lstrip('/') if link.is_absolute() else source.parent / link
        materialize(resolved, target, extracted, seen + 1)
    elif source.is_dir():
        target.mkdir(parents=True, exist_ok=True)
        for child in source.iterdir():
            if child.name in ('docs', 'man', 'cacerts'): continue
            materialize(child, target / child.name, extracted)
    elif source.is_file():
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    else:
        raise RuntimeError(f'Unresolved runtime path: {source}')

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--cache', type=pathlib.Path, default=ROOT / '.runtime-cache')
    parser.add_argument('--output', type=pathlib.Path, default=ROOT / 'dist')
    parser.add_argument('--host-jar', type=pathlib.Path, default=ROOT.parent / 'zig-tachi/host/build/libs/tachi-host.jar')
    parser.add_argument('--test-sysroot', action='store_true', help='Also unpack ARM libc for emulation; never shipped to the reader')
    args=parser.parse_args()
    args.cache.mkdir(parents=True, exist_ok=True)
    if not args.host_jar.is_file(): raise SystemExit('Build zig-tachi/host first: zig build host in that repository')
    app=args.output / 'applications' / 'pocketmanga'
    runtime=app / 'runtime'
    # Preserve any existing user library when rebuilding a staging directory.
    if runtime.exists(): shutil.rmtree(runtime)
    runtime.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix='pocketmanga-runtime-') as tmp:
        extracted=pathlib.Path(tmp)
        for name in ('openjdk-17-jre-headless','libatomic1','gcc-12-base','ca-certificates'):
            extract(fetch(name,args.cache),extracted)
        materialize(extracted / 'usr/lib/jvm/java-17-openjdk-armel', runtime / 'jre', extracted)
        # Keep the firmware's newer C++ runtime: overriding it with GCC 12's
        # copy breaks libinkview, which needs GLIBCXX_3.4.31 on firmware 6.10.
        (runtime / 'lib').mkdir()
        for source in (extracted / 'usr/lib/arm-linux-gnueabi').glob('libatomic.so*'):
            materialize(source,runtime / 'lib' / source.name,extracted)
        certs=extracted / 'usr/share/ca-certificates'
        (runtime / 'ca.pem').write_bytes(b'\n'.join(p.read_bytes() for p in sorted(certs.rglob('*.crt'))))
        cacerts=runtime / 'jre/lib/security/cacerts'
        subprocess.run(['java', str(ROOT/'tools/BuildTrustStore.java'),str(certs),str(cacerts)],check=True)
        shutil.copytree(extracted / 'usr/share/doc', runtime / 'licenses', dirs_exist_ok=True, symlinks=True)
        if args.test_sysroot:
            sysroot=args.output / 'test-sysroot'
            for name in ('libc6','libstdc++6','libgcc-s1','zlib1g'):
                extract(fetch(name,args.cache),sysroot)
    shutil.copy2(args.host_jar,runtime/'tachi-host.jar')
    binary=ROOT/'zig-out/bin/pocketmanga.app'
    if not binary.is_file(): raise SystemExit('Run zig build device -Doptimize=ReleaseSmall first')
    (app/'bin').mkdir(exist_ok=True)
    shutil.copy2(binary, app/'bin/pocketmanga')
    shutil.copy2(ROOT/'tools/pocketmanga.app',args.output/'applications/pocketmanga.app')
    shutil.copy2(ROOT/'tools/pocketmanga-log.app',args.output/'applications/pocketmanga-log.app')
    (runtime/'packages.json').write_text(json.dumps(LOCK,indent=2)+'\n')
    archive=args.output/'pocketmanga-verse.tar.gz'
    with tarfile.open(archive,'w:gz') as tar: tar.add(args.output/'applications',arcname='applications')
    print('Archive:',archive,flush=True)
    print('Ready:',args.output/'applications',flush=True)
    print('Copy this applications/ folder to the Verse once; all browsing and downloads then run on the reader.')
if __name__=='__main__': main()
