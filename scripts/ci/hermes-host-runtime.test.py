"""Bounded scope guards; optional real prepared-core/package probes, no connect/build.

Retain every disposable fixture. Run the actual probes with --source, --sha,
--home-root, --tools-root and --plugin pointing at the caller-owned installation.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("hermes_host_runtime", HERE / "hermes-host-runtime.py")
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
OPTIONS = argparse.Namespace(source=None, sha=None, home_root=None, tools_root=None, plugin=None)


class ScopeGuards(unittest.TestCase):
    def setUp(self):
        self.scratch = Path(tempfile.mkdtemp(prefix="ih-runtime-guard-")).resolve()
        self.home = self.scratch / "owned-root"
        self.home.mkdir()
        self.tools = self.home / "tools"
        self.env = {"HOME": str(self.scratch), "HERMES_HOME": str(self.home), "HERMES_RUNTIME_DIR": str(self.tools)}

    def check(self, home=None, tools=None, env=None):
        return helper.require_scope(str(home or self.home), str(tools or self.tools),
                                    environment=self.env if env is None else env)

    def test_explicit_roots_and_normal_scope_are_required(self):
        for roots in ((None, self.tools), (self.home, None)):
            with self.assertRaises(AssertionError):
                helper.require_scope(*roots, environment=self.env)
        with self.assertRaises(AssertionError):
            self.check(env={"HOME": str(self.scratch)})

    def test_missing_root_and_changed_tools_are_refused(self):
        with self.assertRaises(AssertionError):
            self.check(home=self.scratch / "missing")
        with self.assertRaises(AssertionError):
            self.check(tools=self.scratch / "other-tools")
        with self.assertRaises(AssertionError):
            self.check(env={**self.env, "HERMES_RUNTIME_DIR": str(self.scratch / "other-tools")})

    def test_production_root_and_unrelated_profile_are_refused(self):
        production = self.scratch / ".hermes"
        production.mkdir()
        with self.assertRaises(AssertionError):
            self.check(home=production, tools=production / "tools",
                       env={**self.env, "HERMES_HOME": str(production), "HERMES_RUNTIME_DIR": str(production / "tools")})
        unrelated = self.scratch / "unrelated"
        unrelated.mkdir()
        with self.assertRaises(AssertionError):
            self.check(env={**self.env, "HERMES_HOME": str(unrelated)})

    def test_existing_default_receiving_state_and_jobs_are_refused(self):
        (self.home / "state.db").touch()
        with self.assertRaises(AssertionError):
            self.check()
        other = self.scratch / "jobs-root"
        (other / "cron").mkdir(parents=True)
        (other / "cron/jobs.json").write_text("[]")
        with self.assertRaises(AssertionError):
            self.check(home=other, tools=other / "tools",
                       env={**self.env, "HERMES_HOME": str(other), "HERMES_RUNTIME_DIR": str(other / "tools")})

    def test_exact_named_profile_retains_the_same_tools_owner(self):
        profile = self.home / "profiles" / "isolated"
        profile.mkdir(parents=True)
        self.assertEqual(self.check(env={**self.env, "HERMES_HOME": str(profile)}), (self.home, self.tools))


class SourceGuards(unittest.TestCase):
    def setUp(self):
        self.source = Path(tempfile.mkdtemp(prefix="ih-source-guard-")).resolve()
        subprocess.run(["git", "init", "-q", str(self.source)], check=True)
        fixture = """blob
mark :1
data 6
clean

commit refs/heads/main
committer Fixture <fixture@example.invalid> 1 +0000
data 8
fixture
M 100644 :1 visible.py
"""
        subprocess.run(["git", "fast-import", "--quiet"], cwd=self.source, input=fixture, text=True, check=True)
        subprocess.run(["git", "checkout", "-q", "main"], cwd=self.source, check=True)
        subprocess.run(["git", "remote", "add", "origin", "https://github.com/morajabi/hermes-agent.git"], cwd=self.source, check=True)
        self.sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.source, text=True).strip()

    def test_actual_git_rejects_dirty_worktree_and_index(self):
        self.assertEqual(helper.require_source(self.source, self.sha, "morajabi/hermes-agent"), self.source)
        (self.source / "visible.py").write_text("changed\n")
        with self.assertRaises(AssertionError):
            helper.require_source(self.source, self.sha, "morajabi/hermes-agent")
        subprocess.run(["git", "add", "visible.py"], cwd=self.source, check=True)
        with self.assertRaises(AssertionError):
            helper.require_source(self.source, self.sha, "morajabi/hermes-agent")

    def test_actual_git_error_cannot_become_clean_provenance(self):
        (self.source / ".git").rename(self.source / "retained-git-metadata")
        with self.assertRaises(subprocess.CalledProcessError):
            helper.require_source(self.source, self.sha, "morajabi/hermes-agent")


class ActualPreparedHost(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not all((OPTIONS.source, OPTIONS.sha, OPTIONS.home_root, OPTIONS.tools_root, OPTIONS.plugin)):
            raise unittest.SkipTest("Actual host probes require explicit prepared source/root/package paths")
        cls.source = Path(OPTIONS.source).resolve()
        cls.home = Path(OPTIONS.home_root).resolve()
        cls.tools = Path(OPTIONS.tools_root).resolve()
        cls.env = {key: os.environ[key] for key in ("PATH", "HOME", "USER", "LANG", "LC_ALL", "TMPDIR") if key in os.environ}
        cls.env.update(HERMES_HOME=str(cls.home), HERMES_RUNTIME_DIR=str(cls.tools))

    def probe(self, *, home=None, tools=None, sha=None, repository="morajabi/hermes-agent", active=None):
        home, tools = home or self.home, tools or self.tools
        return subprocess.run([sys.executable, "-I", "-B", str(HERE / "hermes-host-runtime.py"), "inspect",
            "--source", str(self.source), "--sha", sha or OPTIONS.sha, "--repository", repository,
            "--home-root", str(home), "--tools-root", str(tools)], capture_output=True, text=True, timeout=45,
            env={**self.env, "HERMES_HOME": str(active or home), "HERMES_RUNTIME_DIR": str(tools)})

    def test_real_normal_activation_loads_exact_core_and_committed_dependencies(self):
        result = self.probe()
        self.assertEqual(result.returncode, 0, "Real committed-runtime guard failed")
        value = json.loads(result.stdout)
        self.assertEqual(value["source"], str(self.source))
        self.assertEqual(value["version"]["commit"], OPTIONS.sha)
        self.assertEqual(value["intakeVersion"], 1)
        self.assertTrue(value["dependencyImportsFromCommittedGeneration"])
        self.assertTrue(Path(value["selectedEnvironment"]).is_relative_to(self.home / "installs"))

    def test_real_uncommitted_root_refuses_without_pm_provisioning(self):
        home = Path(tempfile.mkdtemp(prefix="ih-uncommitted-"))
        result = self.probe(home=home, tools=home / "tools")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PM has not committed", result.stderr)
        self.assertFalse((home / "installs").exists())
        self.assertFalse((home / "tools").exists())

    def test_real_wrong_identity_and_tools_refuse_before_activation(self):
        for arguments in ({"sha": "0" * 40}, {"repository": "NousResearch/hermes-agent"},
                          {"tools": self.home / "different-tools"}):
            result = self.probe(**arguments)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(result.stdout.strip())

    def test_named_profile_cannot_be_prepared_root_before_sync_or_launcher(self):
        # Real helper main and canonical core mapping; intercept only effectful
        # child calls so the failing old path cannot provision a profile's parent.
        # This is a setup-order guard, not receiving/provider evidence.
        code = """
import importlib.util, json, subprocess, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('owned_runtime_helper', sys.argv[1])
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
calls = {'syncCalls':0, 'launcherCalls':0}
original = subprocess.run
launcher = sys.argv[5]
def observe(argv, *args, **kwargs):
    if argv[0] == sys.executable and 'from pm import sync_venv' in ' '.join(argv):
        calls['syncCalls'] += 1
        return subprocess.CompletedProcess(argv, 0)
    if argv[0] == launcher:
        calls['launcherCalls'] += 1
        return subprocess.CompletedProcess(argv, 0)
    return original(argv, *args, **kwargs)
subprocess.run = observe
profile = Path(sys.argv[4]).resolve()
sys.argv = [sys.argv[1], 'prepare', '--source',sys.argv[2], '--sha',sys.argv[3],
            '--repository','morajabi/hermes-agent', '--home-root',str(profile),
            '--tools-root',str(profile/'tools'), '--launcher',launcher]
try:
    helper.main()
except AssertionError:
    pass
else:
    raise AssertionError('A named profile was accepted as the prepared root')
from hermes_constants import get_default_hermes_root
assert get_default_hermes_root(home=profile).resolve() == profile.parent.parent
assert calls == {'syncCalls':0, 'launcherCalls':0}, 'Rejection occurred after child effects: ' + str(calls)
print(json.dumps({'profileRejected':True, 'actualCanonicalParentVerified':True, **calls}))
"""
        owned = Path(tempfile.mkdtemp(prefix="ih-profile-root-guard-")).resolve()
        profile = owned / "profiles" / "empty"
        profile.mkdir(parents=True)
        launcher = str(Path(sys.executable).parent / "hermes")
        result = subprocess.run([sys.executable, "-I", "-B", "-c", code,
            str(HERE / "hermes-host-runtime.py"), str(self.source), OPTIONS.sha, str(profile), launcher],
            capture_output=True, text=True, timeout=15,
            env={**self.env, "HERMES_HOME": str(profile), "HERMES_RUNTIME_DIR": str(profile / "tools")})
        self.assertEqual(result.returncode, 0, result.stderr[-1500:])
        self.assertEqual(json.loads(result.stdout), {"profileRejected": True, "actualCanonicalParentVerified": True,
                                                   "syncCalls": 0, "launcherCalls": 0})
        self.assertFalse((owned / "installs").exists())
        self.assertFalse((profile / "tools").exists())

    def test_two_fresh_profiles_share_generation_with_independent_state_paths(self):
        values = []
        for _ in range(2):
            profile = self.home / "profiles" / ("guard-" + uuid.uuid4().hex[:8])
            profile.mkdir(parents=True)
            result = self.probe(active=profile)
            self.assertEqual(result.returncode, 0, "Actual named profile failed to retain prepared selection")
            value = json.loads(result.stdout)
            values.append((profile / "state.db", value["selectedEnvironment"], value["managerPython"]))
        self.assertNotEqual(values[0][0], values[1][0])
        self.assertEqual(values[0][1:], values[1][1:])

    def test_actual_packed_constructor_rejects_zero_and_accepts_normal_missing_setting(self):
        code = """
import importlib.util, json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import hermes_bootstrap
from gateway.config import PlatformConfig
from gateway.platform_registry import PlatformEntry, platform_registry
sys.path.insert(0, sys.argv[2])
from inline.adapter import InlineAdapter
platform_registry.register(PlatformEntry(name='inline', label='Inline', adapter_factory=InlineAdapter, check_fn=lambda:True))
spec = importlib.util.spec_from_file_location('owned_flow', sys.argv[3])
flow = importlib.util.module_from_spec(spec)
spec.loader.exec_module(flow)
environment = {'INLINE_E2E_HUMAN_ID':'20', 'INLINE_E2E_BOT_ID':'10', 'INLINE_TOKEN':'10:fake',
               'INLINE_BASE_URL':'http://127.0.0.1:9', 'HERMES_HOME':sys.argv[4]}
config = flow.configuration('http://127.0.0.1:9/v1', environment=environment)
assert config['gateway']['standalone'] is True
assert 'sidecar_port' not in config['platforms']['inline']
bad = dict(config['platforms']['inline'], sidecar_port=0)
try:
    InlineAdapter(PlatformConfig.from_dict(bad))
except ValueError as error:
    assert '1 to 65535' in str(error)
else:
    raise AssertionError('The actual package unexpectedly accepted explicit zero')
adapter = InlineAdapter(PlatformConfig.from_dict(config['platforms']['inline']))
assert adapter._listen_port == 0 and adapter._sidecar_proc is None
assert Path(type(adapter).__module__.replace('.', '/')).name == 'adapter'
assert Path(sys.modules[type(adapter).__module__].__file__).resolve().is_relative_to(Path(sys.argv[2]).resolve())
print(json.dumps({'explicitZeroRejected':True, 'missingSettingAccepted':True, 'noConnect':True}))
"""
        profile = self.home / "profiles" / ("constructor-" + uuid.uuid4().hex[:8])
        profile.mkdir(parents=True)
        result = subprocess.run([sys.executable, "-I", "-B", "-c", code, str(self.source),
            str(Path(OPTIONS.plugin).resolve()), str(HERE / "hermes-local-flow.py"), str(profile)],
            capture_output=True, text=True, timeout=30, env={**self.env, "HERMES_HOME": str(profile)})
        self.assertEqual(result.returncode, 0, "Synthetic constructor diagnostics: " + result.stderr[-2000:])
        self.assertEqual(json.loads(result.stdout), {"explicitZeroRejected": True, "missingSettingAccepted": True, "noConnect": True})


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ("source", "sha", "home-root", "tools-root", "plugin"):
        parser.add_argument("--" + name)
    OPTIONS, unittest_args = parser.parse_known_args()
    unittest.main(argv=[sys.argv[0], *unittest_args])
