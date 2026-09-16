"""Black-box release tests; run with PYTHONDONTWRITEBYTECODE=1.

All repositories, fake credentials, build products, and command fixtures live
under an ignored .build directory. No Apple tools or GitHub access are used.
"""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[2]
REAL_GIT = shutil.which("git")
REAL_MAKE = shutil.which("make")
VERSION = "1.2.3"
TAG = "v" + VERSION
STEM = "utisuna-" + VERSION + "-macos"


STUB = r'''
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import zipfile

name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["STUB_LOG"], "a", encoding="utf-8") as log:
    log.write(json.dumps({"tool": name, "args": args, "cwd": os.getcwd()}) + "\n")

def fail(message):
    print("stub " + name + ": " + message, file=sys.stderr)
    sys.exit(91)

def option(key):
    return args[args.index(key) + 1]

if name == "git":
    command_index = 0
    while command_index < len(args) and args[command_index] == "-C":
        command_index += 2
    command = args[command_index] if command_index < len(args) else ""
    if command in ("fetch", "push"):
        if "origin" not in args:
            fail("only fixture origin operations are allowed")
        prefix = args[:command_index]
        origin = subprocess.check_output(
            [os.environ["REAL_GIT"]] + prefix + ["remote", "get-url", "origin"],
            text=True,
        ).strip()
        mapping = json.loads(os.environ["STUB_REMOTES"])
        if origin not in mapping:
            fail("refusing unmapped remote " + origin)
        target = mapping[origin]
        try:
            Path(target).relative_to(Path(os.environ["STUB_ROOT"]))
        except ValueError:
            fail("remote must be inside the fixture directory")
        if not Path(target).is_dir():
            fail("remote must be a local fixture repository")
        if command == "push":
            kind = "TAP" if "homebrew-tap" in origin else "APP"
            if os.environ.get("STUB_FAIL_" + kind + "_PUSH") == "1":
                print("simulated " + kind + " push failure", file=sys.stderr)
                sys.exit(1)
        args[args.index("origin")] = target
        if command == "fetch":
            branch = args[-1]
            args[-1] = "refs/heads/" + branch + ":refs/remotes/origin/" + branch
    elif command in ("clone", "ls-remote", "remote-https", "remote-http", "submodule"):
        fail("network-capable git command is forbidden")
    os.execv(os.environ["REAL_GIT"], [os.environ["REAL_GIT"]] + args)
elif name == "swift":
    if not args or args[0] != "build":
        fail("unexpected Swift command")
    scratch = Path(option("--scratch-path")).resolve()
    configuration = option("-c")
    binary_dir = scratch / "arm64-apple-macosx" / configuration / "bin with spaces"
    if "--show-bin-path" in args:
        print(binary_dir)
    else:
        binary_dir.mkdir(parents=True, exist_ok=True)
        version = os.environ.get("STUB_BINARY_VERSION", Path("VERSION").read_text().strip())
        binary = binary_dir / "utisuna"
        binary.write_text(
            "#!/bin/sh\n"
            "# freshly built by the isolated Swift fixture\n"
            "if [ \"$1\" = --version ]; then\n"
            "  printf '%s\\n' " + shlex.quote(version) + "\n"
            "else\n"
            "  printf '%s\\n' 'fixture executable'\n"
            "fi\n"
        )
        binary.chmod(0o755)
        print("Swift build diagnostic on stdout, not a binary directory")
elif name == "lipo":
    if args[:1] != ["-archs"] or not Path(args[-1]).is_file():
        fail("expected architecture inspection of an existing binary")
    print(os.environ.get("STUB_ARCH", "arm64"))
elif name == "otool":
    if args[:1] != ["-l"] or not Path(args[-1]).is_file():
        fail("expected load-command inspection of an existing binary")
    print("Load command 0\n      cmd LC_BUILD_VERSION\n platform 1\n    minos "
          + os.environ.get("STUB_MINOS", "12.0") + "\n      sdk 15.0")
elif name == "codesign":
    if not Path(args[-1]).is_file():
        fail("signing target is not an existing file")
    if "--sign" not in args and "--verify" not in args:
        fail("unexpected signing operation")
    sys.exit(int(os.environ.get("STUB_CODESIGN_EXIT", "0")))
elif name == "xcrun":
    if args[:2] != ["notarytool", "submit"] or not Path(args[2]).is_file():
        fail("only submitting a fixture archive is allowed")
    if "--wait" not in args or option("--output-format") != "json":
        fail("notarization must wait for a JSON result")
    print(json.dumps({"id": "isolated-notary-id",
                      "status": os.environ.get("STUB_NOTARY_STATUS", "Accepted")}))
    sys.exit(int(os.environ.get("STUB_NOTARY_EXIT", "0")))
elif name == "plutil":
    if args[:5] != ["-extract", "status", "raw", "-o", "-"]:
        fail("unexpected JSON extraction")
    print(json.loads(Path(args[-1]).read_text())["status"])
elif name == "ditto":
    if args[:4] != ["--norsrc", "-c", "-k", "--keepParent"]:
        fail("unexpected archive options")
    source, target = map(Path, args[-2:])
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(source.rglob("*")):
            if path.is_file():
                archive.write(path, path.relative_to(source.parent))
elif name == "gh":
    storage = Path(os.environ["STUB_GH_STORAGE"])
    release_file = storage / "release.json"
    if args[:2] == ["auth", "status"]:
        sys.exit(int(os.environ.get("STUB_GH_AUTH_EXIT", "0")))
    elif args[:1] == ["api"]:
        if "--paginate" not in args or "repos/rioriost/utisuna/releases" not in args:
            fail("release discovery must use the paginated releases API")
        if release_file.exists():
            release = json.loads(release_file.read_text())
            if release["tag_name"] in option("--jq"):
                print(release["id"])
    elif args[:2] == ["release", "create"]:
        if release_file.exists():
            fail("existing release must never be replaced")
        if "--verify-tag" not in args:
            fail("release creation must verify the existing tag")
        assets = []
        for item in args[3:]:
            if item.startswith("--"):
                break
            source = Path(item)
            if not source.is_file():
                fail("release asset is missing")
            shutil.copy2(source, storage / source.name)
            assets.append(source.name)
        if len(assets) != 2:
            fail("expected precisely archive and checksum assets")
        release_file.write_text(json.dumps({"id": 123, "tag_name": args[2]}))
        if os.environ.get("STUB_DIRTY_TAP_ON_CREATE") == "1":
            tap = Path(os.environ["HOMEBREW_TAP_PATH"])
            (tap / "other.txt").write_text("Concurrent staged change.\n")
            subprocess.run(
                [os.environ["REAL_GIT"], "-C", str(tap), "add", "--", "other.txt"],
                check=True,
            )
            (tap / "other.txt").write_text("Concurrent unstaged change.\n")
            (tap / "untracked.txt").write_text("Concurrent untracked change.\n")
        if os.environ.get("STUB_COMMIT_TAP_ON_CREATE") == "1":
            tap = Path(os.environ["HOMEBREW_TAP_PATH"])
            (tap / "other.txt").write_text("Concurrent committed change.\n")
            subprocess.run(
                [os.environ["REAL_GIT"], "-C", str(tap), "commit", "--quiet",
                 "-am", "Concurrent tap commit"],
                check=True,
            )
    elif args[:2] == ["release", "download"]:
        if not release_file.exists():
            fail("release does not exist")
        target = Path(option("--dir"))
        for i, arg in enumerate(args):
            if arg == "--pattern":
                source = storage / args[i + 1]
                if not source.is_file():
                    fail("release asset does not exist")
                shutil.copy2(source, target / source.name)
    else:
        fail("unexpected GitHub operation; no real gh command is ever executed")
else:
    fail("unsupported command")
'''


@unittest.skipUnless(REAL_GIT, "git is required")
class ReleaseWorkflowTests(unittest.TestCase):
    def setUp(self):
        fixture_parent = ROOT / ".build" / "release-tests"
        fixture_parent.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(
            prefix="workflow-", dir=fixture_parent
        )
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.repo = self.base / "source repo"
        self.repo.mkdir()
        self.bin = self.base / "stub bin"
        self.bin.mkdir()
        self.log = self.base / "commands.jsonl"
        self.storage = self.base / "github assets"
        self.storage.mkdir()
        self.tap = self.base / "homebrew tap"
        self.app_remote = self.base / "app.git"
        self.tap_remote = self.base / "tap.git"
        self.env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith(("GIT_", "GH_", "GITHUB_", "STUB_"))
            and key not in {
                "SWIFT", "APP_NAME", "PRODUCT_NAME", "CONFIGURATION", "BUILD_DIR",
                "ARTIFACTS_DIR", "OUTPUT_BASENAME", "APP_REPO", "HOMEBREW_TAP_REPO",
                "DEFAULT_BRANCH", "TAG", "SIGN_IDENTITY", "NOTARY_PROFILE", "PUBLISH",
                "NOTARIZE", "HOMEBREW_TAP_PATH", "RELEASE_NOTES", "MAKEFLAGS",
                "MFLAGS", "MAKEFILES",
            }
        }
        home = self.base / "home"
        home.mkdir()
        self.env.update({
            "HOME": str(home),
            "XDG_CONFIG_HOME": str(home),
            "PATH": str(self.bin) + os.pathsep + os.environ.get("PATH", os.defpath),
            "PYTHONDONTWRITEBYTECODE": "1",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_AUTHOR_NAME": "Release Fixture",
            "GIT_AUTHOR_EMAIL": "release-fixture@example.invalid",
            "GIT_COMMITTER_NAME": "Release Fixture",
            "GIT_COMMITTER_EMAIL": "release-fixture@example.invalid",
            "REAL_GIT": REAL_GIT,
            "STUB_ROOT": str(self.base),
            "STUB_LOG": str(self.log),
            "STUB_GH_STORAGE": str(self.storage),
            "STUB_REMOTES": json.dumps({
                "https://github.com/rioriost/utisuna.git": str(self.app_remote),
                "https://github.com/rioriost/homebrew-tap.git": str(self.tap_remote),
                "git@github.com:rioriost/utisuna.git": str(self.app_remote),
                "git@github.com:rioriost/homebrew-tap.git": str(self.tap_remote),
            }),
        })
        for name in ("swift", "lipo", "otool", "codesign", "xcrun", "plutil",
                     "gh", "git", "ditto"):
            stub = self.bin / name
            stub.write_text("#!" + sys.executable + "\n" + STUB)
            stub.chmod(0o755)
        (self.repo / "scripts").mkdir()
        for name in ("release-common.sh", "release.sh", "notarize.sh"):
            shutil.copy2(ROOT / "scripts" / name, self.repo / "scripts" / name)
        (self.repo / "docs").mkdir()
        shutil.copy2(ROOT / "docs" / "utisuna.rb.template",
                     self.repo / "docs" / "utisuna.rb.template")
        shutil.copy2(ROOT / "Makefile", self.repo / "Makefile")
        (self.repo / "README.md").write_text("Isolated release fixture.\n")
        (self.repo / "LICENSE").write_text("Fixture license.\n")
        (self.repo / "VERSION").write_text(VERSION + "\n")
        (self.repo / ".gitignore").write_text(".build/\nbuild/\n")
        (self.repo / "Formula").mkdir()
        (self.repo / "Formula" / "utisuna.rb").write_text(
            "# Tracked root formula must remain untouched.\n"
        )
        self.initialize(self.repo)
        self.git(self.repo, "tag", TAG)
        self.commit = self.git(self.repo, "rev-parse", "HEAD").stdout.strip()
        self.original_formula = (self.repo / "Formula" / "utisuna.rb").read_bytes()

    def run_command(self, args, cwd=None, env=None):
        environment = self.env.copy()
        if env:
            for key, value in env.items():
                if value is None:
                    environment.pop(key, None)
                else:
                    environment[key] = str(value)
        return subprocess.run(
            [str(arg) for arg in args], cwd=cwd or self.repo, env=environment,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30,
        )

    def git(self, repo, *args):
        # Fixture setup deliberately bypasses the wrapper and uses local paths only.
        result = self.run_command([REAL_GIT, "-C", repo, *args])
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def initialize(self, repo):
        self.git(repo, "init", "--quiet")
        self.git(repo, "symbolic-ref", "HEAD", "refs/heads/main")
        self.git(repo, "config", "commit.gpgsign", "false")
        self.git(repo, "config", "tag.gpgsign", "false")
        self.git(repo, "add", ".")
        self.git(repo, "commit", "--quiet", "-m", "Fixture source")

    def setup_publish(self):
        self.tap.mkdir()
        (self.tap / "Formula").mkdir()
        (self.tap / "Formula" / "utisuna.rb").write_text("# Previous tap formula.\n")
        (self.tap / "other.txt").write_text("Existing unrelated tracked file.\n")
        self.initialize(self.tap)
        for repo, remote, url in (
            (self.repo, self.app_remote, "https://github.com/rioriost/utisuna.git"),
            (self.tap, self.tap_remote, "https://github.com/rioriost/homebrew-tap.git"),
        ):
            self.git(self.base, "init", "--bare", "--quiet", str(remote))
            self.git(repo, "push", "--quiet", str(remote), "HEAD:refs/heads/main")
            self.git(repo, "remote", "add", "origin", url)
            head = self.git(repo, "rev-parse", "HEAD").stdout.strip()
            self.git(repo, "update-ref", "refs/remotes/origin/main", head)
        self.env["HOMEBREW_TAP_PATH"] = str(self.tap)

    def release(self, *args, env=None):
        return self.run_command(["bash", "scripts/release.sh", *args], env=env)

    def notarize(self, *args, env=None):
        settings = {
            "SIGN_IDENTITY": "Isolated signing identity, never a real credential",
            "NOTARY_PROFILE": "isolated-notary-profile",
        }
        settings.update(env or {})
        return self.run_command(["bash", "scripts/notarize.sh", *args], env=settings)

    def publish(self, *args, env=None):
        settings = {
            "SIGN_IDENTITY": "Isolated signing identity, never a real credential",
            "NOTARY_PROFILE": "isolated-notary-profile",
        }
        settings.update(env or {})
        return self.release("--publish", *(args or (TAG,)), env=settings)

    def calls(self, tool=None):
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] \
            if self.log.exists() else []
        return [call for call in calls if tool is None or call["tool"] == tool]

    def clear_calls(self):
        self.log.write_text("")

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_failure(self, result, message=None):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        if message:
            self.assertIn(message.lower(), (result.stdout + result.stderr).lower())

    def assert_no_build_or_publication(self):
        self.assertEqual(self.calls("swift"), [])
        self.assertEqual(self.calls("codesign"), [])
        self.assertEqual(self.calls("xcrun"), [])
        self.assertFalse(any(
            call["args"][:2] == ["release", "create"] for call in self.calls("gh")
        ))
        self.assertFalse(any("push" in call["args"] for call in self.calls("git")))

    def assert_local_only(self):
        self.assertEqual(self.calls("gh"), [])
        self.assertFalse(any(
            any(command in call["args"] for command in ("push", "fetch", "clone"))
            for call in self.calls("git")
        ))

    def archive(self, unsigned=False):
        return self.repo / "build" / ("unsigned" if unsigned else "") / (STEM + ".zip")

    def assert_artifacts(self, unsigned=False):
        archive = self.archive(unsigned)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        self.assertEqual(Path(str(archive) + ".sha256").read_text(),
                         digest + "  " + archive.name + "\n")
        self.assertEqual(Path(str(archive) + ".commit").read_text(), self.commit + "\n")
        receipt = Path(str(archive) + ".notarized")
        if unsigned:
            self.assertFalse(receipt.exists())
        else:
            self.assertEqual(receipt.read_text(), digest + "\n")
            self.assertEqual(
                json.loads((archive.parent / (STEM + ".notary.json")).read_text())["status"],
                "Accepted",
            )
        formula = archive.with_suffix(".rb").read_text()
        self.assertIn('version "' + VERSION + '"', formula)
        self.assertIn('sha256 "' + digest + '"', formula)
        self.assertIn("https://github.com/rioriost/utisuna/releases/download/"
                      + TAG + "/" + archive.name, formula)
        self.assertNotIn("{{", formula)
        self.assertIn("depends_on arch: :arm64", formula)
        self.assertIn("depends_on macos: :monterey", formula)
        self.assertEqual((self.repo / "Formula" / "utisuna.rb").read_bytes(),
                         self.original_formula)
        self.assertEqual(self.git(self.repo, "status", "--porcelain").stdout, "")
        with zipfile.ZipFile(archive) as zipped:
            self.assertEqual(set(zipped.namelist()), {
                STEM + "/utisuna", STEM + "/README.md",
                STEM + "/LICENSE", STEM + "/INSTALL.txt",
            })
            self.assertIn(b"freshly built", zipped.read(STEM + "/utisuna"))
            self.assertIn(VERSION.encode(), zipped.read(STEM + "/utisuna"))
            self.assertTrue(zipped.getinfo(STEM + "/utisuna").external_attr >> 16 & 0o111)
        self.assertEqual(list(archive.parent.glob(".utisuna-*")), [])
        return archive

    def test_default_release_is_clean_unsigned_local_archive(self):
        result = self.release(TAG)
        self.assert_success(result)
        archive = self.assert_artifacts(unsigned=True)
        self.assertIn(str(archive), result.stdout)
        self.assert_local_only()
        self.assertEqual(self.calls("codesign"), [])
        self.assertEqual(self.calls("xcrun"), [])
        builds = self.calls("swift")
        self.assertEqual(len(builds), 2)
        binary_dir = self.repo / ".build/arm64-apple-macosx/release/bin with spaces"
        self.assert_success(self.run_command([binary_dir / "utisuna", "--version"]))
        self.assertEqual(self.run_command([binary_dir / "utisuna", "--version"]).stdout,
                         VERSION + "\n")

    def test_local_tag_can_be_inferred_or_supplied_by_environment(self):
        for selector in ({}, {"TAG": TAG}):
            with self.subTest(selector=selector):
                env = dict(selector, ARTIFACTS_DIR="build/tag-" + str(len(selector)))
                self.assert_success(self.release(env=env))
        self.assert_local_only()

    def test_plain_numeric_tag_is_accepted(self):
        self.git(self.repo, "tag", VERSION)
        self.assert_success(self.release(VERSION))
        formula = self.archive(True).with_suffix(".rb").read_text()
        self.assertIn("/download/" + VERSION + "/", formula)

    def test_cold_notarize_builds_once_and_diagnostics_do_not_contaminate_path(self):
        result = self.notarize(TAG, env={"PUBLISH": "1"})
        self.assert_success(result)
        self.assert_artifacts()
        self.assertIn("Swift build diagnostic on stdout", result.stderr)
        self.assertNotIn("Swift build diagnostic", result.stdout)
        self.assert_local_only()
        self.assertEqual(len(self.calls("swift")), 2)
        self.assertEqual(len([call for call in self.calls("codesign")
                              if "--sign" in call["args"]]), 1)
        self.assertEqual(len([call for call in self.calls("codesign")
                              if "--verify" in call["args"]]), 1)
        self.assertEqual(len(self.calls("xcrun")), 1)

    def test_custom_scratch_path_is_shared_and_stale_binary_is_replaced(self):
        scratch = self.repo / ".build" / "custom scratch with spaces"
        stale = scratch / "arm64-apple-macosx/release/bin with spaces/utisuna"
        stale.parent.mkdir(parents=True)
        stale.write_text("#!/bin/sh\nprintf 'stale binary\\n'\n")
        stale.chmod(0o755)
        self.assert_success(self.notarize(TAG, env={"BUILD_DIR": str(scratch)}))
        self.assert_artifacts()
        self.assertNotIn("stale binary", stale.read_text())
        calls = self.calls("swift")
        self.assertEqual(len(calls), 2)
        for call in calls:
            args = call["args"]
            self.assertEqual(args[args.index("--scratch-path") + 1], str(scratch))
            self.assertEqual(args[args.index("--arch") + 1], "arm64")
            self.assertEqual(args[args.index("-c") + 1], "release")
        self.assertNotIn("--show-bin-path", calls[0]["args"])
        self.assertIn("--product", calls[0]["args"])
        self.assertIn("--show-bin-path", calls[1]["args"])

    def test_tag_head_mismatch_is_rejected_before_side_effects(self):
        (self.repo / "VERSION").write_text("1.2.4\n")
        self.git(self.repo, "add", "VERSION")
        self.git(self.repo, "commit", "--quiet", "-m", "Newer source")
        for invoke in (self.release, self.notarize, self.publish):
            with self.subTest(script=invoke.__name__):
                self.assert_failure(invoke(TAG), "HEAD must match")
        self.assert_no_build_or_publication()
        self.assertFalse((self.repo / "build").exists())

    def test_missing_and_invalid_tags_are_rejected_before_side_effects(self):
        for tag in ("v9.9.9", "latest", "1.2", "1.2.3-rc1", "1.2.3/../../bad"):
            with self.subTest(tag=tag):
                self.assert_failure(self.release(tag))
        self.assert_no_build_or_publication()

    def test_dirty_source_staged_unstaged_and_untracked_are_untouched(self):
        source = self.repo / "VERSION"
        source.write_text("staged source change\n")
        self.git(self.repo, "add", "VERSION")
        source.write_text("unstaged source change\n")
        untracked = self.repo / "untracked.txt"
        untracked.write_text("Do not change this.\n")
        status = self.git(self.repo, "status", "--porcelain").stdout
        index = self.git(self.repo, "show", ":VERSION").stdout
        self.assert_failure(self.release(TAG), "not clean")
        self.assertEqual(self.git(self.repo, "status", "--porcelain").stdout, status)
        self.assertEqual(self.git(self.repo, "show", ":VERSION").stdout, index)
        self.assertEqual(source.read_text(), "unstaged source change\n")
        self.assertEqual(untracked.read_text(), "Do not change this.\n")
        self.assert_no_build_or_publication()

    def test_source_staged_only_or_untracked_only_changes_are_rejected(self):
        source = self.repo / "VERSION"
        original = source.read_text()
        source.write_text("Staged source change.\n")
        self.git(self.repo, "add", "VERSION")
        self.assert_failure(self.release(TAG), "not clean")
        self.assertEqual(source.read_text(), "Staged source change.\n")
        self.assertEqual(self.git(self.repo, "show", ":VERSION").stdout,
                         "Staged source change.\n")
        self.git(self.repo, "reset", "--quiet", "HEAD", "--", "VERSION")
        source.write_text(original)
        untracked = self.repo / "untracked.txt"
        untracked.write_text("Untracked source change.\n")
        self.assert_failure(self.release(TAG), "not clean")
        self.assertEqual(untracked.read_text(), "Untracked source change.\n")
        self.assert_no_build_or_publication()

    def test_binary_version_mismatch_prevents_signing_and_archive(self):
        self.assert_failure(self.notarize(TAG, env={"STUB_BINARY_VERSION": "0.0.0"}),
                            "version does not match")
        self.assertEqual(self.calls("codesign"), [])
        self.assertEqual(self.calls("xcrun"), [])
        self.assertFalse(self.archive().exists())

    def test_architecture_and_minimum_os_are_validated_before_signing(self):
        for setting, value, message in (
            ("STUB_ARCH", "x86_64", "only arm64"),
            ("STUB_ARCH", "x86_64 arm64", "only arm64"),
            ("STUB_MINOS", "13.0", "macOS 12.0"),
        ):
            with self.subTest(setting=setting, value=value):
                self.assert_failure(self.notarize(TAG, env={setting: value}), message)
                self.assertFalse(self.archive().exists())
        self.assertEqual(self.calls("codesign"), [])
        self.assertEqual(self.calls("xcrun"), [])

    def test_signing_requires_both_identity_and_profile_before_build(self):
        for missing in ("SIGN_IDENTITY", "NOTARY_PROFILE"):
            with self.subTest(missing=missing):
                self.assert_failure(self.notarize(TAG, env={missing: None}), missing)
        self.assert_no_build_or_publication()

    def test_codesign_failure_never_submits_or_emits_release_artifacts(self):
        self.assert_failure(self.notarize(TAG, env={"STUB_CODESIGN_EXIT": "1"}))
        self.assertEqual(self.calls("xcrun"), [])
        self.assertFalse(self.archive().exists())
        self.assertEqual(list((self.repo / "build").glob(".utisuna-*")), [])

    def test_failed_or_nonaccepted_notarization_never_emits_accepted_artifacts(self):
        for status, exit_code in (("Invalid", "0"), ("In Progress", "0"),
                                  ("Accepted", "1")):
            with self.subTest(status=status, exit_code=exit_code):
                self.assert_failure(self.notarize(
                    TAG, env={"STUB_NOTARY_STATUS": status, "STUB_NOTARY_EXIT": exit_code}
                ))
                archive = self.archive()
                for path in (archive, Path(str(archive) + ".sha256"),
                             Path(str(archive) + ".commit"),
                             Path(str(archive) + ".notarized"), archive.with_suffix(".rb")):
                    self.assertFalse(path.exists(), str(path))
                report = archive.parent / (STEM + ".notary.json")
                self.assertEqual(json.loads(report.read_text())["status"], status)
                self.assertEqual(list(archive.parent.glob(".utisuna-*")), [])
        self.assert_local_only()

    def test_existing_artifacts_are_immutable_and_refused_before_build(self):
        self.assert_success(self.notarize(TAG))
        archive = self.assert_artifacts()
        snapshots = {path: path.read_bytes() for path in archive.parent.iterdir()
                     if path.is_file()}
        self.clear_calls()
        self.assert_failure(self.notarize(TAG), "already exists")
        self.assert_no_build_or_publication()
        for path, content in snapshots.items():
            self.assertEqual(path.read_bytes(), content)

    def test_partial_existing_artifact_sets_are_not_overwritten(self):
        for suffix in (".zip", ".zip.sha256", ".zip.commit", ".zip.notarized", ".rb"):
            with self.subTest(suffix=suffix):
                directory = self.repo / "build" / ("existing" + suffix)
                directory.mkdir(parents=True)
                existing = directory / (STEM + suffix)
                existing.write_bytes(b"existing artifact, preserve exactly\n")
                self.assert_failure(self.release(TAG, env={"ARTIFACTS_DIR": str(directory)}),
                                    "already exists")
                self.assertEqual(existing.read_bytes(), b"existing artifact, preserve exactly\n")
        self.assert_no_build_or_publication()

    def test_missing_tap_is_rejected_before_build_or_upload(self):
        for path in (None, str(self.base / "does not exist")):
            with self.subTest(path=path):
                self.assert_failure(self.publish(TAG, env={"HOMEBREW_TAP_PATH": path}),
                                    "HOMEBREW_TAP_PATH")
        self.assert_no_build_or_publication()

    def test_dirty_tap_staged_unstaged_untracked_are_preserved(self):
        self.setup_publish()
        formula = self.tap / "Formula" / "utisuna.rb"
        original = formula.read_bytes()
        other = self.tap / "other.txt"
        other.write_text("Staged unrelated change.\n")
        self.git(self.tap, "add", "other.txt")
        other.write_text("Unstaged unrelated change.\n")
        untracked = self.tap / "untracked.txt"
        untracked.write_text("Untouched untracked file.\n")
        status = self.git(self.tap, "status", "--porcelain").stdout
        index = self.git(self.tap, "show", ":other.txt").stdout
        self.assert_failure(self.publish(TAG), "clean")
        self.assertEqual(self.git(self.tap, "status", "--porcelain").stdout, status)
        self.assertEqual(self.git(self.tap, "show", ":other.txt").stdout, index)
        self.assertEqual(other.read_text(), "Unstaged unrelated change.\n")
        self.assertEqual(untracked.read_text(), "Untouched untracked file.\n")
        self.assertEqual(formula.read_bytes(), original)
        self.assert_no_build_or_publication()
        self.assertEqual(self.calls("gh"), [])

    def test_staged_only_tap_changes_are_rejected_before_build_or_upload(self):
        self.setup_publish()
        other = self.tap / "other.txt"
        other.write_text("Staged-only change.\n")
        self.git(self.tap, "add", "other.txt")
        index = self.git(self.tap, "show", ":other.txt").stdout
        head = self.git(self.tap, "rev-parse", "HEAD").stdout
        self.assert_failure(self.publish(TAG), "clean")
        self.assertEqual(self.git(self.tap, "show", ":other.txt").stdout, index)
        self.assertEqual(self.git(self.tap, "rev-parse", "HEAD").stdout, head)
        self.assertEqual(other.read_text(), "Staged-only change.\n")
        self.assert_no_build_or_publication()

    def test_untracked_only_tap_changes_are_rejected_before_build_or_upload(self):
        self.setup_publish()
        untracked = self.tap / "untracked.txt"
        untracked.write_text("Untracked-only change.\n")
        self.assert_failure(self.publish(TAG), "clean")
        self.assertEqual(untracked.read_text(), "Untracked-only change.\n")
        self.assert_no_build_or_publication()

    def test_tap_must_be_checkout_root(self):
        self.setup_publish()
        self.assert_failure(self.publish(
            TAG, env={"HOMEBREW_TAP_PATH": str(self.tap / "Formula")}
        ), "root")
        self.assert_no_build_or_publication()

    def test_app_and_tap_origins_must_match_expected_repositories(self):
        self.setup_publish()
        for repo in (self.repo, self.tap):
            with self.subTest(repo=repo.name):
                original = self.git(repo, "remote", "get-url", "origin").stdout.strip()
                self.git(repo, "remote", "set-url", "origin",
                         "https://github.com/someone/unrelated.git")
                self.assert_failure(self.publish(TAG), "origin")
                self.git(repo, "remote", "set-url", "origin", original)
        self.assert_no_build_or_publication()
        self.assertEqual(self.calls("gh"), [])

    def test_app_and_tap_must_use_main_branch(self):
        self.setup_publish()
        for repo in (self.repo, self.tap):
            with self.subTest(repo=repo.name):
                self.git(repo, "checkout", "--quiet", "-b", "other-branch")
                self.assert_failure(self.publish(TAG), "main")
                self.git(repo, "checkout", "--quiet", "main")
        self.assert_no_build_or_publication()

    def test_tap_local_commits_are_rejected_before_build_or_upload(self):
        self.setup_publish()
        (self.tap / "other.txt").write_text("Unrelated local commit.\n")
        self.git(self.tap, "commit", "--quiet", "-am", "Unrelated local commit")
        self.assert_failure(self.publish(TAG), "match origin/main")
        self.assert_no_build_or_publication()

    def test_tap_remote_must_be_fetched_before_synchronization_check(self):
        self.setup_publish()
        original = self.git(self.tap, "rev-parse", "HEAD").stdout.strip()
        (self.tap / "other.txt").write_text("New remote change.\n")
        self.git(self.tap, "commit", "--quiet", "-am", "Remote update")
        self.git(self.tap, "push", "--quiet", str(self.tap_remote), "HEAD:refs/heads/main")
        self.git(self.tap, "reset", "--hard", original)
        self.assert_failure(self.publish(TAG), "match origin/main")
        self.assertTrue(any("fetch" in call["args"] for call in self.calls("git")))
        self.assert_no_build_or_publication()
        self.assertEqual((self.tap / "other.txt").read_text(),
                         "Existing unrelated tracked file.\n")

    def test_existing_github_release_is_rejected_using_paginated_api(self):
        self.setup_publish()
        (self.storage / "release.json").write_text(
            json.dumps({"id": 123, "tag_name": TAG})
        )
        self.assert_failure(self.publish(TAG), "already exists")
        self.assert_no_build_or_publication()
        api = [call for call in self.calls("gh") if call["args"][:1] == ["api"]]
        self.assertEqual(len(api), 1)
        self.assertIn("--paginate", api[0]["args"])
        self.assertIn("repos/rioriost/utisuna/releases", api[0]["args"])
        self.assertFalse(self.archive().exists())

    def test_failed_github_authentication_prevents_build_and_upload(self):
        self.setup_publish()
        self.assert_failure(self.publish(TAG, env={"STUB_GH_AUTH_EXIT": "1"}),
                            "authentication")
        self.assert_no_build_or_publication()

    def test_publish_then_resume_preserves_assets_and_commits_only_formula(self):
        self.setup_publish()
        self.assert_success(self.publish(TAG))
        archive = self.assert_artifacts()
        snapshot = {path: (path.read_bytes(), path.stat().st_mtime_ns)
                    for path in (archive, Path(str(archive) + ".sha256"),
                                 Path(str(archive) + ".commit"),
                                 Path(str(archive) + ".notarized"))}
        self.assertEqual(self.git(
            self.tap, "diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"
        ).stdout.strip(), "Formula/utisuna.rb")
        message = self.git(self.tap, "log", "-1", "--format=%B").stdout
        self.assertIn("Co-authored-by: Copilot "
                      "<223556219+Copilot@users.noreply.github.com>", message)
        self.assertEqual((self.tap / "Formula" / "utisuna.rb").read_bytes(),
                         archive.with_suffix(".rb").read_bytes())
        self.assertEqual(self.git(self.tap, "status", "--porcelain").stdout, "")
        self.assertEqual((self.tap / "other.txt").read_text(),
                         "Existing unrelated tracked file.\n")
        for repo, remote in ((self.repo, self.app_remote), (self.tap, self.tap_remote)):
            self.assertEqual(self.git(repo, "rev-parse", "HEAD").stdout,
                             self.git(remote, "rev-parse", "refs/heads/main").stdout)
        self.assertEqual(self.git(self.app_remote, "rev-parse", "refs/tags/" + TAG).stdout,
                         self.commit + "\n")
        tap_head = self.git(self.tap, "rev-parse", "HEAD").stdout
        pushes = [call["args"] for call in self.calls("git") if "push" in call["args"]]
        self.assertEqual(len(pushes), 2)
        self.assertEqual(pushes[0], [
            "push", "--atomic", "origin", self.commit + ":refs/heads/main",
            "refs/tags/" + TAG,
        ])
        self.assertEqual(pushes[1], [
            "-C", str(self.tap), "push", "origin", tap_head.strip() + ":refs/heads/main",
        ])
        self.clear_calls()
        # Resume must not even require signing credentials.
        self.assert_success(self.release("--resume", TAG))
        self.assertEqual(self.calls("swift"), [])
        self.assertEqual(self.calls("codesign"), [])
        self.assertEqual(self.calls("xcrun"), [])
        self.assertFalse(any(call["args"][:2] == ["release", "create"]
                             for call in self.calls("gh")))
        self.assertTrue(any(call["args"][:2] == ["release", "download"]
                            for call in self.calls("gh")))
        self.assertFalse(any(
            call["args"][:1] == ["push"] for call in self.calls("git")
        ))
        self.assertEqual(self.git(self.tap, "rev-parse", "HEAD").stdout, tap_head)
        for path, expected in snapshot.items():
            self.assertEqual((path.read_bytes(), path.stat().st_mtime_ns), expected)

    def test_resume_can_publish_locally_notarized_archive_without_rebuild(self):
        self.setup_publish()
        self.assert_success(self.notarize(TAG))
        archive = self.assert_artifacts()
        original = archive.read_bytes()
        self.clear_calls()
        self.assert_success(self.release("--resume", TAG))
        self.assertEqual(self.calls("swift"), [])
        self.assertEqual(self.calls("codesign"), [])
        self.assertEqual(self.calls("xcrun"), [])
        self.assertEqual(archive.read_bytes(), original)
        self.assertEqual((self.storage / archive.name).read_bytes(), original)

    def test_resume_recovers_failed_tap_push_without_extra_commit_or_rebuild(self):
        self.setup_publish()
        self.assert_failure(self.publish(TAG, env={"STUB_FAIL_TAP_PUSH": "1"}),
                            "tap push failed")
        archive = self.assert_artifacts()
        tap_head = self.git(self.tap, "rev-parse", "HEAD").stdout
        self.assertEqual(Path(str(archive) + ".tap-commit").read_text(), tap_head)
        original = archive.read_bytes()
        self.clear_calls()
        self.assert_success(self.release("--resume", TAG))
        self.assertEqual(self.calls("swift"), [])
        self.assertEqual(self.calls("xcrun"), [])
        self.assertEqual(self.git(self.tap, "rev-parse", "HEAD").stdout, tap_head)
        self.assertEqual(self.git(self.tap_remote, "rev-parse", "refs/heads/main").stdout,
                         tap_head)
        self.assertEqual(archive.read_bytes(), original)

    def test_resume_recovers_failed_app_push_without_rebuild(self):
        self.setup_publish()
        self.assert_failure(self.publish(TAG, env={"STUB_FAIL_APP_PUSH": "1"}),
                            "APP push failure")
        archive = self.assert_artifacts()
        original = archive.read_bytes()
        self.assertFalse((self.storage / "release.json").exists())
        self.clear_calls()
        self.assert_success(self.release("--resume", TAG))
        self.assertEqual(self.calls("swift"), [])
        self.assertEqual(self.calls("codesign"), [])
        self.assertEqual(self.calls("xcrun"), [])
        self.assertEqual((self.storage / archive.name).read_bytes(), original)

    def test_tap_changes_during_publication_are_not_overwritten_or_committed(self):
        self.setup_publish()
        head = self.git(self.tap, "rev-parse", "HEAD").stdout
        formula = (self.tap / "Formula" / "utisuna.rb").read_bytes()
        self.assert_failure(self.publish(
            TAG, env={"STUB_DIRTY_TAP_ON_CREATE": "1"}
        ), "Tap changed during publication")
        self.assert_artifacts()
        self.assertTrue((self.storage / "release.json").exists())
        self.assertEqual(self.git(self.tap, "rev-parse", "HEAD").stdout, head)
        self.assertEqual((self.tap / "Formula" / "utisuna.rb").read_bytes(), formula)
        self.assertEqual(self.git(self.tap, "show", ":other.txt").stdout,
                         "Concurrent staged change.\n")
        self.assertEqual((self.tap / "other.txt").read_text(),
                         "Concurrent unstaged change.\n")
        self.assertEqual((self.tap / "untracked.txt").read_text(),
                         "Concurrent untracked change.\n")
        self.assertFalse(any(
            "push" in call["args"] and str(self.tap) in call["args"]
            for call in self.calls("git")
        ))

    def test_tap_head_change_during_publication_is_not_overwritten_or_pushed(self):
        self.setup_publish()
        head = self.git(self.tap, "rev-parse", "HEAD").stdout
        formula = (self.tap / "Formula" / "utisuna.rb").read_bytes()
        self.assert_failure(self.publish(
            TAG, env={"STUB_COMMIT_TAP_ON_CREATE": "1"}
        ), "Tap HEAD changed during publication")
        self.assert_artifacts()
        self.assertNotEqual(self.git(self.tap, "rev-parse", "HEAD").stdout, head)
        self.assertEqual(self.git(self.tap, "log", "-1", "--format=%s").stdout,
                         "Concurrent tap commit\n")
        self.assertEqual(self.git(self.tap_remote, "rev-parse", "refs/heads/main").stdout,
                         head)
        self.assertEqual(self.git(self.tap, "status", "--porcelain").stdout, "")
        self.assertEqual((self.tap / "Formula" / "utisuna.rb").read_bytes(), formula)
        self.assertEqual((self.tap / "other.txt").read_text(),
                         "Concurrent committed change.\n")
        self.assertFalse(any(
            "push" in call["args"] and str(self.tap) in call["args"]
            for call in self.calls("git")
        ))

    def test_existing_release_resume_from_detached_tag_never_rewinds_source_branch(self):
        self.setup_publish()
        self.assert_success(self.publish(TAG))
        archive = self.archive()
        original = archive.read_bytes()
        (self.repo / "VERSION").write_text("1.2.4\n")
        self.git(self.repo, "commit", "--quiet", "-am", "Development after release")
        newer = self.git(self.repo, "rev-parse", "HEAD").stdout
        self.git(self.repo, "push", "--quiet", str(self.app_remote), "HEAD:refs/heads/main")
        self.git(self.repo, "checkout", "--quiet", "--detach", TAG)
        self.clear_calls()
        self.assert_success(self.release("--resume", TAG))
        self.assertEqual(self.calls("swift"), [])
        self.assertEqual(self.calls("codesign"), [])
        self.assertEqual(self.calls("xcrun"), [])
        self.assertFalse(any(call["args"][:1] == ["push"] for call in self.calls("git")))
        self.assertFalse(any(call["args"][:2] == ["release", "create"]
                             for call in self.calls("gh")))
        self.assertEqual(self.git(self.app_remote, "rev-parse", "refs/heads/main").stdout,
                         newer)
        self.assertEqual(self.git(self.repo, "rev-parse", "refs/heads/main").stdout, newer)
        self.assertEqual(archive.read_bytes(), original)

    def test_resume_rejects_unrelated_tap_commit_even_with_matching_marker(self):
        self.setup_publish()
        self.assert_success(self.notarize(TAG))
        (self.tap / "other.txt").write_text("Unrelated local commit.\n")
        self.git(self.tap, "commit", "--quiet", "-am", "Unrelated local commit")
        head = self.git(self.tap, "rev-parse", "HEAD").stdout
        Path(str(self.archive()) + ".tap-commit").write_text(head)
        self.clear_calls()
        self.assert_failure(self.release("--resume", TAG), "unrelated commits")
        self.assert_no_build_or_publication()
        self.assertEqual(self.git(self.tap, "rev-parse", "HEAD").stdout, head)

    def test_resume_rejects_changed_archive_commit_checksum_or_notary_receipt(self):
        self.assert_success(self.notarize(TAG))
        archive = self.assert_artifacts()
        for path, content, message in (
            (archive, archive.read_bytes() + b"tampered", "checksum"),
            (Path(str(archive) + ".sha256"), b"0" * 64 + b"\n", "checksum"),
            (Path(str(archive) + ".commit"), b"0" * 40 + b"\n", "source commit"),
            (Path(str(archive) + ".notarized"), b"0" * 64 + b"\n", "notarized"),
        ):
            with self.subTest(path=path.name):
                original = path.read_bytes()
                path.write_bytes(content)
                self.clear_calls()
                self.assert_failure(self.release("--resume", TAG), message)
                self.assert_no_build_or_publication()
                self.assertEqual(self.calls("gh"), [])
                self.assertEqual(path.read_bytes(), content)
                path.write_bytes(original)

    def test_resume_rejects_missing_archive_provenance_or_notary_receipt(self):
        self.assert_success(self.notarize(TAG))
        archive = self.assert_artifacts()
        for path in (archive, Path(str(archive) + ".sha256"),
                     Path(str(archive) + ".commit"), Path(str(archive) + ".notarized")):
            with self.subTest(path=path.name):
                content = path.read_bytes()
                path.unlink()
                self.clear_calls()
                self.assert_failure(self.release("--resume", TAG))
                self.assert_no_build_or_publication()
                self.assertEqual(self.calls("gh"), [])
                path.write_bytes(content)

    def test_resume_rejects_modified_archive_even_with_recomputed_checksum(self):
        self.assert_success(self.notarize(TAG))
        archive = self.archive()
        archive.write_bytes(archive.read_bytes() + b"changed after notarization\n")
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        Path(str(archive) + ".sha256").write_text(digest + "  " + archive.name + "\n")
        self.clear_calls()
        self.assert_failure(self.release("--resume", TAG), "notarized archive checksum")
        self.assert_no_build_or_publication()
        self.assertEqual(self.calls("gh"), [])

    def test_resume_rejects_unsigned_archive(self):
        self.assert_success(self.release(TAG))
        self.clear_calls()
        self.assert_failure(self.release(
            "--resume", TAG, env={"ARTIFACTS_DIR": "build/unsigned"}
        ), "notarization receipt")
        self.assert_no_build_or_publication()

    def test_resume_rejects_remote_asset_changes_without_overwriting_them(self):
        self.setup_publish()
        self.assert_success(self.publish(TAG))
        archive = self.archive()
        tap_head = self.git(self.tap, "rev-parse", "HEAD").stdout
        for name in (archive.name, archive.name + ".sha256"):
            with self.subTest(asset=name):
                remote = self.storage / name
                original = remote.read_bytes()
                changed = original + b"remote changed\n"
                remote.write_bytes(changed)
                self.clear_calls()
                self.assert_failure(self.release("--resume", TAG), "assets differ")
                self.assert_no_build_or_publication()
                self.assertEqual(remote.read_bytes(), changed)
                self.assertEqual(self.git(self.tap, "rev-parse", "HEAD").stdout, tap_head)
                self.assertEqual(list(archive.parent.glob(".utisuna-*")), [])
                remote.write_bytes(original)

    def test_resume_rejects_missing_remote_asset_without_replacing_release(self):
        self.setup_publish()
        self.assert_success(self.publish(TAG))
        (self.storage / (STEM + ".zip.sha256")).unlink()
        self.clear_calls()
        self.assert_failure(self.release("--resume", TAG), "download")
        self.assert_no_build_or_publication()
        self.assertFalse((self.storage / (STEM + ".zip.sha256")).exists())
        self.assertEqual(list(self.archive().parent.glob(".utisuna-*")), [])

    @unittest.skipUnless(REAL_MAKE, "make is required")
    def test_make_notarize_invokes_only_notarize_script(self):
        result = self.run_command([REAL_MAKE, "-n", "notarize", "TAG=" + TAG])
        self.assert_success(result)
        self.assertEqual(result.stdout.count("./scripts/notarize.sh"), 1)
        self.assertNotIn("./scripts/release.sh", result.stdout)
        self.assertEqual(self.calls("swift"), [])

    @unittest.skipUnless(REAL_MAKE, "make is required")
    def test_make_install_uses_custom_scratch_show_bin_path(self):
        scratch = self.repo / ".build" / "make scratch with spaces"
        prefix = self.base / "installation prefix"
        result = self.run_command([
            REAL_MAKE, "install", "BUILD_DIR=" + str(scratch), "PREFIX=" + str(prefix)
        ])
        self.assert_success(result)
        installed = prefix / "bin" / "utisuna"
        self.assertTrue(installed.is_file())
        self.assertEqual(self.run_command([installed, "--version"]).stdout, VERSION + "\n")
        calls = self.calls("swift")
        self.assertEqual(len(calls), 2)
        self.assertNotIn("--show-bin-path", calls[0]["args"])
        self.assertIn("--show-bin-path", calls[1]["args"])
        for call in calls:
            self.assertEqual(call["args"][call["args"].index("--scratch-path") + 1],
                             str(scratch))
        self.assert_local_only()


if __name__ == "__main__":
    unittest.main()
