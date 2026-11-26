"""Resolve review pins and launch the configured engine from either host."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


CLAUDE_EFFORTS = ("low", "medium", "high", "xhigh", "max")
CODEX_EFFORTS = ("minimal", "low", "medium", "high", "xhigh")
DEFAULT_CLAUDE_MODEL = "claude-sonnet-5-5"
DEFAULT_CODEX_MODEL = "gpt-6-luna"


def load_config(root, host):
    candidates = (root / ".cross-review-ship.json", Path.home() / ".cross-review-ship.json")
    path = next((candidate for candidate in candidates if candidate.exists()), None)
    claude = {"model": DEFAULT_CLAUDE_MODEL, "effort": "medium"}
    ce = {"model": DEFAULT_CODEX_MODEL, "effort": "medium"} if host == "codex" else claude
    defaults = {"ce": ce.copy(), "ocr": claude.copy(), "ship": claude.copy()}
    if path is None:
        return {"source": "defaults", **defaults}

    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
        if not isinstance(data, dict) or data.keys() - {"ce", "ocr", "ship"}:
            raise ValueError("expected an object with ce, ocr, or ship keys")
        ce_config = data.get("ce", {})
        if not isinstance(ce_config, dict) or ce_config.keys() - {"claude", "codex"}:
            raise ValueError("ce: expected claude or codex keys")
        pins = {
            "ce": ce_config.get(host, defaults["ce"]),
            "ocr": data.get("ocr", defaults["ocr"]),
            "ship": data.get("ship", defaults["ship"]),
        }
        for engine, pin in pins.items():
            if not isinstance(pin, dict) or set(pin) != {"model", "effort"}:
                raise ValueError(f"{engine}: expected model and effort")
            model, effort = pin["model"], pin["effort"]
            if not isinstance(model, str) or not re.fullmatch(r"[A-Za-z0-9][\w./:@+\[\]-]*", model, re.ASCII):
                raise ValueError(f"{engine}: invalid model identifier")
            efforts = CODEX_EFFORTS if engine == "ce" and host == "codex" else CLAUDE_EFFORTS
            if effort not in efforts:
                raise ValueError(f"{engine}: effort must be one of {', '.join(efforts)}")
    except (TypeError, ValueError) as error:
        raise ValueError(f"{path}: {error}") from error

    return {"source": str(path), **pins}


def git(*args, env=None):
    return subprocess.check_output(["git", *args], env=env)


def snapshot(base_ref):
    if base_ref is None:
        try:
            base_ref = git("symbolic-ref", "--quiet", "refs/remotes/origin/HEAD").decode().strip()
        except subprocess.CalledProcessError:
            base_ref = "origin/HEAD"
    base_sha = git("rev-parse", "--verify", "--end-of-options", f"{base_ref}^{{commit}}").decode().strip()
    try:
        base_sha = git("merge-base", "HEAD", base_sha).decode().strip()
    except subprocess.CalledProcessError:
        pass
    if git("ls-files", "-u"):
        raise ValueError("resolve unmerged paths first")
    with tempfile.TemporaryDirectory(prefix="cross-review-ship-") as directory:
        env = {**os.environ, "GIT_INDEX_FILE": str(Path(directory) / "index")}
        git("read-tree", "HEAD", env=env)
        git("add", "-A", env=env)
        tree = git("write-tree", env=env).decode().strip()
        wt = git("commit-tree", tree, "-p", "HEAD", "-m", "cross-review-ship snapshot").decode().strip()
    untracked = git("ls-files", "--others", "--exclude-standard", "-z")
    return {
        "base": base_sha,
        "snapshot": wt,
        "untracked": [os.fsdecode(path) for path in untracked.split(b"\0") if path],
    }


def launch(args, pin):
    model, effort = pin["model"], pin["effort"]
    env = os.environ.copy()
    if args.action == "ocr":
        env["CLAUDE_CODE_EFFORT_LEVEL"] = effort
        command = [
            "ocr", "review", "--from", args.base, "--to", args.snapshot,
            "--provider", "anthropic-oauth", "--model", model, "--format", "json",
            "--audience", "agent", "--concurrency", "2", "--output", args.output,
        ]
    elif args.action == "ce" and args.host == "codex":
        prompt = (
            f"Run the installed ce-code-review skill with mode:agent depth:full base:{args.base}. "
            f"For every CE subagent pass model={model}, reasoning_effort={effort}, "
            "and fork_turns=none at dispatch. Pass the review scope explicitly. "
            "If pinning is rejected, report the engine failure. Return only the skill's raw JSON. "
            "Run locally without a CE cross-model peer. Do not edit the reviewed tree."
        )
        command = [
            "codex", "exec", "--ephemeral", "--sandbox", "workspace-write", "--model", model,
            "-c", f"model_reasoning_effort={json.dumps(effort)}", prompt,
        ]
    else:
        env.pop("CLAUDECODE", None)
        env["CLAUDE_CODE_SUBAGENT_MODEL"] = model
        env["CLAUDE_CODE_SUBAGENT_MODEL_FORCE"] = "1"
        env["CLAUDE_CODE_EFFORT_LEVEL"] = effort
        prompt = f"/code-review {effort} {args.base}...{args.snapshot}"
        if args.action == "ce":
            prompt = (
                "Use the installed ce-code-review skill with arguments "
                f"mode:agent depth:full base:{args.base}. "
                "Run locally without a CE cross-model peer. Do not edit the reviewed tree. "
                "Return only the skill's raw JSON."
            )
        command = [
            "claude", "-p", "--no-session-persistence", "--model", model, "--effort", effort,
            "--permission-mode", "acceptEdits" if args.action == "ce" else "plan", "--", prompt,
        ]
    return subprocess.run(command, env=env, check=False).returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("resolve", "snapshot", "ce", "ocr", "ship"))
    parser.add_argument("--host", required=True, choices=("claude", "codex"))
    parser.add_argument("--base")
    parser.add_argument("--snapshot")
    parser.add_argument("--output")
    parser.add_argument("--ocr-model")
    parser.add_argument("--ship-level", choices=CLAUDE_EFFORTS)
    args = parser.parse_args()

    try:
        root = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"], text=True, encoding="utf-8"
        ).strip()
        os.chdir(root)
        if args.action == "snapshot":
            print(json.dumps(snapshot(args.base)))
            return 0
        config = load_config(Path(root), args.host)
        if args.action == "resolve":
            print(json.dumps(config))
            return 0
        for name in ("base", "snapshot") if args.action in ("ocr", "ship") else ("base",):
            if not re.fullmatch(r"[0-9a-f]{40}", getattr(args, name) or ""):
                raise ValueError(f"--{name} requires a full commit SHA")
        if args.action == "ocr" and not args.output:
            raise ValueError("ocr requires --output")
        if args.ocr_model:
            if not re.fullmatch(r"[A-Za-z0-9][\w./:@+\[\]-]*", args.ocr_model, re.ASCII):
                raise ValueError("invalid --ocr-model identifier")
            config["ocr"]["model"] = args.ocr_model
        if args.ship_level:
            config["ship"]["effort"] = args.ship_level
        return launch(args, config[args.action])
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"cross-review-ship: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
