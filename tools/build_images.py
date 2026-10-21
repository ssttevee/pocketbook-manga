#!/usr/bin/env python3
"""Build the pinned Mihon-compatible image runtime for the Verse's glibc 2.23.

Uses only JPEG, PNG/APNG, WebP, GIF, AVIF, HEIF, JPEG XL and JPEG 2000
loaders. PDF, SVG, TIFF, ImageMagick, video and document loaders are disabled.
"""
import argparse,hashlib,json,pathlib,subprocess,tempfile,shutil
ROOT=pathlib.Path(__file__).resolve().parent.parent

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=pathlib.Path,default=ROOT/'.runtime-cache/image')
    parser.add_argument('--host',action='store_true',help='Build only the test bridge against host pkg-config vips')
    args=parser.parse_args()
    args.output.mkdir(parents=True,exist_ok=True)
    if args.host:
        import platform
        pkg='/opt/homebrew/bin/pkg-config' if pathlib.Path('/opt/homebrew/bin/pkg-config').exists() else 'pkg-config'
        flags=subprocess.check_output([pkg,'--cflags','--libs','vips'],text=True).split()
        suffix='dylib' if platform.system()=='Darwin' else 'so'
        library=args.output/('libpocketmanga-image.'+suffix)
        subprocess.run(['cc','-dynamiclib' if suffix=='dylib' else '-shared','-fPIC','-O2',str(ROOT/'src/vips_bridge.c'),*flags,'-o',str(library)],check=True)
        print(library);return
    subprocess.run(['docker','build','--target','toolchain','-t','pocketmanga-cross:local',str(ROOT/'tools/jre')],check=True)
    with tempfile.TemporaryDirectory(prefix='pocketmanga-images-',dir=args.output.parent) as temporary:
        subprocess.run(['docker','build','-f',str(ROOT/'tools/image/Dockerfile'),'--target','export','--output',f'type=local,dest={temporary}',str(ROOT)],check=True)
        for source in pathlib.Path(temporary).iterdir():
            target=args.output/source.name
            if target.is_dir():shutil.rmtree(target)
            elif target.exists():target.unlink()
            shutil.move(str(source),target)
    archive=args.output/'pocketmanga-image.tar'
    digest=hashlib.sha256(archive.read_bytes()).hexdigest()
    print(f'{digest}  {archive}')
    pinned=json.loads((ROOT/'tools/runtime-packages.json').read_text())['images']['SHA256']
    if digest!=pinned:raise SystemExit('Image runtime differs from pinned build; update tools/runtime-packages.json if decoder inputs changed intentionally')
    print('Run tools/test_image_regions.py against the host bridge and package_device.py to bundle the ARM runtime.')
if __name__=='__main__':main()
