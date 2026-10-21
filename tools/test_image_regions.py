#!/usr/bin/env python3
"""Exercise the production image bridge using generated, copyright-free fixtures.

Requires the host bridge shared library and a libvips CLI with encoders for the
eight formats Mihon recognizes. No fixture, encoder, or Python dependency ships
on the reader. Example:
  python3 tools/test_image_regions.py --library zig-out/lib/libpocketmanga-image.dylib
"""

import argparse
import ctypes as C
import math
import pathlib
import shutil
import struct
import subprocess
import tempfile
import threading
import queue
import zlib


def png(path, width, height, pixel):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    rows = b"".join(b"\0" + b"".join(bytes(pixel(x, y)) for x in range(width)) for y in range(height))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def animated_gif(path):
    # Two 2x3 frames: solid white, then solid black. LZW clear codes keep each
    # literal at three bits, making this fixture independent of encoder tools.
    data = bytearray(b"GIF89a\x02\0\x03\0\x80\0\0\0\0\0\xff\xff\xff")
    for colour in (1, 0):
        codes = [c for _ in range(6) for c in (4, colour)] + [5]
        packed = sum(code << (i * 3) for i, code in enumerate(codes)).to_bytes(math.ceil(len(codes) * 3 / 8), "little")
        data += b"\x21\xf9\x04\0\x01\0\0\0\x2c\0\0\0\0\x02\0\x03\0\0\x02" + bytes([len(packed)]) + packed + b"\0"
    path.write_bytes(data + b"\x3b")


class Bridge:
    def __init__(self, library):
        self.lib = C.CDLL(str(library.resolve()))
        self.lib.pmi_probe.argtypes = [C.c_char_p, C.POINTER(C.c_int), C.POINTER(C.c_int)]
        self.lib.pmi_open.argtypes = [C.c_char_p, C.c_double, C.POINTER(C.c_int), C.POINTER(C.c_int)]
        self.lib.pmi_open.restype = C.c_void_p
        self.lib.pmi_region.argtypes = [C.c_void_p, C.c_int, C.c_int, C.c_int, C.c_int, C.c_void_p, C.c_size_t]
        self.lib.pmi_close.argtypes = [C.c_void_p]
        self.lib.pmi_error.restype = C.c_char_p
        assert self.lib.pmi_init() == 0, self.error()

    def error(self):
        return self.lib.pmi_error().decode(errors="replace")

    def probe(self, path):
        w, h = C.c_int(), C.c_int()
        result = self.lib.pmi_probe(bytes(path), C.byref(w), C.byref(h))
        return result, (w.value, h.value)

    def open(self, path, scale=1):
        w, h = C.c_int(), C.c_int()
        handle = self.lib.pmi_open(bytes(path), scale, C.byref(w), C.byref(h))
        assert handle, f"{path.name}: {self.error()}"
        return handle, w.value, h.value

    def region(self, handle, x, y, width, height, padding=0):
        stride = width + padding
        buffer = (C.c_ubyte * (stride * height))(*([0xA5] * (stride * height)))
        result = self.lib.pmi_region(handle, x, y, width, height, buffer, stride)
        assert result == 0, self.error()
        for row in range(height):
            assert bytes(buffer[row * stride + width:(row + 1) * stride]) == b"\xa5" * padding
        return b"".join(bytes(buffer[row * stride:row * stride + width]) for row in range(height))


def verify_regions(bridge, path, scale):
    handle, width, height = bridge.open(path, scale)
    try:
        whole = bridge.region(handle, 0, 0, width, height)
        # Irregular strip sizes deliberately cross libvips tile boundaries.
        for tile_w, tile_h in ((width, 73), (89, height), (131, 97)):
            for y in range(0, height, tile_h):
                for x in range(0, width, tile_w):
                    w, h = min(tile_w, width - x), min(tile_h, height - y)
                    part = bridge.region(handle, x, y, w, h, padding=7)
                    expected = b"".join(whole[(y + row) * width + x:(y + row) * width + x + w] for row in range(h))
                    assert part == expected, (path.name, scale, x, y, w, h)
        buffer = (C.c_ubyte * 16)()
        for rect in ((-1, 0, 1, 1), (0, -1, 1, 1), (width, 0, 1, 1), (0, height, 1, 1), (0, 0, 0, 1)):
            assert bridge.lib.pmi_region(handle, *rect, buffer, 4) != 0
        assert bridge.lib.pmi_region(handle, 0, 0, 4, 1, buffer, 3) != 0
    finally:
        bridge.lib.pmi_close(handle)


def run(args, root):
    bridge = Bridge(args.library)
    count = 0
    for name, width, height in (("vertical", 113, 1157), ("horizontal", 1157, 113)):
        path = root / (name + ".png")
        png(path, width, height, lambda x, y: ((x * 7 + y * 3) % 256, (x + y * 11) % 256, (x * 13 + y) % 256, 255))
        for scale in (1, 0.617, 2):
            verify_regions(bridge, path, scale)
            count += 1

    # A persistent pipeline may be opened by one decode task and requested by
    # the next. VipsRegion itself must never cross those thread boundaries.
    results, release = queue.Queue(), threading.Event()
    def open_on_worker():
        try:
            results.put(bridge.open(root / "vertical.png", 0.617))
        except BaseException as error:
            results.put(error)
        release.wait()
    worker = threading.Thread(target=open_on_worker)
    worker.start()
    try:
        opened = results.get(timeout=10)
        if isinstance(opened, BaseException):
            raise opened
        handle, width, height = opened
        try:
            bridge.region(handle, 0, 0, width, min(97, height))
            bridge.region(handle, 0, max(0, height - 73), width, min(73, height))
        finally:
            bridge.lib.pmi_close(handle)
    finally:
        release.set()
        worker.join(timeout=10)
    count += 1

    source = root / "formats.png"
    png(source, 53, 37, lambda x, y: (x * 4, y * 6, (x + y) * 2, 255))
    # Mihon ImageUtil.findImageType: JPEG, PNG, WebP, GIF, AVIF, HEIF, JXL, JP2.
    # TIFF is available in its dependency but deliberately not recognized by it.
    for extension in ("jpg", "png", "webp", "gif", "avif", "heic", "jxl", "jp2"):
        target = root / ("codec." + extension)
        subprocess.run([args.vips, "copy", str(source), str(target)], check=True, stdout=subprocess.DEVNULL)
        assert bridge.probe(target) == (0, (53, 37)), (extension, bridge.error())
        verify_regions(bridge, target, 0.73)
        count += 1

    for extension in ("tiff", "ppm", "v"):
        target = root / ("denied." + extension)
        subprocess.run([args.vips, "copy", str(source), str(target)], check=True, stdout=subprocess.DEVNULL)
        assert bridge.probe(target)[0] != 0, f"Unexpectedly accepted {extension}"
        count += 1
    # BMP signature: a valid 1x1 24-bit BMP, independent of optional vips savers.
    bmp = root / "denied.bmp"
    bmp.write_bytes(b"BM" + struct.pack("<IHHI", 58, 0, 0, 54) + struct.pack("<IiiHHIIiiII", 40, 1, 1, 1, 24, 0, 4, 0, 0, 0, 0) + b"\xff\xff\xff\0")
    assert bridge.probe(bmp)[0] != 0
    count += 1

    alpha = root / "transparent.png"
    png(alpha, 37, 29, lambda x, y: (0, 0, 0, 0))
    for scale in (1, 0.53):
        handle, w, h = bridge.open(alpha, scale)
        try:
            assert bridge.region(handle, 0, 0, w, h) == b"\xff" * (w * h), "Transparency must composite onto white"
        finally:
            bridge.lib.pmi_close(handle)
        count += 1

    # Hidden blue RGB must not bleed into opaque red at a resampling boundary.
    # Flattening before filtering is equivalent to filtering the white-backed
    # image; filtering unassociated RGBA first creates dark/coloured fringes.
    edge, backed = root / "alpha-edge.png", root / "white-backed.png"
    png(edge, 128, 17, lambda x, y: (255, 0, 0, 255) if x < 64 else (0, 0, 255, 0))
    png(backed, 128, 17, lambda x, y: (255, 0, 0, 255) if x < 64 else (255, 255, 255, 255))
    a, aw, ah = bridge.open(edge, 0.49)
    b, bw, bh = bridge.open(backed, 0.49)
    try:
        assert (aw, ah) == (bw, bh)
        assert bridge.region(a, 0, 0, aw, ah) == bridge.region(b, 0, 0, bw, bh), "Transparent RGB must not create resize halos"
    finally:
        bridge.lib.pmi_close(a)
        bridge.lib.pmi_close(b)
    count += 1

    animation = root / "animated.gif"
    animated_gif(animation)
    handle, w, h = bridge.open(animation)
    try:
        assert (w, h) == (2, 3)
        assert bridge.region(handle, 0, 0, w, h) == b"\xff" * 6, "Reader must use the first animation frame"
    finally:
        bridge.lib.pmi_close(handle)
    count += 1

    jpeg = (root / "codec.jpg").read_bytes()
    exif = b"Exif\0\0II\x2a\0\x08\0\0\0\x01\0" + struct.pack("<HHIHHI", 0x112, 3, 1, 6, 0, 0)
    rotated = root / "oriented.jpg"
    rotated.write_bytes(jpeg[:2] + b"\xff\xe1" + struct.pack(">H", len(exif) + 2) + exif + jpeg[2:])
    assert bridge.probe(rotated) == (0, (37, 53)), bridge.error()
    original, ow, oh = bridge.open(root / "codec.jpg")
    oriented, rw, rh = bridge.open(rotated)
    try:
        a = bridge.region(original, 0, 0, ow, oh)
        b = bridge.region(oriented, 0, 0, rw, rh)
        assert b == bytes(a[(oh - 1 - x) * ow + y] for y in range(rh) for x in range(rw)), "EXIF rotation must transform pixels too"
    finally:
        bridge.lib.pmi_close(original)
        bridge.lib.pmi_close(oriented)
    count += 1

    for filename, data in (("garbage.png", b"not an image"), ("truncated.png", source.read_bytes()[:30])):
        target = root / filename
        target.write_bytes(data)
        assert bridge.probe(target)[0] != 0
        count += 1
    # A plausible header can pass probing while lazy pixel decoding fails.
    # It must report that error rather than silently publishing a partial page.
    truncated = root / "truncated-pixels.png"
    data = source.read_bytes()
    truncated.write_bytes(data[:len(data) // 2])
    w, h = C.c_int(), C.c_int()
    handle = bridge.lib.pmi_open(bytes(truncated), 1, C.byref(w), C.byref(h))
    if handle:
        try:
            buffer = (C.c_ubyte * (w.value * h.value))()
            assert bridge.lib.pmi_region(handle, 0, 0, w.value, h.value, buffer, w.value) != 0, "Truncated pixels must fail decoding"
        finally:
            bridge.lib.pmi_close(handle)
    count += 1
    oversized = root / "oversized.png"
    raw = source.read_bytes()
    ihdr = struct.pack(">II", 32768, 32768) + raw[24:29]
    oversized.write_bytes(raw[:16] + ihdr + struct.pack(">I", zlib.crc32(b"IHDR" + ihdr)) + raw[33:])
    assert bridge.probe(oversized)[0] != 0, "Oversized source must fail before decoding pixels"
    count += 1
    for scale in (0, -1, float("nan"), float("inf"), 4097):
        w, h = C.c_int(), C.c_int()
        assert not bridge.lib.pmi_open(bytes(source), scale, C.byref(w), C.byref(h))
        count += 1
    w, h = C.c_int(), C.c_int()
    assert not bridge.lib.pmi_open(bytes(source), 4096, C.byref(w), C.byref(h)), "Upscaling must respect the output pixel budget"
    count += 1
    print(f"{count} image bridge cases passed (all eight Mihon formats, both axes, region seams, alpha, orientation, animation, invalid inputs)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=pathlib.Path, required=True)
    parser.add_argument("--vips", default=shutil.which("vips") or "vips")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="pocketmanga-image-tests-") as directory:
        run(args, pathlib.Path(directory))


if __name__ == "__main__":
    main()
