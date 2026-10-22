import argparse
import json
from pathlib import Path
import tempfile
import unittest

import release_manifest as manifest


class ManifestTests(unittest.TestCase):
    def test_pins_each_output_and_cds_separately(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ('pocketmanga-jre.tar', 'pocketmanga-image.tar', 'classes.jsa'):
                (root / name).write_text(name)
            image = 'ghcr.io/example/builder@sha256:' + 'a' * 64
            result = manifest.create_manifest('2.39', root, root, image)
            self.assertEqual('2.39', result['profile']['glibc'])
            self.assertEqual('softfp', result['profile']['abi'])
            self.assertNotEqual(result['jre']['SHA256'], result['images']['SHA256'])
            self.assertEqual(manifest.digest(root / 'classes.jsa'), result['jre']['CDS_SHA256'])
            self.assertEqual('2.39', result['images']['Glibc'])
            self.assertEqual(image, result['builder'])
            json.dumps(result)

    def test_mutable_registry_tag_cannot_be_release_provenance(self):
        for value in ('ghcr.io/example/builder:latest', 'image@sha256:1234', 'image@sha256:' + 'z' * 64):
            with self.subTest(value=value), self.assertRaises(argparse.ArgumentTypeError):
                manifest.immutable_image(value)


if __name__ == '__main__':
    unittest.main()
