#!/usr/bin/env python3
"""Run the production ARM decoder with its selected glibc sysroot under QEMU.

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
    parser.add_argument('--glibc',choices=('2.23','2.39'),default='2.23')
    parser.add_argument('--toolchain-image',help='Matching local or registry builder image')
    args=parser.parse_args()
    toolchain=args.toolchain_image or f'pocketmanga-cross:glibc-{args.glibc}'
    if not args.toolchain_image:
        subprocess.run(['docker','build','--target','toolchain','--build-arg',f'GLIBC_VERSION={args.glibc}','-t',toolchain,str(ROOT/'tools/jre')],check=True)
    image=f'pocketmanga-images:glibc-{args.glibc}'
    subprocess.run(['docker','build','-f',str(ROOT/'tools/image/Dockerfile'),'--target','image','--build-arg',f'GLIBC_VERSION={args.glibc}','--build-arg',f'TOOLCHAIN_IMAGE={toolchain}','-t',image,str(ROOT)],check=True)
    with tempfile.TemporaryDirectory(prefix='pocketmanga-image-arm-') as temporary:
        fixtures=pathlib.Path(temporary)
        png(fixtures/'source.png',53,173)
        for extension in ('jpg','webp','gif','avif','heic','jxl','jp2'):
            subprocess.run([args.vips,'copy',str(fixtures/'source.png'),str(fixtures/('source.'+extension))],check=True)
        png(fixtures/'horizontal.png',173,53)
        png(fixtures/'large.png',5000,3617)
        subprocess.run(['docker','run','--rm','-v',str(fixtures)+':/fixtures:ro','--entrypoint','/bin/sh',image,'-c',
            'qemu-arm -L "$(arm-pocketbook-linux-gnueabi-gcc -print-sysroot)" /work/out/pocketmanga-image-smoke /fixtures/*'],check=True)
    print(f'PASS ARM/glibc {args.glibc}: eight formats and large PNG disk spill')
if __name__=='__main__':main()
