"""Opt-in integration coverage of Zig's real runtime artifact cache.

Run with POCKETMANGA_ZIG_CACHE_TEST=/absolute/path/to/zig and Python unittest.
Docker is replaced by a tiny artifact exporter; no runtime is compiled or pulled.
The test copies current source files and may reuse existing dependency packages.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

import runtime_cache

ROOT = Path(__file__).resolve().parent.parent


def artifact(component, glibc):
    return f'cache-fixture-{component}-glibc-{glibc}\n'.encode()


class RuntimeBuilderTrustTests(unittest.TestCase):
    def test_builder_must_be_immutable(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'tools').mkdir()
            (root / 'tools/runtime-packages.json').write_text(json.dumps({
                'builders': {'2.23': 'ghcr.io/example/builder:latest'},
            }))
            with mock.patch.object(runtime_cache, 'ROOT', root):
                with self.assertRaises(argparse.ArgumentTypeError):
                    runtime_cache.builder_reference('2.23')

    def test_missing_profile_cannot_inherit_another_profile_builder(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'tools').mkdir()
            builder = 'ghcr.io/example/builder@sha256:' + 'a' * 64
            (root / 'tools/runtime-packages.json').write_text(json.dumps({
                'builders': {'2.23': builder},
            }))
            with mock.patch.object(runtime_cache, 'ROOT', root):
                self.assertEqual(runtime_cache.builder_reference('2.23'), builder)
                with self.assertRaisesRegex(ValueError, 'glibc 2.39'):
                    runtime_cache.builder_reference('2.39')


@unittest.skipUnless(os.environ.get('POCKETMANGA_ZIG_CACHE_TEST'), 'Set POCKETMANGA_ZIG_CACHE_TEST for the Zig cache integration test')
class RuntimeCacheTests(unittest.TestCase):
    def test_real_zig_cache_invalidation_and_untrusted_output(self):
        zig = str(Path(os.environ['POCKETMANGA_ZIG_CACHE_TEST']).resolve())
        self.assertEqual(subprocess.check_output([zig, 'version'], text=True).strip(), '0.17.0')
        with tempfile.TemporaryDirectory(prefix='pocketmanga-runtime-cache-', dir='/tmp') as temporary:
            root = Path(temporary)
            source = root / 'source'
            source.mkdir()
            tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
            for name in {*tracked, 'tools/runtime_cache.py', 'tools/install_tree.py'}:
                if not name:
                    continue
                original = ROOT / name
                if not original.is_file():
                    continue
                target = source / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(original, target)
            # Reusing downloaded packages keeps this test focused on the Run
            # cache, independently of public-network dependency availability.
            if (ROOT / 'zig-pkg').is_dir():
                (source / 'zig-pkg').symlink_to(ROOT / 'zig-pkg', target_is_directory=True)
            lock_path = source / 'tools/runtime-packages.json'
            lock = json.loads(lock_path.read_text())
            for glibc in ('2.23', '2.39'):
                profile = lock.setdefault('profiles', {}).setdefault(glibc, {})
                for component in ('jre', 'images'):
                    entry = {**lock[component], **profile.get(component, {})}
                    entry['SHA256'] = hashlib.sha256(artifact(component, glibc)).hexdigest()
                    profile[component] = entry
            lock_path.write_text(json.dumps(lock))
            fake_bin = root / 'bin'
            fake_bin.mkdir()
            fake_docker = fake_bin / 'docker'
            fake_docker.write_text('''#!/usr/bin/env python3
import hashlib,json,os,pathlib,sys
args=sys.argv[1:]
if not args or args[0]!='build':
    raise SystemExit('Unexpected Docker operation in runtime cache test: '+repr(args))
component='images' if any(a.startswith('TOOLCHAIN_IMAGE=') for a in args) else 'jre'
glibc=next(a.split('=',1)[1] for a in args if a.startswith('GLIBC_VERSION='))
output=args[args.index('--output')+1]
destination=pathlib.Path(next(a.split('=',1)[1] for a in output.split(',') if a.startswith('dest=')))
destination.mkdir(parents=True,exist_ok=True)
name='pocketmanga-jre.tar' if component=='jre' else 'pocketmanga-image.tar'
data=f'cache-fixture-{component}-glibc-{glibc}\\n'.encode()
(destination/name).write_bytes(data)
(destination/'runtime-link').symlink_to(name)
(destination/(name+'.sha256')).write_text(hashlib.sha256(data).hexdigest()+'  '+name+'\\n')
if component=='jre':(destination/'classes.jsa').write_bytes(('CDS-'+glibc).encode())
with open(os.environ['POCKETMANGA_FAKE_DOCKER_LOG'],'a') as log:
    log.write(json.dumps({'component':component,'glibc':glibc,'args':args})+'\\n')
''')
            fake_docker.chmod(0o755)
            docker_log = root / 'docker.jsonl'
            environment = dict(os.environ)
            environment['PATH'] = str(fake_bin) + os.pathsep + environment.get('PATH', '')
            environment['POCKETMANGA_FAKE_DOCKER_LOG'] = str(docker_log)
            cache = root / 'local'

            def records():
                return [json.loads(line) for line in docker_log.read_text().splitlines()] if docker_log.exists() else []

            def build(glibc='2.23', succeeds=True):
                result = subprocess.run([
                    zig, 'build', 'runtimes', f'-Dglibc={glibc}', '--cache-dir', str(cache), '--summary', 'all',
                ], cwd=source, env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=240)
                if succeeds:
                    self.assertEqual(result.returncode, 0, result.stdout)
                else:
                    self.assertNotEqual(result.returncode, 0, 'Corrupted runtime cache was accepted:\n' + result.stdout)
                return result

            build()
            self.assertTrue((source / 'zig-out/runtimes/images/runtime-link').is_symlink())
            initial = records()
            self.assertEqual({entry['component'] for entry in initial}, {'jre', 'images'})
            build()
            self.assertEqual(records(), initial, 'An unchanged build invoked Docker instead of using Zig output caching')

            bridge = source / 'src/vips_bridge.c'
            bridge.write_bytes(bridge.read_bytes() + b'\n/* runtime cache invalidation fixture */\n')
            before = len(records())
            build()
            self.assertIn('images', {entry['component'] for entry in records()[before:]})

            before = len(records())
            build('2.39')
            changed = records()[before:]
            self.assertEqual({entry['component'] for entry in changed}, {'jre', 'images'})
            self.assertTrue(all(entry['glibc'] == '2.39' for entry in changed))
            before = records()
            build('2.23')
            self.assertEqual(records(), before, 'Returning to an unchanged profile discarded its cached runtime')

            previous_builder = lock['builders']['2.23']
            lock['builders']['2.23'] = previous_builder[:-1] + ('a' if previous_builder[-1] != 'a' else 'b')
            lock_path.write_text(json.dumps(lock))
            before = len(records())
            build()
            self.assertEqual({entry['component'] for entry in records()[before:]}, {'jre', 'images'})

            manifests = []
            for path in cache.rglob('runtime-manifest.json'):
                body = json.loads(path.read_text())
                if body.get('profile', {}).get('glibc') == '2.23' and body.get('builder') == lock['builders']['2.23']:
                    manifests.append((path, body))
            self.assertTrue(manifests, 'No provenance for the selected builder/profile was produced')
            for _, body in manifests:
                self.assertEqual(body['jre']['CDS_SHA256'], hashlib.sha256(b'CDS-2.23').hexdigest())

            # A forged provenance document must not make cached outputs trusted.
            for path, body in manifests:
                body['builder'] = 'ghcr.io/example/unreviewed@sha256:' + 'f' * 64
                path.write_text(json.dumps(body))
            before = records()
            build(succeeds=False)
            self.assertEqual(records(), before)
            for path, body in manifests:
                body['builder'] = lock['builders']['2.23']
                path.write_text(json.dumps(body))

            # CDS is deliberately outside the pinned tar; its manifest hash
            # must still detect corruption of a previously generated archive.
            cds_files = [path for path in cache.rglob('classes.jsa') if path.read_bytes() == b'CDS-2.23']
            self.assertTrue(cds_files)
            for path in cds_files:
                path.write_bytes(b'corrupted class-data archive')
            build(succeeds=False)
            self.assertEqual(records(), before)
            for path in cds_files:
                path.write_bytes(b'CDS-2.23')

            archives = [path for path in cache.rglob('pocketmanga-jre.tar') if path.read_bytes() == artifact('jre', '2.23')]
            self.assertTrue(archives)
            for path in archives:
                path.write_bytes(b'corrupted cached runtime')
            build(succeeds=False)
            self.assertEqual(records(), before, 'Verification failure unexpectedly rebuilt or accepted a modified cached runtime')


if __name__ == '__main__':
    unittest.main()
