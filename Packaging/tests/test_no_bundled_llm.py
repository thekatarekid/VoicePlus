"""X5 — LLM weights (Qwen3.5-2B / 4B, the cleanup GGUF) are downloads, never part of the DMG."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class NoBundledLLMTests(unittest.TestCase):
    def test_packaging_scripts_never_copy_gguf(self):
        for name in ("make_app.sh", "release.sh", "bundle_models.py"):
            text = (ROOT / name).read_text().lower()
            self.assertNotIn(".gguf", text, name)
            self.assertNotIn("models/llm", text, name)

    def test_verify_install_refuses_bundled_gguf(self):
        text = (ROOT / "verify_install.sh").read_text()
        self.assertIn("-iname '*.gguf'", text)
        self.assertIn("LLM weights must not be bundled", text)


if __name__ == "__main__":
    unittest.main()
