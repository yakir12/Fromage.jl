#!/usr/bin/env python3
"""Validate agent integration without model turns, MCP calls or publishing.

Python 3.11+ and PyYAML are tooling-only dependencies. Native discovery uses
temporary Codex state and ephemeral project trust; it never saves user trust.
"""

import ast
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import tomllib

try:
    import yaml
except ModuleNotFoundError:
    raise SystemExit("Integration validation requires PyYAML in the Python tooling environment")


ROOT = Path(__file__).resolve().parents[2]


def run(args, **kwargs):
    result = subprocess.run(
        args, cwd=ROOT, capture_output=True, text=True, timeout=60, **kwargs
    )
    if result.returncode:
        # Config/runtime diagnostics may contain local values. Do not dump them.
        raise RuntimeError(f"{args[0]} failed (exit {result.returncode}); inspect locally")
    assert "Ignoring malformed agent role definition" not in result.stderr, "Codex rejected an agent role"
    return result.stdout


def metadata(path):
    parts = path.read_text().split("---", 2)
    assert len(parts) == 3 and not parts[0].strip(), f"Missing frontmatter: {path.name}"
    data = yaml.safe_load(parts[1])
    assert data.get("name") and data.get("description"), path.name
    return data


def structural():
    for path in (ROOT / ".claude").rglob("*.json"):
        json.loads(path.read_text())
    for path in (ROOT / ".codex").rglob("*.json"):
        if path.name != "auth.json":
            json.loads(path.read_text())
    for path in (ROOT / ".github").rglob("*.yml"):
        yaml.safe_load(path.read_text())
    for path in (ROOT / ".codex").rglob("*.toml"):
        if not path.name.endswith(".local.toml"):
            tomllib.loads(path.read_text())
    for path in (ROOT / ".claude/hooks").glob("*.sh"):
        run(["bash", "-n", str(path)])
        assert os.access(path, os.X_OK), path.name
    run(["bash", "-n", ".github/scripts/cache-cleanup.sh"])
    ast.parse(Path(__file__).read_text())

    claude = json.loads((ROOT / ".claude/settings.json").read_text())
    config = tomllib.loads((ROOT / ".codex/config.toml").read_text())
    readonly = {
        item.removeprefix("mcp__kaimon__")
        for item in claude["permissions"]["allow"]
        if item.startswith("mcp__kaimon__")
    }
    server = config["mcp_servers"]["kaimon"]
    assert server["default_tools_approval_mode"] == "prompt"
    assert {k for k, v in server["tools"].items()
            if v["approval_mode"] in {"auto", "approve"}} == readonly
    assert config["sandbox_mode"] == "workspace-write"
    assert config["sandbox_workspace_write"]["network_access"] is False
    assert config["approval_policy"] == "on-request"
    assert config["approvals_reviewer"] == "auto_review"

    agents = {}
    for path in (ROOT / ".codex/agents").glob("*.toml"):
        role = tomllib.loads(path.read_text())
        original = ROOT / ".claude/agents" / (path.stem + ".md")
        metadata(original)
        assert role["name"] == path.stem and role["description"]
        assert config["agents"][path.stem]["description"] == role["description"]
        assert config["agents"][path.stem]["config_file"] == f"agents/{path.stem}.toml"
        assert (ROOT / ".codex" / config["agents"][path.stem]["config_file"]).resolve() == path.resolve()
        assert str(original.relative_to(ROOT)) in role["developer_instructions"]
        assert role["sandbox_mode"] == "read-only"
        assert role["mcp_servers"]["kaimon"]["url"] == server["url"], path.name
        assert set(role["mcp_servers"]["kaimon"]["enabled_tools"]) == readonly
        agents[role["name"]] = path
    assert set(agents) == {p.stem for p in (ROOT / ".claude/agents").glob("*.md")}

    skills = {}
    for original in (ROOT / ".claude/skills").glob("*/SKILL.md"):
        source = metadata(original)
        name = "fromage-implement" if source["name"] == "implement" else source["name"]
        target = ROOT / ".agents/skills" / name / "SKILL.md"
        assert metadata(target)["name"] == name
        assert str(original.relative_to(ROOT)) in target.read_text()
        if source.get("disable-model-invocation"):
            policy = yaml.safe_load((target.parent / "agents/openai.yaml").read_text())
            assert policy["policy"]["allow_implicit_invocation"] is False
        skills[name] = target
    assert {p.parent.name for p in (ROOT / ".agents/skills").glob("*/SKILL.md")} == set(skills)
    print(f"PASS structured files, Claude references, {len(agents)} agents, {len(skills)} skills, approval parity")
    return agents, skills


def hook_and_rule_checks():
    hooks = json.loads((ROOT / ".codex/hooks.json").read_text())["hooks"]
    for event, filename in [("SessionStart", "kaimon-session-start.sh"),
                            ("PreToolUse", "prefer-kaimon-search.sh")]:
        handler = hooks[event][0]["hooks"][0]
        assert handler["command"] == f'bash "$(git rev-parse --show-toplevel)/.claude/hooks/{filename}"'
        assert handler["timeout"] == 5
    # Export a fake curl only inside this child shell: exercise both startup
    # branches without contacting any service or altering the original hook.
    for status in ("200", "000"):
        output = run(["bash", "-c", f"curl() {{ printf '%s' '{status}'; }}; "
                      "export -f curl; bash .claude/hooks/kaimon-session-start.sh"])
        context = json.loads(output)["hookSpecificOutput"]
        assert context["hookEventName"] == "SessionStart"
        assert ("NOT REACHABLE" in context["additionalContext"]) == (status == "000")
    # These scripts were inspected: this hook only parses input and prints JSON.
    for command, denied in [
        ("rg retry src", True), ("git grep retry", True),
        ("sed -n '1,10p' src/shareio.jl", False),
        ("rg title README.md # kaimon-ok", False),
    ]:
        output = run(["bash", ".claude/hooks/prefer-kaimon-search.sh"], input=json.dumps({
            "hook_event_name": "PreToolUse", "tool_name": "Bash",
            "tool_input": {"command": command},
        }))
        decision = json.loads(output)["hookSpecificOutput"]["permissionDecision"] if output else None
        assert (decision == "deny") == denied
    for command in [["git", "push", "origin", "main"], ["gh", "pr", "merge", "1"],
                    ["git", "tag", "v0.0.0"], ["gh", "workflow", "run", "Docs.yml"]]:
        result = json.loads(run(["codex", "execpolicy", "check", "--rules",
                                 ".codex/rules/fromage.rules", "--", *command]))
        assert result["decision"] == "prompt"
    print("PASS hook deny/allow fixtures and native release-rule checks (commands not executed)")


def native_discovery(agents, skills):
    with tempfile.TemporaryDirectory(prefix="fromage-codex-validation-") as state:
        env = os.environ.copy()
        env["CODEX_HOME"] = state
        env["RUST_LOG"] = "warn"
        flags = ["-c", "projects={" + json.dumps(str(ROOT)) + '={trust_level="trusted"}}',
                 "-c", "sqlite_home=" + json.dumps(state),
                 "-c", "log_dir=" + json.dumps(state)]
        # Metadata endpoints do not start threads, run hooks, or initialize MCP.
        diagnostics = tempfile.TemporaryFile(mode="w+t")
        proc = subprocess.Popen(["codex", "app-server", "--stdio", "--strict-config", *flags],
                                cwd=ROOT, env=env, stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=diagnostics, text=True)
        messages = queue.Queue()

        def receive():
            for line in proc.stdout:
                messages.put(json.loads(line))
            messages.put(None)

        threading.Thread(target=receive, daemon=True).start()

        def request(number, method, params):
            proc.stdin.write(json.dumps({"id": number, "method": method, "params": params}) + "\n")
            proc.stdin.flush()
            while True:
                message = messages.get(timeout=30)
                if message is None:
                    raise RuntimeError("Codex metadata server exited; run codex doctor locally")
                if message.get("id") == number:
                    assert "error" not in message, f"RPC failed: {method}"
                    return message["result"]

        try:
            request(1, "initialize", {"clientInfo": {"name": "fromage_validator", "version": "1"},
                                      "capabilities": {"experimentalApi": True}})
            proc.stdin.write('{"method":"initialized"}\n')
            proc.stdin.flush()
            config = request(2, "config/read", {"cwd": str(ROOT), "includeLayers": True})
            assert any(l["name"]["type"] == "project" and not l.get("disabledReason")
                       for l in config["layers"])
            assert config["origins"]["sandbox_mode"]["name"]["type"] == "project"
            assert config["config"]["approvals_reviewer"] == "auto_review"
            assert config["origins"]["approvals_reviewer"]["name"]["type"] == "project"
            assert "kaimon" in config["config"]["mcp_servers"]
            assert set(agents) <= set(config["config"]["agents"])
            discovered = request(3, "skills/list", {"cwds": [str(ROOT)], "forceReload": True})
            entries = discovered["data"][0]
            assert not entries["errors"]
            paths = {Path(s["path"]).resolve() for s in entries["skills"]}
            assert all(p.resolve() in paths for p in skills.values())
            hooks = request(4, "hooks/list", {"cwds": [str(ROOT)]})["data"][0]
            assert not hooks["errors"] and not hooks["warnings"]
            project_hooks = [h for h in hooks["hooks"] if h["source"] == "project"]
            assert {h["eventName"] for h in project_hooks} == {"sessionStart", "preToolUse"}
            assert all(h["enabled"] for h in project_hooks)
            print("PASS native project config, MCP listing, skill discovery and hook registration")
            print("INFO isolated hook trust: " + ", ".join(sorted({h["trustStatus"] for h in project_hooks})))
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            proc.stdin.close()
            proc.stdout.close()
            diagnostics.seek(0)
            startup_diagnostics = diagnostics.read()
            diagnostics.close()

        assert "Ignoring malformed agent role definition" not in startup_diagnostics, \
            "Codex rejected an agent role during app-server startup"

        # Constructs a prompt locally; never sends it to a model. Disable all hooks
        # and the configured MCP server because this command creates a session.
        prompt = run(["codex", *flags, "-c", "features.hooks=false", "-c",
                      "mcp_servers.kaimon.enabled=false", "debug", "prompt-input"], env=env)
        data = json.loads(prompt)
        assert "Ignoring malformed agent role definition" not in prompt, "Codex rejected an agent role"
        for log in Path(state).rglob("*.log"):
            assert "Ignoring malformed agent role definition" not in log.read_text(), "Codex rejected an agent role"
        text = json.dumps(data)
        assert "AGENTS.md instructions for " + str(ROOT) in text
        assert (ROOT / "AGENTS.md").read_text().strip() in "\n".join(
            part.get("text", "") for item in data for part in item.get("content", [])
        )
        print("PASS native AGENTS.md prompt discovery; no model, hooks or MCP executed")
        print(f"PASS {len(agents)} agent declarations/references; no malformed-role startup warnings")
        print("INFO delegated specialist execution not tested")


if __name__ == "__main__":
    os.chdir(ROOT)
    native_discovery(*structural())
    hook_and_rule_checks()
    print("PASS integration validation; live MCP and Julia tests are separate checks")
