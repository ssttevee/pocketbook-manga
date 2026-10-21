"""Keep only ELF dependencies reachable from the bridge, not build-time tools."""
import pathlib,re,subprocess
root=pathlib.Path('/work/out/lib')
keep=set();queue=[root/'libpocketmanga-image.so']
while queue:
    path=queue.pop()
    if path.name in keep:continue
    keep.add(path.name)
    real=path.resolve();keep.add(real.name)
    output=subprocess.check_output(['arm-pocketbook-linux-gnueabi-readelf','-d',str(real)],text=True)
    for name in re.findall(r'\(NEEDED\).*\[([^]]+)\]',output):
        candidate=root/name
        if candidate.exists():queue.append(candidate)
for path in root.iterdir():
    if path.name not in keep:path.unlink()
