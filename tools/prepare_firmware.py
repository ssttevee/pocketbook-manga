#!/usr/bin/env python3
"""Extract official Verse images for the firmware tests, without mounting anything.

Keep --output outside the repository: the test roots contain proprietary files.
Requires debugfs (e2fsprogs) and unsquashfs. Downloads are explicit, never automatic.
"""
import argparse, gzip, hashlib, pathlib, shutil, struct, subprocess, tempfile, zipfile
ROOT = pathlib.Path(__file__).resolve().parent.parent
FIRMWARE = {
    '6.9': ('45d889ab952e0d66775ed0c07931061bb12f6a38949a354b302808a16eb8a042', 'U629.6.9.862'),
    '6.10': ('b4f21e38bc9213dd3588e77258e26f72dc644fa565c98260f7334fd62eaabe8a', 'U629.6.10.1461'),
}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('version', choices=FIRMWARE)
    parser.add_argument('archive', type=pathlib.Path)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--debugfs', default=shutil.which('debugfs') or '/opt/homebrew/opt/e2fsprogs/sbin/debugfs')
    args = parser.parse_args()
    output = args.output.resolve()
    if output.is_relative_to(ROOT): raise SystemExit('Extract firmware outside the repository')
    if output.exists() and any(output.iterdir()): raise SystemExit('Use an empty output directory')
    digest = hashlib.file_digest(args.archive.open('rb'), 'sha256').hexdigest()
    if digest != FIRMWARE[args.version][0]: raise SystemExit('Firmware archive SHA256 mismatch')
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='pocketmanga-firmware-') as tmp:
        tmp = pathlib.Path(tmp)
        with zipfile.ZipFile(args.archive) as archive:
            member = next(n for n in archive.namelist() if n.upper().endswith('SWUPDATE.BIN'))
            with archive.open(member) as src, (tmp/'update.bin').open('wb') as dest: shutil.copyfileobj(src, dest)
        with (tmp/'update.bin').open('rb') as update:
            header = update.read(1024)
            if header[:16] != b'PocketBookUpdate': raise RuntimeError('Unknown firmware header')
            partitions = {}
            for offset in range(256, 1024, 16):
                kind, _, start, size = struct.unpack_from('<4I', header, offset)
                if kind == 0: break
                if kind in (0x72, 0x65): partitions[kind] = (start, size)
            for kind, dest in ((0x72, output), (0x65, output/'ebrmain')):
                start, size = partitions[kind]
                update.seek(1024 + start)
                compressed = tmp/'partition.gz'
                with compressed.open('wb') as out:
                    remaining = size
                    while remaining:
                        data = update.read(min(remaining, 1 << 20))
                        if not data: raise RuntimeError('Truncated firmware')
                        out.write(data)
                        remaining -= len(data)
                image = tmp/'partition.ext2'
                with gzip.open(compressed) as src, image.open('wb') as out: shutil.copyfileobj(src, out)
                dest.mkdir(parents=True, exist_ok=True)
                # Non-root debugfs reports failed chown after extracting files.
                # Retain its output; subsequent ELF hashes/tests verify content.
                with (output/f'debugfs-{kind:x}.log').open('w') as log:
                    subprocess.run([args.debugfs, '-R', f'rdump / "{dest}"', str(image)], stdout=log, stderr=log, check=True)
        subprocess.run(['unsquashfs', '-no-progress', '-no-xattrs', '-d', str(output/'ebrmain/cramfs'), str(output/'ebrmain/cramfs.img'), 'lib'], check=True)
    if not (output/'lib/libc.so.6').exists(): raise RuntimeError('Missing rootfs libc')
    if not (output/'ebrmain/lib/libinkview.so').exists(): raise RuntimeError('Missing InkView')
    (output/'firmware-version').write_text(FIRMWARE[args.version][1] + '\n')
    print('Extracted:', output)

if __name__ == '__main__': main()
