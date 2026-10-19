#!/usr/bin/env python3
"""Check the versioned ELF dependency closure against a firmware + bundle.

Includes the JNI native libraries used by the fixture and network flows.
No proprietary library is copied into the bundle.
"""
import argparse, json, pathlib, re, shutil, subprocess
ROOT = pathlib.Path(__file__).resolve().parent.parent

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--process', choices=['ui', 'worker'], required=True)
    parser.add_argument('--rootfs', type=pathlib.Path, required=True)
    parser.add_argument('--readelf', default=shutil.which('llvm-readelf') or '/opt/homebrew/opt/llvm/bin/llvm-readelf')
    parser.add_argument('--output', type=pathlib.Path)
    args = parser.parse_args()
    app = ROOT/'dist/applications/pocketmanga'
    runtime = app/'runtime'
    firmware = args.rootfs.resolve()
    search = [firmware/'lib', firmware/'ebrmain/lib', firmware/'usr/lib', firmware/'ebrmain/cramfs/lib']
    if args.process == 'worker': search = [runtime/'lib', runtime/'jre/lib', runtime/'jre/lib/server'] + search
    def resolve(path):
        # Absolute symlinks in a rootfs must resolve inside that rootfs.
        for _ in range(32):
            if not path.is_symlink(): return path
            link = pathlib.Path(path.readlink())
            path = firmware/str(link).lstrip('/') if link.is_absolute() else path.parent/link
        raise RuntimeError('Symlink loop: '+str(path))
    def locate(name):
        for directory in search:
            path = resolve(directory/name)
            if path.is_file(): return path.resolve()
        raise RuntimeError('Missing NEEDED: '+name)
    def readelf(*options):
        return subprocess.check_output([args.readelf, *map(str, options)], text=True)
    if args.process == 'ui':
        queue = [app/'bin/pocketmanga', locate('libinkview.so')]
    else:
        queue = [app/'bin/pocketmanga-worker'] + [runtime/'jre/lib'/name for name in ['server/libjvm.so','libjava.so','libjimage.so','libnet.so','libnio.so','libzip.so','libverify.so','libmanagement.so','libmanagement_ext.so','libextnet.so']]
        queue += list((runtime/'lib').iterdir())
    entries = {}
    exports = set()
    imports = {}
    while queue:
        path = queue.pop(0).resolve()
        if str(path) in entries: continue
        dynamic = readelf('-d', path)
        needed = re.findall(r'\(NEEDED\).*\[([^]]+)\]', dynamic)
        symbols = readelf('--dyn-syms','--wide',path)
        required = set()
        provided = set()
        for line in symbols.splitlines():
            fields = line.split()
            if len(fields) < 8 or not fields[0].endswith(':') or not fields[0][:-1].isdigit(): continue
            name = fields[7].replace('@@','@')
            if fields[6] == 'UND':
                if '@' in name and fields[4] != 'WEAK': required.add(name)
            elif fields[4] in ('GLOBAL','WEAK'):
                provided.add(name)
        exports.update(provided)
        imports[str(path)] = required
        versions = re.findall(r'@GLIBC_([0-9.]+)', ' '.join(required))
        maximum = max(versions,key=lambda v:tuple(map(int,v.split('.')))) if versions else None
        entries[str(path)] = {'needed':needed,'max_glibc':maximum,'origin':'bundle' if path.is_relative_to(app) else 'firmware'}
        queue += [locate(name) for name in needed]
    for path, required in imports.items():
        missing = required-exports
        if missing: raise RuntimeError(f'{path}: missing versioned symbols: {sorted(missing)}')
    # No second glibc/GCC runtime may enter the closure from the firmware.
    gnu = json.loads((ROOT/'tools/runtime-packages.json').read_text())['firmware']['libraries']
    for path, entry in entries.items():
        if args.process == 'worker' and pathlib.Path(path).name in gnu and entry['origin'] != 'bundle': raise RuntimeError('Mixed runtime: '+path)
    if args.process == 'ui' and any(entry['origin'] == 'bundle' and '/runtime/' in path for path, entry in entries.items()): raise RuntimeError('Private runtime in UI')
    if args.process == 'worker' and any('libinkview' in path for path in entries): raise RuntimeError('InkView in worker')
    report = {'process':args.process,'rootfs':str(firmware),'versioned_imports':sum(map(len,imports.values())),'libraries':entries}
    text = json.dumps(report,indent=2)+'\n'
    if args.output:
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(text)
    print(f'PASS {args.process}: {len(entries)} ELF objects, {report["versioned_imports"]} versioned imports satisfied')
    for path, entry in entries.items():
        if entry['origin']=='firmware': print('Device:',pathlib.Path(path).name,'NEEDED='+','.join(entry['needed']),'GLIBC<='+str(entry['max_glibc']))

if __name__ == '__main__': main()
