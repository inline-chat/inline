"""Prepare/probe an owned CI root through Hermes' existing PM selection owner.

This is host admission, not receiving evidence. No selection facts are written
here; PM publishes them. The exact Git checkout remains the core import owner.
"""
from __future__ import annotations

import argparse
from dataclasses import asdict
import json
import os
from pathlib import Path
import subprocess
import sys


def require_scope(home_root, tools_root, *, environment=None):
    env = os.environ if environment is None else environment
    assert home_root and tools_root, "Explicit prepared home and tools roots are required"
    assert env.get("HERMES_HOME") and env.get("HERMES_RUNTIME_DIR"), "Normal runtime scope is required"
    home, tools = Path(home_root).resolve(), Path(tools_root).resolve()
    assert home.is_dir(), "Prepared home root is missing"
    assert home != (Path(env["HOME"]) / ".hermes").resolve(), "Production home cannot qualify CI receiving"
    assert tools == home / "tools", "Prepared tools must retain their original home scope"
    assert Path(env["HERMES_RUNTIME_DIR"]).resolve() == tools, "Runtime tools handoff differs"
    active = Path(env["HERMES_HOME"]).resolve()
    assert active == home or (active.parent == home / "profiles" and active.is_dir()), \
        "Active home must be the prepared root or one fresh named profile"
    if hasattr(os, "getuid"):
        assert home.stat().st_uid == os.getuid(), "Prepared home must belong to this caller"
    assert not (home / "state.db").exists() and not (home / "cron/jobs.json").exists(), \
        "Prepared default home must not contain receiving state or cron jobs"
    return home, tools


def require_source(source, sha, repository):
    source = Path(source).resolve()
    assert not (source / ".env").exists(), "Host qualification requires a secret-free source"
    def git(*args):
        return subprocess.check_output(["git", *args], cwd=source, text=True,
            stderr=subprocess.PIPE, timeout=10).strip()
    assert git("rev-parse", "HEAD") == sha, "Prepared runtime source differs from the qualified commit"
    assert git("remote", "get-url", "origin") == f"https://github.com/{repository}.git", \
        "Prepared runtime source differs from the qualified origin"
    for stage in ((), ("--cached",)):
        assert not git("diff", *stage, "--no-ext-diff", "--no-textconv", "--name-only"), \
            "Prepared runtime source has tracked modifications"
    sys.path.insert(0, str(source))
    return source


def require_default_root(home_root):
    from hermes_constants import get_default_hermes_root
    home = Path(home_root).resolve()
    assert get_default_hermes_root(home=home).resolve() == home, \
        "Prepared home must be a canonical default root, not a named profile"


def inspect_runtime(source, home_root, tools_root):
    home, tools = require_scope(home_root, tools_root)
    require_default_root(home)
    from hermes_constants import get_default_hermes_root
    from pm.environments import committed_venv, dependency_home_root, site_packages, store_root
    from pm.install import venv_is_current
    from pm.runtime import runtime_python
    assert get_default_hermes_root(home=os.environ["HERMES_HOME"]).resolve() == home
    assert dependency_home_root().resolve() == home and store_root(source).resolve() == tools
    selected = committed_venv(source)
    assert selected is not None, "PM has not committed an application environment for this root/source"
    assert venv_is_current(project_root=source), "Prepared PM application stamp is no longer current"
    # bootstrap=False refuses missing/stale manager state instead of provisioning it.
    manager = runtime_python(bootstrap=False)
    import hermes_bootstrap  # normal entry-point dependency activation and generation lease
    import gateway.platforms.base as base
    import hermes_state
    from hermes_cli import version_info
    import openai
    assert Path(base.__file__).resolve().parents[2] == source
    assert Path(hermes_state.__file__).resolve().parent == source
    assert Path(version_info.__file__).resolve().parents[1] == source
    assert Path(openai.__file__).resolve().is_relative_to(site_packages(selected).resolve()), \
        "Normal bootstrap did not select the committed dependency environment"
    version = version_info.get_version_info()
    return {"source": str(source), "homeRoot": str(home), "toolsRoot": str(tools),
            "selectedEnvironment": str(selected), "managerPython": str(manager),
            "pythonBin": str(Path(sys.executable).absolute()), "version": asdict(version),
            "intakeVersion": getattr(base.BasePlatformAdapter, "durable_intake_version", None),
            "dependencyImportsFromCommittedGeneration": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("prepare", "inspect"))
    parser.add_argument("--source", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--home-root", required=True)
    parser.add_argument("--tools-root", required=True)
    parser.add_argument("--launcher")
    options = parser.parse_args()
    require_scope(options.home_root, options.tools_root)
    source = require_source(options.source, options.sha, options.repository)
    # Bind the verified core's canonical home mapping before any PM mutation.
    require_default_root(options.home_root)
    if options.mode == "prepare":
        assert options.launcher, "Normal launcher is required for host admission"
        # Cold preparation has its own bounded host phase. The receiving lane's
        # per-command/matrix budgets remain unchanged, and no stamp is fabricated.
        code = "import sys; sys.path.insert(0, sys.argv[1]); from pm import sync_venv; sync_venv(explicit=True)"
        subprocess.run([sys.executable, "-I", "-B", "-c", code, str(source)], check=True, timeout=300)
        subprocess.run([options.launcher, "plugins", "list"], check=True, timeout=30,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    runtime = inspect_runtime(source, options.home_root, options.tools_root)
    assert runtime["version"]["commit"] == options.sha, "Loaded source version does not match the qualified commit"
    print(json.dumps(runtime, sort_keys=True))


if __name__ == "__main__":
    main()
