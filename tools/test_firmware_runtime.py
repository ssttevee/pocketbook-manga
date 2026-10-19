#!/usr/bin/env python3
"""Run the shipped launcher/binary in official firmware containers as reader.

Only local Docker images are made. Extracted proprietary files stay outside
this repo. A DNS/HTTP sidecar supplies the extension's authenticated image.
"""
import argparse, pathlib, shutil, subprocess, tarfile, tempfile, time, uuid
ROOT = pathlib.Path(__file__).resolve().parent.parent

def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)

def fixture(directory):
    classes = directory/'classes'
    classes.mkdir(parents=True, exist_ok=True)
    jar = ROOT.parent/'zig-tachi/host/build/libs/tachi-host.jar'
    run('javac', '--release', '17', '-classpath', str(jar), '-d', str(classes), str(ROOT/'tools/fixture/FixtureSource.java'))
    shutil.copy2(ROOT/'tools/fixture/AndroidManifest.xml', classes/'AndroidManifest.xml')
    target = directory/'source.jar'
    run('jar', '--create', '--file', str(target), '-C', str(classes), '.')
    return target

def root_tar(source, target):
    def select(info):
        name = info.name.removeprefix('./')
        if name == 'dev': return None
        if name.startswith(('lost+found', 'lib/modules', 'lib/firmware')): return None
        if name.startswith('ebrmain/') and not name.startswith(('ebrmain/lib', 'ebrmain/cramfs/lib')) and name != 'ebrmain/cramfs': return None
        if name.endswith('.log'): return None
        info.uid = info.gid = 0
        info.uname = info.gname = 'root'
        return info
    with tarfile.open(target, 'w') as tar:
        tar.add(source, arcname='.', filter=select)
        dev = tarfile.TarInfo('dev')
        dev.type = tarfile.DIRTYPE
        dev.mode = 0o755
        tar.addfile(dev)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rootfs', type=pathlib.Path, required=True)
    parser.add_argument('--version', choices=['6.9', '6.10'], required=True)
    parser.add_argument('--deny-new-syscalls', action='store_true')
    parser.add_argument('--emulator-image', default='pocketmanga-kernel310-test:local')
    parser.add_argument('--log-launcher', action='store_true')
    parser.add_argument('--parent-exit', action='store_true', help='Kill UI cleanup deliberately and verify its worker cannot outlive it')
    parser.add_argument('--mode', choices=['sources', 'fixture'], default='fixture')
    args = parser.parse_args()
    if not (args.rootfs/'ebrmain/lib/libinkview.so').exists(): raise SystemExit('Extract rootfs + ebrmain/cramfs/lib first')
    tag = 'pocketmanga-firmware-' + args.version + ('-linux310' if args.deny_new_syscalls else '-native') + ':local'
    output = ROOT/'dist/firmware-tests'
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='pocketmanga-firmware-test-') as tmp:
        context = pathlib.Path(tmp)
        jar = fixture(context/'fixture')
        root_tar(args.rootfs, context/'rootfs.tar')
        shutil.copytree(ROOT/'dist/applications', context/'applications', symlinks=True)
        # A rebuilt staging bundle may contain data from earlier manual tests.
        app = context/'applications/pocketmanga'
        for child in app.iterdir():
            if child.name not in ('runtime', 'bin'):
                if child.is_dir(): shutil.rmtree(child)
                else: child.unlink()
        shutil.copy2(jar, context/'source.jar')
        if args.deny_new_syscalls:
            container = subprocess.check_output(['docker','create',args.emulator_image], text=True).strip()
            try: run('docker','cp',container+':/qemu-arm',str(context/'qemu-arm'))
            finally: run('docker','rm',container, stdout=subprocess.DEVNULL)
        else: (context/'qemu-arm').write_bytes(b'')
        shutil.copy2(ROOT/'tools/kernel310-launch.sh',context/'kernel310-launch.sh')
        shutil.copy2(ROOT/'tools/Dockerfile.firmware-test', context/'Dockerfile')
        run('docker', 'build', '--platform', 'linux/arm/v5', '-t', tag, str(context))
        sidecar = 'pocketmanga-fixture-' + uuid.uuid4().hex[:12]
        run('docker', 'run', '-d', '--rm', '--name', sidecar, '--dns', '127.0.0.1', '-v', str(ROOT)+':/work:ro', 'pocketmanga-arm-test:local', 'python3', '-u', '/work/tools/fixture/firmware_server.py')
        try:
            time.sleep(1)
            command = ['docker', 'run', '--rm', '--platform', 'linux/arm/v5', '--network', 'container:'+sidecar,
                '-e', 'POCKETMANGA_RUNTIME_CHECK='+args.mode, '-e', 'POCKETMANGA_FIXTURE=/var/tmp/source.jar',
                '-e', 'POCKETMANGA_FIXTURE_HOST=fixture.pocketmanga.test', '-e', 'LD_BIND_NOW=1', '-e', 'POCKETMANGA_WORKER_TEST=1', '-e', 'POCKETMANGA_WORKER_IDLE_MS=1000']
            command += ['--entrypoint', '/bin/sh']
            if args.deny_new_syscalls:
                command += ['-e', 'POCKETMANGA_EXPECT_ENOSYS=1', '-e', 'POCKETMANGA_WORKER_EMULATOR=/qemu-arm', '-e', 'QEMU_POCKETMANGA_KERNEL310=1', '-e', 'QEMU_UNAME=3.10.65']
            if args.parent_exit: command += ['-e', 'POCKETMANGA_PARENT_EXIT_TEST=1']
            command += [tag]
            launcher = '/mnt/ext1/applications/pocketmanga-log.app' if args.log_launcher else '/mnt/ext1/applications/pocketmanga.app'
            if args.parent_exit:
                prefix = '/bin/sh /kernel310-launch.sh ' if args.deny_new_syscalls else ''
                shell = prefix + '/mnt/ext1/applications/pocketmanga.app & owner=$!; wait "$owner" || exit $?; '
                shell += 'worker=$(cat /mnt/ext1/applications/pocketmanga/.worker-pid); '
                shell += 'for attempt in 1 2 3 4 5; do if [ ! -r /proc/$worker/status ]; then echo "Worker exited after abrupt UI exit"; exit 0; fi; '
                shell += 'state=$(cat /proc/$worker/status); case "$state" in *"State:"*"Z (zombie)"*) echo "Worker exited after abrupt UI exit"; exit 0;; esac; sleep 1; done; exit 1'
                command += ['-c', shell]
            elif args.log_launcher:
                prefix = '/bin/sh /kernel310-launch.sh ' if args.deny_new_syscalls else ''
                command += ['-c', prefix+launcher+'; result=$?; cat /mnt/ext1/applications/pocketmanga.log; exit "$result"']
            elif args.deny_new_syscalls: command += ['/kernel310-launch.sh', launcher]
            else: command += [launcher]
            result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            suffix = ('-parent-exit' if args.parent_exit else '') + ('-linux310' if args.deny_new_syscalls else '') + ('-log' if args.log_launcher else '')
            log = output/(args.version+'-'+args.mode+suffix+'.log')
            log.write_text(result.stdout)
            print(result.stdout, end='', flush=True)
            result.check_returncode()
            if args.parent_exit:
                if 'Worker exited after abrupt UI exit' not in result.stdout: raise RuntimeError('Orphan worker')
                print('PASS: parent exit', args.version, suffix)
                return
            for expected in ['InkView loaded with RTLD_NOW', 'ARM JNI host:', 'Native UI mappings verified', 'Bundled glibc mappings verified', 'Worker crash reported; retry restarted', 'Worker rejects unsupported protocol', 'Worker exits on pipe EOF', 'Idle worker exits and is reaped', 'Linux file metadata, repeated mkdir and entropy passed']:
                if expected not in result.stdout: raise RuntimeError('Missing check: '+expected)
            if args.deny_new_syscalls and 'Raw ARM statx and getrandom return ENOSYS' not in result.stdout: raise RuntimeError('Syscall denial did not reach the ARM guest')
            if args.mode == 'fixture' and 'authenticated image download passed' not in result.stdout: raise RuntimeError('Fixture did not finish')
            dns = subprocess.check_output(['docker','logs',sidecar], text=True, stderr=subprocess.STDOUT)
            if args.mode == 'fixture' and 'DNS fixture.pocketmanga.test' not in dns: raise RuntimeError('JVM did not exercise DNS')
            (output/(args.version+'-dns.log')).write_text(dns)
            print('PASS:', args.version, args.mode, suffix, 'as uid 1000, cwd /; log:', log)
        finally:
            subprocess.run(['docker', 'stop', sidecar], check=False, stdout=subprocess.DEVNULL)

if __name__ == '__main__': main()
