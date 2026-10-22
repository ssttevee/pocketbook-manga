"""A reused package staging directory must never publish reader data."""
import importlib.util
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('package_device', Path(__file__).with_name('package_device.py'))
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PackageTests(unittest.TestCase):
    def test_reused_native_build_cannot_select_another_runtime(self):
        lock = package.runtime_lock('2.23', None)
        package.validate_profile('2.23', lock, {'cpu': 'armv7', 'abi': 'softfp', 'glibc': '2.23'})
        with self.assertRaisesRegex(ValueError, 'Native build target'):
            package.validate_profile('2.23', lock, {'cpu': 'armv7', 'abi': 'softfp', 'glibc': '2.39'})
        with self.assertRaisesRegex(ValueError, 'Native build target'):
            package.validate_profile('2.23', lock, {'cpu': 'armv7', 'abi': 'hard', 'glibc': '2.23'})

    def test_mixed_runtime_manifest_is_rejected(self):
        lock = package.runtime_lock('2.23', None)
        lock['images']['Glibc'] = '2.39'
        with self.assertRaisesRegex(ValueError, 'images runtime'):
            package.validate_profile('2.23', lock, package.PROFILES['2.23'])

    def test_unreviewed_profile_requires_manifest(self):
        # Until a runtime is reviewed, it cannot inherit the other ABI's pins.
        from unittest.mock import patch
        with patch.dict(package.LOCK, {'profiles': {}}):
            with self.assertRaisesRegex(ValueError, 'No reviewed runtime pins'):
                package.runtime_lock('2.39', None)

    def test_archive_only_contains_application_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            files = (
                'pocketmanga.app', 'pocketmanga-log.app',
                'pocketmanga/bin/pocketmanga', 'pocketmanga/bin/pocketmanga-worker',
                'pocketmanga/runtime/tachi-host.jar',
                'pocketmanga/tachi.sqlite3', 'pocketmanga/tachi.sqlite3-journal',
                'pocketmanga/library.json', 'pocketmanga/progress.json',
                'pocketmanga/downloads/page.webp', 'unrelated.app',
            )
            for relative in files:
                path = root / 'applications' / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(relative)
            archive = root / 'app.tar.gz'
            package.write_archive(root, archive)
            with tarfile.open(archive) as tar:
                shipped = {entry.name for entry in tar if entry.isfile()}
            self.assertEqual({'applications/' + path for path in files[:5]}, shipped)
            for relative in files:
                self.assertEqual(relative, (root / 'applications' / relative).read_text())


if __name__ == '__main__':
    unittest.main()
