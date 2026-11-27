import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("generate-tauri-update-feed.py")
ASSETS = (
    "AI Cleaner_2.0.1_universal.app.tar.gz",
    "AI Cleaner_2.0.1_x64-setup.exe",
    "AI Cleaner_2.0.1_x64_en-US.msi",
    "AI Cleaner_2.0.1_amd64.AppImage",
)


class UpdateFeedTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.notes = self.root / "notes.md"
        self.notes.write_text("Release notes\n", encoding="utf-8")
        for index, name in enumerate(ASSETS):
            (self.root / name).write_bytes(b"installer")
            (self.root / f"{name}.sig").write_text(f"signed-{index}\n", encoding="utf-8")

    def generate(self):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "v2.0.1", "example/ai-cleaner", str(self.root), str(self.notes)],
            capture_output=True,
            text=True,
        )

    def test_maps_each_platform_and_keeps_windows_installer_types_separate(self):
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        feed = json.loads((self.root / "latest.json").read_text(encoding="utf-8"))
        self.assertEqual(feed["version"], "2.0.1")
        self.assertEqual(feed["notes"], "Release notes")
        platforms = feed["platforms"]
        self.assertEqual(platforms["darwin-aarch64"], platforms["darwin-x86_64"])
        self.assertEqual(platforms["windows-x86_64"], platforms["windows-x86_64-nsis"])
        self.assertEqual(platforms["windows-x86_64-msi"]["signature"], "signed-2")
        self.assertEqual(platforms["linux-x86_64"]["signature"], "signed-3")
        self.assertEqual(
            platforms["darwin-aarch64"]["url"],
            "https://github.com/example/ai-cleaner/releases/download/v2.0.1/"
            "AI%20Cleaner_2.0.1_universal.app.tar.gz",
        )

    def test_refuses_to_generate_feed_if_a_signed_installer_is_missing(self):
        (self.root / f"{ASSETS[2]}.sig").unlink()
        result = self.generate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(".msi.sig", result.stderr)
        self.assertFalse((self.root / "latest.json").exists())


if __name__ == "__main__":
    unittest.main()
