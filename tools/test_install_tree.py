"""Installed reader trees must preserve dynamic-library links and permissions."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from install_tree import install


class InstallTreeTests(unittest.TestCase):
    def test_replaces_owned_tree_preserving_links_modes_and_siblings(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / 'cache', root / 'prefix/release'
            source.mkdir()
            binary = source / 'worker'
            binary.write_bytes(b'worker')
            binary.chmod(0o755)
            (source / 'libvips.so.42.20.7').write_bytes(b'library')
            (source / 'libvips.so.42').symlink_to('libvips.so.42.20.7')
            (source / 'directory-link').symlink_to('nested', target_is_directory=True)
            (source / 'nested').mkdir()
            (source / 'nested/data').write_bytes(b'data')
            destination.mkdir(parents=True)
            (destination / 'stale').write_bytes(b'old profile')
            sibling = destination.parent / 'keep'
            sibling.write_bytes(b'unrelated output')
            for _ in range(2):
                install(source, destination)
                self.assertTrue((destination / 'libvips.so.42').is_symlink())
                self.assertEqual('libvips.so.42.20.7', (destination / 'libvips.so.42').readlink().as_posix())
                self.assertTrue((destination / 'directory-link').is_symlink())
                self.assertEqual(0o755, (destination / 'worker').stat().st_mode & 0o777)
                self.assertFalse((destination / 'stale').exists())
                self.assertEqual(b'unrelated output', sibling.read_bytes())

    def test_failed_copy_preserves_previous_installation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / 'cache', root / 'installed'
            source.mkdir()
            destination.mkdir()
            (destination / 'keep').write_bytes(b'old output')
            with patch('install_tree.shutil.copytree', side_effect=OSError('disk full')):
                with self.assertRaisesRegex(OSError, 'disk full'):
                    install(source, destination)
            self.assertEqual(b'old output', (destination / 'keep').read_bytes())


if __name__ == '__main__':
    unittest.main()
