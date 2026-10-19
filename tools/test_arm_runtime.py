#!/usr/bin/env python3
"""Developer-only ARM/JNI integration check; no test tools ship in the device bundle."""
import argparse, pathlib, subprocess
ROOT=pathlib.Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser()
parser.add_argument('mode',choices=['sources','repo','fixture'],default='fixture',nargs='?')
args=parser.parse_args()
jar=ROOT.parent/'zig-tachi/host/build/libs/tachi-host.jar'
classes=ROOT/'dist/fixture/classes'
classes.mkdir(parents=True,exist_ok=True)
if args.mode=='fixture':
    subprocess.run(['javac','--release','17','-classpath',str(jar),'-d',str(classes),str(ROOT/'tools/fixture/FixtureSource.java')],check=True)
    (classes/'AndroidManifest.xml').write_bytes((ROOT/'tools/fixture/AndroidManifest.xml').read_bytes())
    subprocess.run(['jar','--create','--file',str(ROOT/'dist/fixture/source.jar'),'-C',str(classes),'.'],check=True)
scratch=ROOT/'dist/arm-test-data'
scratch.mkdir(exist_ok=True)
link=scratch/'runtime'
if not link.is_symlink(): link.symlink_to('../applications/pocketmanga/runtime',target_is_directory=True)
libs=':'.join(['/work/dist/applications/pocketmanga/runtime/lib','/work/dist/test-sysroot/lib/arm-linux-gnueabi','/work/dist/test-sysroot/usr/lib/arm-linux-gnueabi','/work/dist/applications/pocketmanga/runtime/jre/lib','/work/dist/applications/pocketmanga/runtime/jre/lib/server'])
# All shell tokens here are fixed tool paths / mode choices, not user-provided strings.
command='qemu-arm -L /work/dist/test-sysroot /work/dist/applications/pocketmanga/runtime/lib/ld-linux.so.3 --inhibit-cache --library-path '+libs+' /work/dist/applications/pocketmanga/bin/pocketmanga-worker /work/dist/arm-test-data '+args.mode
if args.mode=='fixture': command='python3 /work/tools/fixture/server.py & exec '+command+' /work/dist/fixture/source.jar'
else: command='exec '+command
subprocess.run(['docker','run','--rm','-v',str(ROOT)+':/work','-w','/work','pocketmanga-arm-test:local','sh','-c',command],check=True)
