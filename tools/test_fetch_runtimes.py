"""A release downloader must reject mutable or incomplete provenance early."""
import argparse
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import build_jre

import fetch_runtimes


class RuntimeReferenceTests(unittest.TestCase):
    def lock(self):
        image = lambda name: f'ghcr.io/example/{name}@sha256:' + 'a' * 64
        return {'builders': {'2.39': image('builder')},
                'runtime_images': {'2.39': {'jre': image('jvm'), 'images': image('decoders')}}}

    def test_each_provenance_reference_must_be_immutable(self):
        for component in ('builder', 'jre', 'images'):
            with self.subTest(component=component):
                lock = self.lock()
                if component == 'builder':
                    lock['builders']['2.39'] = 'ghcr.io/example/builder:latest'
                else:
                    lock['runtime_images']['2.39'][component] = f'ghcr.io/example/{component}:latest'
                with self.assertRaises(argparse.ArgumentTypeError):
                    fetch_runtimes.image_references(lock, '2.39')

    def test_profile_never_inherits_another_profile_image(self):
        with self.assertRaisesRegex(ValueError, 'glibc 2.23'):
            fetch_runtimes.image_references(self.lock(), '2.23')
        lock = self.lock()
        del lock['runtime_images']['2.39']['images']
        with self.assertRaisesRegex(ValueError, 'images'):
            fetch_runtimes.image_references(lock, '2.39')

    def test_wrong_archive_pin_preserves_previously_verified_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'tools').mkdir()
            lock = self.lock()
            lock['profiles'] = {'2.39': {'jre': {'SHA256': '0' * 64}}}
            (root / 'tools/runtime-packages.json').write_text(json.dumps(lock))
            output = root / 'cached'
            (output / 'jre').mkdir(parents=True)
            existing = output / 'jre/pocketmanga-jre.tar'
            existing.write_bytes(b'previously verified runtime')
            provenance = output / 'runtime-manifest.json'
            provenance.write_text('previously verified provenance')

            def bad_transport(image, destination):
                destination.mkdir(parents=True)
                (destination / 'pocketmanga-jre.tar').write_bytes(b'unreviewed runtime')

            with mock.patch.object(fetch_runtimes, 'ROOT', root), \
                    mock.patch.object(build_jre, 'ROOT', root), \
                    mock.patch.object(fetch_runtimes, 'extract_artifacts', bad_transport), \
                    contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(SystemExit, 'differs from the pinned build'):
                    fetch_runtimes.fetch('2.39', output)
            self.assertEqual(existing.read_bytes(), b'previously verified runtime')
            self.assertEqual(provenance.read_text(), 'previously verified provenance')


if __name__ == '__main__':
    unittest.main()
