#!/usr/bin/env python3
"""Isolated packaging workflow fixtures; no real apps, keychain or UI touched."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class BuildWorkflowChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="island-build-fixture-")
        self.root = Path(self.temp.name)
        for folder in ["script", "Sources/Fixture", "Resources", "tools", "products"]:
            (self.root / folder).mkdir(parents=True)
        (self.root / "Package.swift").write_text("// Fixture only\n")
        (self.root / "VERSION").write_text("0.3.1\n")
        (self.root / "Sources/Fixture/main.swift").write_text("// Fixture only\n")
        (self.root / "Resources/AppIcon.icns").write_bytes(b"fixture-icon")
        for lang in ["en", "zh-Hans"]:
            (self.root / f"Resources/Localization/{lang}.lproj").mkdir(parents=True)
            (self.root / f"Resources/Localization/{lang}.lproj/Localizable.strings").write_text("/* Fixture */\n")
        (self.root / "script/install_hooks.py").write_text("# Fixture only\n")
        for name in ["LinglongtaiHUD", "linglongtaictl"]:
            (self.root / "products" / name).write_bytes(b"unsigned-fixture-" + name.encode())
        source = Path(__file__).resolve().with_name("build_and_run.sh").read_text()
        # Redirect only absolute system invocations in the fixture copy; the
        # real production script remains unchanged and is never executed here.
        source = source.replace("/usr/bin/security", str(self.root / "tools/security"))
        source = source.replace("/usr/bin/open", str(self.root / "tools/open"))
        self.script = self.root / "script/build_and_run.sh"
        self.script.write_text(source)
        mocks = {
            "git": 'if [[ "$*" == *"rev-parse"* ]]; then echo fixture; fi',
            "swift": 'if [[ "$*" == *"--show-bin-path"* ]]; then echo "$FIXTURE_ROOT/products"; elif [[ -e "$FIXTURE_ROOT/fail-build" ]]; then exit 1; fi',
            "security": 'printf \'  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Fixture identity"\\n\'',
            "codesign": '''printf '%s\\n' "$*" >> "$FIXTURE_ROOT/sign-calls"
if [[ "$*" == *"--force"* ]]; then
  target="${!#}"
  if [[ -f "$target" ]]; then printf '\\nsigned-fixture' >> "$target"; fi
elif [[ -e "$FIXTURE_ROOT/invalid-seal" ]]; then exit 1; fi''',
            "pkill": 'printf stop >> "$FIXTURE_ROOT/stop-calls"',
            "pgrep": 'exit 0',
            "open": 'printf \'%s\\n\' "$*" >> "$FIXTURE_ROOT/open-calls"',
        }
        for name, body in mocks.items():
            path = self.root / "tools" / name
            path.write_text("#!/bin/bash\nset -eu\n" + body + "\n")
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root / "tools") + os.pathsep + os.environ["PATH"], FIXTURE_ROOT=str(self.root))
        self.env.pop("ISLAND_SIGNING_IDENTITY", None)
        self.bundle = self.root / "dist/Agent 灵动岛.app"

    def tearDown(self):
        self.temp.cleanup()

    def run_mode(self, mode="--package-only", **extra):
        result = subprocess.run(["/bin/bash", str(self.script), mode], env=dict(self.env, **extra), capture_output=True, text=True)
        return result

    def sign_count(self):
        path = self.root / "sign-calls"
        return sum("--force" in line for line in path.read_text().splitlines()) if path.exists() else 0

    def test_unchanged_bundle_is_not_resigned(self):
        first = self.run_mode()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertIn("ad-hoc", first.stderr)
        self.assertEqual(self.sign_count(), 3)
        binary = self.bundle / "Contents/MacOS/LinglongtaiHUD"
        self.assertNotEqual(binary.read_bytes(), (self.root / "products/LinglongtaiHUD").read_bytes())
        plist = (self.bundle / "Contents/Info.plist").read_bytes()
        second = self.run_mode()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("preserving existing signature", second.stdout)
        self.assertEqual(self.sign_count(), 3)
        self.assertEqual((self.bundle / "Contents/Info.plist").read_bytes(), plist)
        self.assertFalse((self.root / "stop-calls").exists())
        self.assertFalse((self.root / "open-calls").exists())

    def test_changed_resource_is_repackaged(self):
        self.assertEqual(self.run_mode().returncode, 0)
        (self.root / "Resources/AppIcon.icns").write_bytes(b"changed")
        self.assertEqual(self.run_mode().returncode, 0)
        self.assertEqual(self.sign_count(), 6)

    def test_translations_are_packaged_and_tracked(self):
        result = self.run_mode()
        self.assertEqual(result.returncode, 0, result.stderr)
        resources = self.bundle / "Contents/Resources"
        for lang in ["en", "zh-Hans"]:
            self.assertTrue((resources / f"{lang}.lproj/Localizable.strings").is_file(), lang)
        plist = (self.bundle / "Contents/Info.plist").read_text()
        self.assertIn("<key>CFBundleDevelopmentRegion</key>\n  <string>en</string>", plist)
        self.assertIn("<string>zh-Hans</string>", plist)
        # Editing a translation must repackage, or the change would never reach the app.
        (self.root / "Resources/Localization/en.lproj/Localizable.strings").write_text("/* changed */\n")
        self.assertEqual(self.run_mode().returncode, 0)
        self.assertEqual(self.sign_count(), 6)
        self.assertIn("changed", (resources / "en.lproj/Localizable.strings").read_text())

    def test_changed_binary_or_helper_is_repackaged(self):
        self.assertEqual(self.run_mode().returncode, 0)
        for name, count in [("LinglongtaiHUD", 6), ("linglongtaictl", 9)]:
            (self.root / "products" / name).write_bytes(b"changed-product")
            self.assertEqual(self.run_mode().returncode, 0)
            self.assertEqual(self.sign_count(), count)

    def test_unchanged_run_still_stops_and_launches_once(self):
        self.assertEqual(self.run_mode().returncode, 0)
        result = self.run_mode("--verify")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.sign_count(), 3)
        self.assertEqual((self.root / "stop-calls").read_text(), "stop")
        self.assertEqual(len((self.root / "open-calls").read_text().splitlines()), 1)

    def test_failed_build_leaves_running_app_intact(self):
        (self.root / "fail-build").touch()
        self.assertNotEqual(self.run_mode("run").returncode, 0)
        self.assertFalse((self.root / "stop-calls").exists())
        self.assertFalse((self.root / ".build/island-package.lock").exists())

    def test_concurrent_package_fails_closed(self):
        (self.root / ".build/island-package.lock").mkdir(parents=True)
        result = self.run_mode("run")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("in progress", result.stderr)
        self.assertFalse((self.root / "stop-calls").exists())
        self.assertTrue((self.root / ".build/island-package.lock").is_dir())

    def test_signer_change_forces_repackage(self):
        self.assertEqual(self.run_mode().returncode, 0)
        result = self.run_mode(ISLAND_SIGNING_IDENTITY="0123456789abcdef0123456789abcdef01234567")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.sign_count(), 6)
        self.assertIn("--sign 0123456789ABCDEF0123456789ABCDEF01234567", (self.root / "sign-calls").read_text())

    def test_invalid_signer_or_mode_does_not_mutate_bundle(self):
        self.assertEqual(self.run_mode().returncode, 0)
        self.assertNotEqual(self.run_mode(ISLAND_SIGNING_IDENTITY="not-a-fingerprint").returncode, 0)
        self.assertNotEqual(self.run_mode(ISLAND_SIGNING_IDENTITY="A" * 40).returncode, 0)
        self.assertNotEqual(self.run_mode("--typo").returncode, 0)
        self.assertEqual(self.sign_count(), 3)


if __name__ == "__main__":
    unittest.main()
