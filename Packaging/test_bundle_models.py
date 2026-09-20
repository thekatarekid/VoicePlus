import hashlib
import json
from pathlib import Path
import tempfile
import shutil
import unittest
from bundle_models import verified_files, verified_notices

class BundleModelsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / 'weights.bin').write_bytes(b'verified weights')
        self.entry = {'path': 'weights.bin', 'size': 16, 'sha256': hashlib.sha256(b'verified weights').hexdigest()}
        self.manifest()
    def tearDown(self):
        self.tmp.cleanup()
    def manifest(self):
        (self.root / 'voiceplus-manifest.json').write_text(json.dumps({'modelID': 'test', 'files': [self.entry]}))
    def test_verified_bytes_pass(self):
        self.assertEqual(verified_files(self.root, 'test', ['weights.bin']), [Path('weights.bin')])
    def test_corruption_fails(self):
        (self.root / 'weights.bin').write_bytes(b'corrupt contents')
        with self.assertRaises(ValueError): verified_files(self.root, 'test', ['weights.bin'])
    def test_wrong_identity_fails(self):
        with self.assertRaises(ValueError): verified_files(self.root, 'another', ['weights.bin'])
    def test_escape_fails(self):
        self.entry['path'] = '../weights.bin'; self.manifest()
        with self.assertRaises(ValueError): verified_files(self.root, 'test', [])
    def test_missing_required_component_fails(self):
        with self.assertRaises(ValueError): verified_files(self.root, 'test', ['Encoder.mlmodelc'])

class ModelNoticeTests(unittest.TestCase):
    def test_required_license_copies_are_verified(self):
        folder = Path(__file__).parent / 'model-notices'
        names = {p.name for p in verified_notices(folder)}
        self.assertIn('eou-NVIDIA-Open-Model-License.pdf', names)
        self.assertIn('legacy-segmentation-LICENSE', names)

    def test_changed_license_copy_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp) / 'Notices'
            shutil.copytree(Path(__file__).parent / 'model-notices', folder)
            (folder / 'eou-NOTICE.txt').write_text('missing attribution')
            with self.assertRaises(ValueError): verified_notices(folder)

if __name__ == '__main__': unittest.main()
