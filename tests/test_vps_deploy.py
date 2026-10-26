"""Run the real SSH entrypoint against a local Git repo and a simulated Docker CLI."""

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

DEPLOY_SCRIPT = Path(__file__).resolve().parents[1] / ".github/scripts/deploy-vps.sh"
OLD_ENV = "APP_IMAGE=app:old\nGIT_SHORT_HASH=old\nGIT_TAG=v1\n"
OLD_IMAGES = {"panda-app": "sha256:" + "a" * 64, "nginx": "sha256:" + "b" * 64}

DOCKER_STUB = r"""
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
state_file = Path(os.environ["DOCKER_STATE"])
state = json.loads(state_file.read_text())
scenario = os.environ["DEPLOY_SCENARIO"]
if args[0] == "--config":
    args = args[2:]
command = args.pop(0)
event = {"command": command, "args": args}
state["events"].append(event)
code = 0
output = ""
if command == "login":
    sys.stdin.read()
    if scenario == "login-failure":
        code = 1
elif command == "compose":
    files = []
    env_file = None
    while args and args[0].startswith("-"):
        option, value = args[:2]
        args = args[2:]
        if option == "-f":
            files.append(Path(value))
        elif option == "--env-file":
            env_file = Path(value)
    action = args.pop(0)
    event["action"] = action
    event["phase"] = state["phase"]
    event["files"] = [p.read_text() for p in files]
    if action == "config":
        env = dict(line.split("=", 1) for line in env_file.read_text().splitlines()) if env_file else {}
        output = files[0].read_text() + "\n# image: " + os.environ.get("APP_IMAGE", env.get("APP_IMAGE", "local"))
    elif action == "ps" and "--quiet" in args:
        if not (scenario.startswith("first-deploy") and state["phase"] == "previous"):
            service = args[-1]
            if not (scenario == "missing-container" and state["phase"] == "new" and service == "panda-app"):
                output = state["phase"] + ":" + service
    elif action == "pull":
        if scenario == "pull-failure":
            code = 1
    elif action == "up":
        rollback = len(files) == 2
        state["phase"] = "rollback" if rollback else "new"
        state["polls"] = 0
        if (rollback and scenario == "rollback-failure") or (not rollback and scenario == "up-failure"):
            code = 1
        if not rollback and scenario == "up-timeout":
            code = 124
    elif action == "down":
        state["phase"] = "removed"
elif command == "inspect":
    container = args[-1]
    service = container.split(":", 1)[1]
    if args[1] == "{{.Image}}":
        output = "sha256:" + ("a" if service == "panda-app" else "b") * 64
    else:
        if service == "panda-app":
            state["polls"] += 1
        poll = state["polls"]
        status, health, restarts = "running", "healthy", 0
        if state["phase"] == "new":
            if scenario in ("unhealthy", "rollback-failure", "legacy-rollback", "first-deploy-failure"):
                health = "unhealthy"
            elif scenario == "never-ready":
                health = "starting"
            elif scenario == "slow-start" and poll <= 5:
                health = "starting"
            elif scenario == "late-failure" and poll >= 15:
                health = "unhealthy"
            elif scenario == "restart-loop" and service == "panda-app":
                status, health, restarts = "restarting", "starting", 3
            elif scenario == "nginx-restart-loop" and service == "nginx":
                status, health, restarts = "restarting", "starting", 3
            elif scenario == "late-restart-loop" and service == "panda-app" and poll >= 15:
                restarts = 3
            elif scenario == "exited" and service == "panda-app":
                status = "exited"
            elif scenario == "recovered-restart" and service == "panda-app" and poll >= 4:
                restarts = 1
        elif scenario == "legacy-rollback":
            health = "none"
        output = f"{status}|{health}|{restarts}|start-{restarts}"
elif command == "exec":
    pass
else:
    raise AssertionError(f"Unexpected Docker command: {command}")
state_file.write_text(json.dumps(state))
if output:
    print(output)
sys.exit(code)
"""


def git(path, *args):
    return subprocess.check_output(
        ["git", "-C", str(path), *args], text=True, stderr=subprocess.DEVNULL
    ).strip()


def executable(path, text):
    path.write_text(text)
    path.chmod(0o700)


@pytest.fixture
def deployment(tmp_path):
    origin = tmp_path / "origin"
    origin.mkdir()
    git(origin, "init", "-b", "main")
    git(origin, "config", "user.name", "Deploy Test")
    git(origin, "config", "user.email", "deploy@example.test")
    git(origin, "config", "commit.gpgsign", "false")
    compose_file = origin / "docker-compose.yaml"
    compose_file.write_text("services:\n  panda-app:\n    image: app:old\n")
    git(origin, "add", ".")
    git(origin, "commit", "-m", "previous")
    old_commit = git(origin, "rev-parse", "HEAD")
    compose_file.write_text("services:\n  panda-app:\n    image: app:new\n")
    git(origin, "commit", "-am", "new")
    new_commit = git(origin, "rev-parse", "HEAD")
    vps = tmp_path / "vps"
    git(tmp_path, "clone", str(origin), str(vps))
    git(vps, "checkout", "--detach", old_commit)
    (vps / ".env.deploy").write_text(OLD_ENV)

    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    executable(bin_dir / "docker", f"#!{sys.executable}\n" + DOCKER_STUB)
    executable(bin_dir / "ssh", "#!/bin/sh\nexec bash -se\n")
    executable(bin_dir / "timeout", '#!/bin/sh\nshift\nexec "$@"\n')
    # Advance Bash's own clock without waiting 60 real seconds per scenario.
    bash_env = tmp_path / "bash-env"
    bash_env.write_text("sleep() { SECONDS=$((SECONDS + $1)); }\n")
    state_file = tmp_path / "docker-state.json"
    state_file.write_text(json.dumps({"phase": "previous", "polls": 0, "events": []}))
    env = {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "BASH_ENV": str(bash_env),
        "DOCKER_STATE": str(state_file),
        "VPS_PATH": str(vps),
        "VPS_HOST": "vps.test",
        "VPS_USER": "deploy",
        "VPS_SSH_KEY": "test-key",
        "VPS_KNOWN_HOSTS": "test-host-key",
        "APP_IMAGE": "app:new",
        "GIT_SHORT_HASH": "new",
        "GIT_TAG": "v2",
        "DEPLOY_COMMIT": new_commit,
        "DEPLOY_BRANCH": "main",
        "GHCR_USER": "test-user",
        "GHCR_TOKEN": "test-token",
    }

    def run(scenario):
        result = subprocess.run(
            ["bash", str(DEPLOY_SCRIPT)],
            check=False,
            env={**env, "DEPLOY_SCENARIO": scenario},
            capture_output=True,
            text=True,
            timeout=30,
        )
        return result, json.loads(state_file.read_text())

    return run, vps, old_commit, new_commit


@pytest.mark.parametrize("scenario", ["healthy", "slow-start", "recovered-restart"])
def test_success_is_observed_for_the_whole_window(deployment, scenario):
    run, vps, _, new_commit = deployment
    result, state = run(scenario)
    assert result.returncode == 0, result.stderr
    assert state["phase"] == "new"
    assert state["polls"] >= 15
    assert git(vps, "rev-parse", "HEAD") == new_commit
    assert (vps / ".env.deploy").read_text() == OLD_ENV.replace("old", "new").replace(
        "v1", "v2"
    )


@pytest.mark.parametrize(
    "scenario",
    [
        "never-ready",
        "unhealthy",
        "late-failure",
        "restart-loop",
        "nginx-restart-loop",
        "late-restart-loop",
        "exited",
        "missing-container",
        "up-failure",
        "up-timeout",
        "legacy-rollback",
    ],
)
def test_failed_release_restores_commit_environment_and_exact_images(
    deployment, scenario
):
    run, vps, old_commit, _ = deployment
    result, state = run(scenario)
    assert result.returncode != 0
    assert "Previous release restored and healthy" in result.stderr
    assert state["phase"] == "rollback"
    assert git(vps, "rev-parse", "HEAD") == old_commit
    assert (vps / ".env.deploy").read_text() == OLD_ENV
    up_events = [e for e in state["events"] if e.get("action") == "up"]
    assert len(up_events) == 2
    restored_config, pinned_images = up_events[-1]["files"]
    assert "# image: app:old" in restored_config
    for service, image in OLD_IMAGES.items():
        assert f"{service}:\n    image: {image}" in pinned_images
    assert "never" in up_events[-1]["args"]
    if scenario == "legacy-rollback":
        assert len([e for e in state["events"] if e["command"] == "exec"]) >= 2


@pytest.mark.parametrize("scenario", ["pull-failure", "login-failure"])
def test_failure_before_up_keeps_the_live_release(deployment, scenario):
    run, vps, old_commit, _ = deployment
    result, state = run(scenario)
    assert result.returncode != 0
    assert state["phase"] == "previous"
    assert not any(e.get("action") in ("up", "down") for e in state["events"])
    assert git(vps, "rev-parse", "HEAD") == old_commit
    assert (vps / ".env.deploy").read_text() == OLD_ENV


def test_first_deploy_can_succeed_without_a_previous_environment(deployment):
    run, vps, _, _ = deployment
    (vps / ".env.deploy").unlink()
    result, state = run("first-deploy")
    assert result.returncode == 0, result.stderr
    assert state["phase"] == "new"


def test_failed_first_deploy_removes_failed_containers(deployment):
    run, vps, old_commit, _ = deployment
    (vps / ".env.deploy").unlink()
    result, state = run("first-deploy-failure")
    assert result.returncode != 0
    assert "no previous release to restore" in result.stderr
    assert state["phase"] == "removed"
    assert not (vps / ".env.deploy").exists()
    assert git(vps, "rev-parse", "HEAD") == old_commit


def test_rollback_failure_is_reported_and_keeps_a_manual_recovery_snapshot(deployment):
    run, vps, old_commit, _ = deployment
    result, _ = run("rollback-failure")
    assert result.returncode != 0
    assert "ROLLBACK FAILED; saved configuration:" in result.stderr
    backup = Path(result.stderr.split("saved configuration: ", 1)[1].splitlines()[0])
    try:
        assert (backup / "previous.yaml").is_file()
        assert (backup / "images.yaml").is_file()
        assert not (backup / "docker").exists()
        assert git(vps, "rev-parse", "HEAD") == old_commit
        assert (vps / ".env.deploy").read_text() == OLD_ENV
    finally:
        shutil.rmtree(backup)
