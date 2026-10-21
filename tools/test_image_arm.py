#!/usr/bin/env python3
"""Run the production ARM decoder with its glibc 2.23 sysroot under QEMU.

Uses native libvips only to generate fixtures, never to decode the ARM results.
The >8 MiB RGBA PNG covers native disk spill, whose internal writer must remain
available even though external image encoders are stripped from the runtime.
"""
import argparse,pathlib,shutil,struct,subprocess,tempfile,zlib
ROOT=pathlib.Path(__file__).resolve().parent.parent

def png(path,width,height):
    def chunk(kind,data):return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data))
    compressor=zlib.compressobj();data=bytearray()
    for y in range(height):
        data.extend(compressor.compress(b'\0'+bytes((y%256,80,120,255))*width))
    data.extend(compressor.flush())
    path.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,6,0,0,0))+chunk(b'IDAT',data)+chunk(b'IEND',b''))

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vips',default=shutil.which('vips') or '/opt/homebrew/bin/vips')
    args=parser.parse_args()
    subprocess.run(['docker','build','-f',str(ROOT/'tools/image/Dockerfile'),'--target','image','-t','pocketmanga-images:local',str(ROOT)],check=True)
    with tempfile.TemporaryDirectory(prefix='pocketmanga-image-arm-') as temporary:
        fixtures=pathlib.Path(temporary)
        png(fixtures/'source.png',53,173)
        for extension in ('jpg','webp','gif','avif','heic','jxl','jp2'):
            subprocess.run([args.vips,'copy',str(fixtures/'source.png'),str(fixtures/('source.'+extension))],check=True)
        png(fixtures/'horizontal.png',173,53)
        png(fixtures/'large.png',5000,3617)
        subprocess.run(['docker','run','--rm','-v',str(fixtures)+':/fixtures:ro','--entrypoint','/bin/sh','pocketmanga-images:local','-c',
            'qemu-arm -L "$(arm-pocketbook-linux-gnueabi-gcc -print-sysroot)" /work/out/pocketmanga-image-smoke /fixtures/*'],check=True)
    print('PASS ARM/glibc 2.23: eight formats and large PNG disk spill')
if __name__=='__main__':main()
