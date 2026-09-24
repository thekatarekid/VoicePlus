"""Exercise the release script's signing selection without touching Keychain."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class SigningPolicyTests(unittest.TestCase):
    def select(self, identity, certificate_available=False):
        script = (Path(__file__).resolve().parents[1] / "make_app.sh").read_text()
        policy = script.split('SIGN_ID="in.adityakatare.voiceplus"', 1)[1].split(
            "# AMFI's XML parser", 1
        )[0]
        env = dict(os.environ, CODESIGN_IDENTITY=identity,
                   CODESIGN_CERT_NAME="VoicePlus Local Signing")
        mocked_security = ('printf \'"VoicePlus Local Signing"\\n\''
                           if certificate_available else 'return 0')
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "keychain-lookups"
            env["SIGNING_TEST_MARKER"] = str(marker)
            result = subprocess.run(
                ["/bin/bash", "-c", 'set -e\n'
                 'SIGN_ID="in.adityakatare.voiceplus"\n'
                 'log() { :; }\n'
                 f'security() {{ echo KEYCHAIN_LOOKUP >> "$SIGNING_TEST_MARKER"; {mocked_security}; }}\n'
                 + policy + '\nprintf "%s\\n" "$IDENTITY" "${DR_ARGS[@]}"\n'],
                env=env, text=True, capture_output=True, check=True)
            lookups = marker.read_text() if marker.exists() else ""
        return result.stdout.strip().splitlines(), lookups

    def test_explicit_adhoc_skips_keychain_and_preserves_stable_requirement(self):
        selection, diagnostics = self.select("-", certificate_available=True)
        self.assertEqual(selection, ["-", "-r",
            '=designated => identifier "in.adityakatare.voiceplus"'])
        self.assertNotIn("KEYCHAIN_LOOKUP", diagnostics)

    def test_missing_certificate_uses_stable_adhoc_requirement(self):
        selection, _ = self.select("")
        self.assertEqual(selection, ["-", "-r",
            '=designated => identifier "in.adityakatare.voiceplus"'])

    def test_explicit_certificate_keeps_certificate_requirement(self):
        selection, diagnostics = self.select("Developer ID Application: Example")
        self.assertEqual(selection, ["Developer ID Application: Example"])
        self.assertNotIn("KEYCHAIN_LOOKUP", diagnostics)

    def test_detected_certificate_keeps_certificate_requirement(self):
        selection, _ = self.select("", certificate_available=True)
        self.assertEqual(selection, ["VoicePlus Local Signing"])


if __name__ == "__main__":
    unittest.main()
