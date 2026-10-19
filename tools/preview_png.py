#!/usr/bin/env python3
"""Losslessly wrap fake-InkView P5 screenshots as grayscale PNGs."""
import argparse, pathlib, struct, zlib

def chunk(kind, data):
    return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))

def convert(path):
    magic, dimensions, maximum, pixels = path.read_bytes().split(b'\n', 3)
    width, height = map(int, dimensions.split())
    if magic != b'P5' or maximum != b'255' or len(pixels) != width * height:
        raise ValueError('Expected a packed 8-bit fake-InkView screenshot: ' + str(path))
    rows = b''.join(b'\0' + pixels[y * width:(y + 1) * width] for y in range(height))
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!IIBBBBB', width, height, 8, 0, 0, 0, 0))
    path.with_suffix('.png').write_bytes(png + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('paths', type=pathlib.Path, nargs='*')
    args = parser.parse_args()
    for path in args.paths or sorted(pathlib.Path('preview').glob('*.pgm')):
        convert(path)
