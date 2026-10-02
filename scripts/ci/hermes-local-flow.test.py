"""Actual prepared-core fixture calibration; not receiving qualification.

Normal packed install/CLI enable and production worker construction/startup are
used. The startup negative endpoint is real closed loopback, not an auth/transport
mock. Observers do not alter startup outcomes. No receiving receipt is produced.
Retain every fresh profile, and run with explicit caller-owned prepared paths.
"""
import argparse
import asyncio
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import signal
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid


HERE = Path(__file__).resolve().parent
OPTIONS = argparse.Namespace(source=None, home_root=None, tools_root=None, consumer=None, node_bin=None,
                             baseline_flow=None, installer_bin=None, report=None)
OBSERVATIONS = []


PRELUDE = """
import asyncio, importlib.util, inspect, json, os, socket, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
assert not (Path(sys.argv[1])/'.env').exists()
import hermes_bootstrap
spec = importlib.util.spec_from_file_location('owned_flow', sys.argv[2])
flow = importlib.util.module_from_spec(spec)
spec.loader.exec_module(flow)
home = Path(os.environ['HERMES_HOME'])
report_path = Path(os.environ['CALIBRATION_REPORT'])
from hermes_cli.config import atomic_config_write, require_readable_config_before_write
"""


@unittest.skipUnless(os.name == "posix", "The process-death receiving lane requires POSIX process groups")
class ActualCommandOwnership(unittest.IsolatedAsyncioTestCase):
    async def exercise_held_descendant(self, *, cancel, leader_exits):
        spec = importlib.util.spec_from_file_location("owned_command_flow", HERE / "hermes-local-flow.py")
        flow = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(flow)
        directory = Path(tempfile.mkdtemp(prefix="ih-command-owned-"))
        ready = directory / "owned-pids.json"
        child_code = "import time; time.sleep(600)"
        leader_code = """
import json, os, subprocess, sys, time
from pathlib import Path
child = subprocess.Popen([sys.executable, '-I', '-B', '-c', sys.argv[2]])
Path(sys.argv[1]).write_text(json.dumps({'leader':os.getpid(), 'descendant':child.pid,
                                      'group':os.getpgrp()}))
if sys.argv[3] == 'exit':
    sys.exit(0)
time.sleep(600)
"""
        env = {key: os.environ[key] for key in ("PATH", "HOME", "USER", "TMPDIR", "LANG", "LC_ALL") if key in os.environ}
        pids = None
        with patch.dict(os.environ, {"INLINE_E2E_CONSUMER": str(directory)}):
            task = asyncio.create_task(flow.command(sys.executable, "-I", "-B", "-c", leader_code,
                str(ready), child_code, "exit" if leader_exits else "hold", env=env, timeout=3))
            try:
                deadline = time.monotonic() + 2.5
                while not ready.exists() and time.monotonic() < deadline:
                    await asyncio.sleep(0.02)
                self.assertTrue(ready.exists(), "The actual descendant was not started")
                pids = json.loads(ready.read_text())
                self.assertTrue(self.is_running(pids["descendant"]), "The descendant must be alive before settlement")
                if cancel:
                    task.cancel()
                    with self.assertRaises(asyncio.CancelledError):
                        await task
                else:
                    with self.assertRaises(TimeoutError):
                        await task
                deadline = time.monotonic() + 3
                while any(self.is_running(pids[key]) for key in ("leader", "descendant")) and time.monotonic() < deadline:
                    await asyncio.sleep(0.02)
                self.assertFalse(self.is_running(pids["descendant"]), "The held descendant survived command settlement")
                self.assertFalse(self.is_running(pids["leader"]), "The command leader survived settlement")
                self.assertEqual(pids["group"], pids["leader"], "The command must own its isolated process group")
                OBSERVATIONS.append({"case":"owned-command-cancellation" if cancel else "owned-command-timeout",
                    "leaderExitedBeforeSettlement":leader_exits, "leaderStopped":True, "descendantStopped":True,
                    "ownedGroup":True, "fixture":str(directory)})
            finally:
                if not task.done():
                    task.cancel()
                    try:
                        await task
                    except asyncio.CancelledError:
                        pass
                # Only the exact PIDs spawned by this fixture may be cleaned up
                # when testing the known-broken baseline; never a shared group.
                if pids:
                    for key in ("descendant", "leader"):
                        if self.is_running(pids[key]):
                            os.kill(pids[key], signal.SIGKILL)

    @staticmethod
    def is_running(pid):
        result = subprocess.run(["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True, timeout=3)
        return result.returncode == 0 and bool(result.stdout.strip()) and not result.stdout.strip().startswith("Z")

    async def test_timeout_stops_descendant_even_after_command_leader_exits(self):
        await self.exercise_held_descendant(cancel=False, leader_exits=True)

    async def test_cancellation_stops_live_command_and_held_descendant(self):
        await self.exercise_held_descendant(cancel=True, leader_exits=False)


class ActualFixtureCalibration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not all((OPTIONS.source, OPTIONS.home_root, OPTIONS.tools_root, OPTIONS.consumer, OPTIONS.node_bin)):
            raise unittest.SkipTest("Explicit prepared host and packed consumer paths are required")
        cls.source = Path(OPTIONS.source).resolve()
        cls.root = Path(OPTIONS.home_root).resolve()
        cls.tools = Path(OPTIONS.tools_root).resolve()
        cls.consumer = Path(OPTIONS.consumer).resolve()
        cls.env = {key: os.environ[key] for key in ("PATH", "HOME", "USER", "TMPDIR", "LANG", "LC_ALL") if key in os.environ}
        cls.env.update(HERMES_RUNTIME_DIR=str(cls.tools), HERMES_PREPARED_HOME_ROOT=str(cls.root),
                       HERMES_PREPARED_RUNTIME_DIR=str(cls.tools), HERMES_BIN=str(Path(sys.executable).parent / "hermes"),
                       HERMES_PYTHON_BIN=sys.executable, INLINE_NODE_BIN=OPTIONS.node_bin,
                       INLINE_E2E_CONSUMER=str(cls.consumer), INLINE_E2E_HUMAN_ID="20", INLINE_E2E_BOT_ID="10",
                       INLINE_TOKEN="10:offline-fixture", INLINE_BASE_URL="http://127.0.0.1:9")
        cls.env["INLINE_HERMES_BIN"] = cls.env["HERMES_BIN"]
        assert cls.root.is_dir() and cls.tools == cls.root / "tools"
        assert cls.root != (Path(cls.env["HOME"]) / ".hermes").resolve()
        assert not (cls.root / "state.db").exists() and not (cls.root / "cron/jobs.json").exists()
        assert not (cls.root / ".env").exists() and not (cls.source / ".env").exists()
        assert (cls.consumer / "node_modules/.bin/inline-hermes").is_file()
        # Use the reviewed pre-effect scope/source guards before creating a
        # profile or invoking either normal installer/launcher.
        spec = importlib.util.spec_from_file_location("owned_runtime", HERE / "hermes-host-runtime.py")
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=cls.source, text=True).strip()
        helper.require_scope(cls.root, cls.tools, environment={**cls.env, "HERMES_HOME":str(cls.root)})
        helper.require_source(cls.source, head, "morajabi/hermes-agent")
        helper.require_default_root(cls.root)

    def profile(self):
        home = self.root / "profiles" / ("cal-" + uuid.uuid4().hex[:8])
        home.mkdir(parents=True)
        return home, {**self.env, "HERMES_HOME": str(home)}

    def run_probe(self, code, env, *arguments, timeout=30):
        report = Path(env["HERMES_HOME"]) / ("calibration-" + uuid.uuid4().hex + ".json")
        result = subprocess.run([sys.executable, "-I", "-B", "-c", PRELUDE + code,
            str(self.source), str(HERE / "hermes-local-flow.py"), *map(str, arguments)],
            capture_output=True, text=True, timeout=timeout, env={**env, "CALIBRATION_REPORT":str(report)}, cwd=self.consumer)
        # Do not dump child logs/config/provider content on a failed assertion.
        errors = re.findall(r"(?m)^([A-Za-z][A-Za-z0-9_.]*(?:Error|Exception)|StopIteration)\b", result.stderr)
        self.assertEqual(result.returncode, 0, "Actual fixture probe failed; return code " + str(result.returncode)
                         + "; failure classes " + ",".join(errors))
        self.assertTrue(report.is_file(), "Actual probe emitted no assertion report")
        value = json.loads(report.read_text())
        OBSERVATIONS.append(value)
        return value

    def test_actual_normal_enable_survives_worker_configuration_and_wires_startup(self):
        home, env = self.profile()
        self.run_probe("flow.write_profile_configuration('http://127.0.0.1:9/v1')\nreport_path.write_text('{}')\n", env)
        probe_log = home / "canonical-install-probes.jsonl"
        observer = home / "observe-canonical-hermes"
        observer.write_text("#!" + sys.executable + "\n" + """
import json, os, sys
from pathlib import Path
source = Path(""" + repr(str(self.consumer / "node_modules/@inline-chat/hermes-agent-adapter/plugin/inline")) + """)
target = Path(os.environ['HERMES_HOME'])/'plugins/inline'
files = [p for p in source.rglob('*') if p.is_file()]
equal = all((target/p.relative_to(source)).is_file() and
            p.read_bytes() == (target/p.relative_to(source)).read_bytes() for p in files)
with Path(""" + repr(str(probe_log)) + """).open('a') as log:
    log.write(json.dumps({'args':sys.argv[1:], 'allRuntimeBytesMatch':equal})+'\\n')
os.execv(""" + repr(env["HERMES_BIN"]) + """, [""" + repr(env["HERMES_BIN"]) + """, *sys.argv[1:]])
""")
        observer.chmod(0o755)
        env["INLINE_HERMES_BIN"] = str(observer)
        installer = OPTIONS.installer_bin or str(self.consumer / "node_modules/.bin/inline-hermes")
        for command in ([OPTIONS.node_bin, installer,
                         "install", "--hermes-home", str(home), "--json"],
                        [env["HERMES_BIN"], "plugins", "enable", "inline-platform"]):
            self.run_probe("asyncio.run(flow.command(*sys.argv[3:], env=dict(os.environ)))\nreport_path.write_text('{}')\n",
                           env, *command, timeout=40)
        probes = [json.loads(line) for line in probe_log.read_text().splitlines()]
        self.assertEqual(probes, [{"args":["inline", "status", "--json"], "allRuntimeBytesMatch":True}])
        value = self.run_probe("""
config = require_readable_config_before_write(home/'config.yaml')
enabled = config['plugins']['enabled']
assert 'inline-platform' in enabled
config['platforms']['inline']['connect_timeout_ms'] = 1000
atomic_config_write(home/'config.yaml', config)
with socket.socket() as closed:
    assert closed.connect_ex(('127.0.0.1',9)) != 0
from gateway.run import GatewayRunner
original_start = GatewayRunner.start
original_wire = GatewayRunner._wire_adapter_handlers
observed = {}
def observe_wire(runner, adapter, *args, **kwargs):
    result = original_wire(runner, adapter, *args, **kwargs)
    if adapter.platform.value == 'inline':
        assert adapter._durable_intake_available()
        packaged = Path(os.environ['INLINE_E2E_CONSUMER'])/'node_modules/@inline-chat/hermes-agent-adapter/plugin/inline/adapter.py'
        assert Path(inspect.getfile(type(adapter))).resolve().read_bytes() == packaged.read_bytes()
        observed['packedAdapterLoaded'] = True
        observed['durableHandlerWired'] = True
    return result
async def observe_start(runner, *args, **kwargs):
    # Observation only: the ordinary startup implementation runs unchanged.
    result = await original_start(runner, *args, **kwargs)
    observed['normalStartReturned'] = result
    observed['enabledInline'] = any(p.value=='inline' and c.enabled for p,c in runner.config.platforms.items())
    failed = next((v for p,v in runner._failed_platforms.items() if p.value=='inline'), None)
    assert failed is not None, 'No real Inline connection attempt was retained for retry'
    observed['realClosedEndpointAttempted'] = True
    observed['authenticatedReceiving'] = False
    return result
GatewayRunner.start = observe_start
GatewayRunner._wire_adapter_handlers = observe_wire
job = {'reply':'no-input-fixture', 'hold':False, 'expectedInputs':[],
       **{key:str(home/('probe-'+key+'.json')) for key in ('observations','ready','stop','query','history','status')}}
try:
    asyncio.run(flow.worker(job))
except RuntimeError as error:
    assert isinstance(error.__cause__, StopIteration), 'Unexpected worker failure'
else:
    raise AssertionError('The closed endpoint unexpectedly authenticated')
after = require_readable_config_before_write(home/'config.yaml')
assert after['plugins']['enabled'] == enabled
assert after['platforms']['inline']['connect_timeout_ms'] == 1000
assert observed['normalStartReturned'] and observed['enabledInline']
observed.update(case='normal-plugin-admission-preserved', nativeEnablePersisted=True,
                pluginConfigurationPreserved=True, profile=str(home))
report_path.write_text(json.dumps(observed))
""", env)
        value.update(canonicalInstallProbeCount=len(probes), realCanonicalHostDelegated=True,
                     installProbeAfterAllRuntimeBytesMatch=True, installerBin=installer)
        self.assertTrue(value["durableHandlerWired"] and value["pluginConfigurationPreserved"])
        self.assertFalse(value["authenticatedReceiving"])

    def test_actual_context_resolver_uses_declared_fixture_contract_without_http_probes(self):
        if not OPTIONS.baseline_flow:
            self.skipTest("The retained pre-calibration source is required for the causal probe comparison")
        _home, env = self.profile()
        value = self.run_probe("""
legacy_spec = importlib.util.spec_from_file_location('prior_flow', sys.argv[3])
legacy = importlib.util.module_from_spec(legacy_spec)
legacy_spec.loader.exec_module(legacy)
job = {'reply':'no-input-fixture', 'hold':False, 'expectedInputs':[], 'observations':str(home/'provider.json')}
from gateway.run import _resolve_gateway_model_context, _resolve_runtime_agent_kwargs
observed = []
for label, producer in [('baseline',legacy), ('calibrated',flow)]:
    provider = flow.DeterministicProvider(home,job)
    paths = []
    handler = provider.server.RequestHandlerClass
    original_get, original_post = handler.do_GET, handler.do_POST
    def get(self):
        paths.append(('GET',self.path))
        return original_get(self)
    def post(self):
        paths.append(('POST',self.path))
        return original_post(self)
    handler.do_GET, handler.do_POST = get, post
    try:
        # The baseline config is immutable prior producer bytes; native writer,
        # resolver, HTTP handler and runtime routing remain actual implementations.
        atomic_config_write(home/'config.yaml', producer.configuration(provider.url))
        runtime = _resolve_runtime_agent_kwargs()
        context = _resolve_gateway_model_context()
        assert runtime['api_mode'] == 'chat_completions'
        assert runtime['base_url'] == provider.url
        if label == 'baseline':
            assert ('POST','/api/show') in paths, 'The claimed metadata probe was not reproduced'
        else:
            assert paths == [], 'The declared fixed context still probed metadata'
            assert context.context_length == 65536 and context.context_source == 'config'
        assert not provider.calls and not provider.entries
        observed.append({'producer':label, 'httpRequests':paths, 'contextLength':context.context_length,
                         'contextSource':context.context_source, 'apiMode':runtime['api_mode'],
                         'providerConversations':0})
    finally:
        provider.close()
report_path.write_text(json.dumps({'case':'actual-model-context-probe-calibration', 'observations':observed,
                                 'receivingMatrix':'not run', 'profile':str(home)}))
""", env, Path(OPTIONS.baseline_flow).resolve())
        self.assertEqual(value["observations"][1]["httpRequests"], [])


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ("source", "home-root", "tools-root", "consumer", "node-bin", "baseline-flow", "installer-bin", "report"):
        parser.add_argument("--" + name)
    OPTIONS, unittest_args = parser.parse_known_args()
    program = unittest.main(argv=[sys.argv[0], *unittest_args], exit=False)
    if OPTIONS.report:
        Path(OPTIONS.report).write_text(json.dumps({"kind":"fixture-calibration-only", "receivingMatrix":"not run",
            "observations":OBSERVATIONS, "successful":program.result.wasSuccessful()}, indent=2)+"\n")
    sys.exit(0 if program.result.wasSuccessful() else 1)
