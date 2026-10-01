import hashlib
import json
from pathlib import Path
import tempfile
import shutil
import unittest
from bundle_models import verified_files, verified_notices, bundle_vad, VAD, VAD_SOURCE

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

class SileroVADBundleTests(unittest.TestCase):
    """V5 C6 — the checked-in VAD verifies and lands where ModelCatalog/BundledModelResources look."""
    def test_checked_in_vad_verifies(self):
        for name, (model_id, required) in VAD.items():
            self.assertTrue(verified_files(VAD_SOURCE / name, model_id, required))

    def test_bundle_vad_copies_verified_tree_and_licence(self):
        with tempfile.TemporaryDirectory() as temp:
            dest = Path(temp) / 'Models'
            bundle_vad(dest)
            self.assertTrue((dest / 'silero-vad' / 'silero-vad-unified-256ms-v6.2.1.mlmodelc' / 'coremldata.bin').is_file())
            self.assertTrue((dest / 'silero-vad' / 'voiceplus-manifest.json').is_file())
            self.assertTrue((dest / 'Notices' / 'LICENSE-silero-vad.txt').is_file())

    def test_tampered_vad_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            src = Path(temp) / 'vad'
            shutil.copytree(VAD_SOURCE, src)
            (src / 'silero-vad' / 'silero-vad-unified-256ms-v6.2.1.mlmodelc' / 'model.mil').write_text('tampered')
            with self.assertRaises(ValueError): bundle_vad(Path(temp) / 'Models', source=src)

if __name__ == '__main__': unittest.main()
