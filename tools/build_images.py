#!/usr/bin/env python3
"""Build the pinned Mihon-compatible image runtime for a PocketBook glibc profile.

Uses only JPEG, PNG/APNG, WebP, GIF, AVIF, HEIF, JPEG XL and JPEG 2000
loaders. PDF, SVG, TIFF, ImageMagick, video and document loaders are disabled.
"""
import argparse,pathlib,subprocess,tempfile,shutil
from build_jre import verify_runtime
ROOT=pathlib.Path(__file__).resolve().parent.parent

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=pathlib.Path)
    parser.add_argument('--glibc',choices=('2.23','2.39'),default='2.23')
    parser.add_argument('--toolchain-image',help='Published builder image; skips building the local cross toolchain')
    parser.add_argument('--record-digest',action='store_true',help='Record a new runtime digest for review instead of comparing the lock')
    parser.add_argument('--host',action='store_true',help='Build only the test bridge against host pkg-config vips')
    args=parser.parse_args()
    if args.output is None:
        args.output=ROOT/'.runtime-cache'/('image' if args.glibc=='2.23' else f'image-glibc-{args.glibc}')
    args.output.mkdir(parents=True,exist_ok=True)
    if args.host:
        import platform
        pkg='/opt/homebrew/bin/pkg-config' if pathlib.Path('/opt/homebrew/bin/pkg-config').exists() else 'pkg-config'
        flags=subprocess.check_output([pkg,'--cflags','--libs','vips'],text=True).split()
        suffix='dylib' if platform.system()=='Darwin' else 'so'
        library=args.output/('libpocketmanga-image.'+suffix)
        subprocess.run(['cc','-dynamiclib' if suffix=='dylib' else '-shared','-fPIC','-O2',str(ROOT/'src/vips_bridge.c'),*flags,'-o',str(library)],check=True)
        print(library);return
    toolchain=args.toolchain_image or f'pocketmanga-cross:glibc-{args.glibc}'
    if not args.toolchain_image:
        subprocess.run(['docker','build','--target','toolchain','--build-arg',f'GLIBC_VERSION={args.glibc}','-t',toolchain,str(ROOT/'tools/jre')],check=True)
    with tempfile.TemporaryDirectory(prefix='pocketmanga-images-',dir=args.output.parent) as temporary:
        subprocess.run(['docker','build','-f',str(ROOT/'tools/image/Dockerfile'),'--target','export','--build-arg',f'TOOLCHAIN_IMAGE={toolchain}','--build-arg',f'GLIBC_VERSION={args.glibc}','--output',f'type=local,dest={temporary}',str(ROOT)],check=True)
        for source in pathlib.Path(temporary).iterdir():
            target=args.output/source.name
            if target.is_dir():shutil.rmtree(target)
            elif target.exists():target.unlink()
            shutil.move(str(source),target)
    archive=args.output/'pocketmanga-image.tar'
    verify_runtime(archive,args.glibc,'images',args.record_digest)
    print('Run tools/test_image_regions.py against the host bridge and package_device.py to bundle the ARM runtime.')
if __name__=='__main__':main()
