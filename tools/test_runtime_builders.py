"""Runtime builds must not confuse source-identical artifacts with distinct ABIs."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('runtime_builder', Path(__file__).with_name('build_jre.py'))
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class RuntimeBuilderTests(unittest.TestCase):
    def test_only_original_profile_inherits_legacy_pin(self):
        legacy = {'SHA256': 'old'}
        modern = {'SHA256': 'new'}
        lock = {'jre': legacy, 'profiles': {'2.39': {'jre': modern}}}
        self.assertIs(builder.runtime_entry(lock, '2.23', 'jre'), legacy)
        self.assertIs(builder.runtime_entry(lock, '2.39', 'jre'), modern)
        self.assertIsNone(builder.runtime_entry({'jre': legacy}, '2.39', 'jre'))

    def test_profile_pin_wins_over_legacy_pin(self):
        modern = {'SHA256': 'replacement'}
        lock = {'jre': {'SHA256': 'legacy'}, 'profiles': {'2.23': {'jre': modern}}}
        self.assertIs(builder.runtime_entry(lock, '2.23', 'jre'), modern)

    def test_new_profile_requires_explicit_record_and_does_not_modify_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'tools').mkdir()
            archive = root / 'pocketmanga-jre.tar'
            archive.write_bytes(b'new ABI runtime')
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            # Even an identical legacy digest cannot approve a new ABI.
            lock = root / 'tools/runtime-packages.json'
            original = json.dumps({'jre': {'Version': '17', 'SHA256': digest}})
            lock.write_text(original)
            with mock.patch.object(builder, 'ROOT', root), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(SystemExit, 'No reviewed jre digest'):
                    builder.verify_runtime(archive, '2.39', 'jre', False)
                self.assertFalse((root / 'runtime-entry.json').exists())
                builder.verify_runtime(archive, '2.39', 'jre', True)
            self.assertEqual(lock.read_text(), original)
            entry = json.loads((root / 'runtime-entry.json').read_text())['jre']
            self.assertEqual(entry, {'Version': '17', 'SHA256': digest, 'Glibc': '2.39'})

    def test_reviewed_profile_mismatch_is_fatal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'tools').mkdir()
            archive = root / 'pocketmanga-image.tar'
            archive.write_bytes(b'changed build')
            (root / 'tools/runtime-packages.json').write_text(json.dumps({
                'images': {'SHA256': 'legacy'},
                'profiles': {'2.39': {'images': {'SHA256': 'reviewed'}}},
            }))
            with mock.patch.object(builder, 'ROOT', root), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(SystemExit, 'differs from the pinned build'):
                    builder.verify_runtime(archive, '2.39', 'images', False)
            self.assertFalse((root / 'runtime-entry.json').exists())

    def test_verified_profile_does_not_write_record(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'tools').mkdir()
            archive = root / 'pocketmanga-jre.tar'
            archive.write_bytes(b'approved build')
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            (root / 'tools/runtime-packages.json').write_text(json.dumps({
                'jre': {}, 'profiles': {'2.39': {'jre': {'SHA256': digest}}},
            }))
            with mock.patch.object(builder, 'ROOT', root), contextlib.redirect_stdout(io.StringIO()):
                builder.verify_runtime(archive, '2.39', 'jre', False)
            self.assertFalse((root / 'runtime-entry.json').exists())


if __name__ == '__main__':
    unittest.main()
