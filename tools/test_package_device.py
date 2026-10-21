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
