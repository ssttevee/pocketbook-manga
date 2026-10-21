#!/usr/bin/env python3
"""Check the diagnostic launcher's shell handoff without reader hardware."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class LauncherTests(unittest.TestCase):
    def test_log_launcher_reuses_the_firmware_shell(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            normal = root / 'pocketmanga.app'
            normal.write_text('#!/missing/interpreter\nprintf "startup reached\\n"\nexit 17\n')
            normal.chmod(0o755)
            wrapper = root / 'pocketmanga-log.app'
            wrapper.write_text((ROOT / 'tools/pocketmanga-log.app').read_text().replace(
                '/mnt/ext1/applications', directory))
            result = subprocess.run(['/bin/sh', str(wrapper)], capture_output=True)
            output = (root / 'pocketmanga.log').read_text()
            self.assertEqual(result.returncode, 17, output)
            self.assertIn('PocketManga launcher diagnostics', output)
            self.assertIn('startup reached', output)
            self.assertEqual(result.stderr, b'')


if __name__ == '__main__':
    unittest.main()
