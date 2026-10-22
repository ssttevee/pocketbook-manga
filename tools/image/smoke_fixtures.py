#!/usr/bin/env python3
"""Exercise ARM region decoding in both orientations and PNG's disk-spill path.

Fixtures use only Python's standard library, so the gate does not depend on a
host libvips installation or a second image encoder.
"""
import pathlib
import struct
import subprocess
import tempfile
import zlib


def write_png(path, width, height):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))

    compressor = zlib.compressobj()
    with path.open('wb') as output:
        output.write(b'\x89PNG\r\n\x1a\n')
        output.write(chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)))
        for y in range(height):
            # Opaque black and white halves make nonempty, nonuniform data.
            pixel = b'\0\0\0\xff' if y < height // 2 else b'\xff\xff\xff\xff'
            compressed = compressor.compress(b'\0' + pixel * width)
            if compressed:
                output.write(chunk(b'IDAT', compressed))
        output.write(chunk(b'IDAT', compressor.flush()))
        output.write(chunk(b'IEND', b''))


def main():
    sysroot = subprocess.check_output(['arm-pocketbook-linux-gnueabi-gcc', '-print-sysroot'], text=True).strip()
    fixtures = [('vertical', 53, 173), ('horizontal', 173, 53), ('disk-spill', 5000, 3617)]
    with tempfile.TemporaryDirectory(prefix='pocketmanga-image-smoke-') as temporary:
        for name, width, height in fixtures:
            path = pathlib.Path(temporary) / f'{name}.png'
            write_png(path, width, height)
            result = subprocess.run([
                'qemu-arm', '-L', sysroot, '/work/out/pocketmanga-image-smoke', str(path),
            ], check=True, text=True, stdout=subprocess.PIPE)
            expected = f'PASS {path} {(width + 1) // 2}x{(height + 1) // 2}'
            if expected not in result.stdout.splitlines():
                raise SystemExit(f'Unexpected decoded dimensions: {result.stdout!r}; expected {expected!r}')
            print(result.stdout, end='', flush=True)


if __name__ == '__main__':
    main()
