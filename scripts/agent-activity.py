#!/usr/bin/env python3
"""Publish Claude Code and Codex lifecycle status to the owning Ghostty X pane."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time

# What each lifecycle event does to the pane's phase. None leaves the phase alone
# (the event only adds detail); "end" removes the session.
COMMON_EVENTS = {
    "SessionStart": "ready",
    "UserPromptSubmit": "running",
    "PreToolUse": "running",
    "PermissionRequest": "approval",
    "PostToolUse": "running",
    "Stop": "complete",
    "SessionEnd": "end",
}
EVENTS = {
    "claude": {
        **COMMON_EVENTS,
        "PostToolUseFailure": "running",
        "StopFailure": "error",
        "PreCompact": "compacting",
        "PostCompact": None,
        "SubagentStart": None,
        "SubagentStop": None,
        "TaskCreated": None,
        "TaskCompleted": None,
        "Notification": None,
    },
    "codex": {**COMMON_EVENTS, "PreModelRequest": "running", "Interrupt": "ready"},
}
# Events a turn is made of: they carry the tool being used.
TOOL_EVENTS = {"PreToolUse", "PermissionRequest"}
FILE_TOOLS = {"Read", "Edit", "Write", "MultiEdit", "NotebookEdit"}
EDIT_TOOLS = FILE_TOOLS - {"Read"}
MAX_EDITED = 200
MAX_AGENTS = 24
MAX_TASKS = 48


def atomic_json(path, value):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as output:
        temp = Path(output.name)
        try:
            json.dump(value, output, indent=2)
            output.write("\n")
            output.close()
            temp.replace(path)
        finally:
            temp.unlink(missing_ok=True)


def clip(text, limit=48):
    text = "".join(ch for ch in str(text) if ch.isprintable())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def describe_tool(event):
    """The tool's name and a short, safe word about what it is working on.

    Never a prompt, a full path, a full command or anything from a transcript: a file's
    own name, a command's first word (and its subcommand), a host name, an agent type.
    With GHOSTTY_AGENT_ACTIVITY_DETAILS=0 nothing but the phase is published.
    """
    if os.environ.get("GHOSTTY_AGENT_ACTIVITY_DETAILS") == "0":
        return None, None
    name = event.get("tool_name")
    if not isinstance(name, str) or not name:
        return None, None
    params = event.get("tool_input")
    params = params if isinstance(params, dict) else {}
    target = None
    if name in FILE_TOOLS:
        path = params.get("file_path") or params.get("notebook_path")
        if isinstance(path, str) and path:
            target = os.path.basename(path.rstrip("/"))
    elif name in ("Bash", "PowerShell", "shell", "local_shell"):
        command = params.get("command")
        if isinstance(command, list):
            command = " ".join(str(part) for part in command)
        if isinstance(command, str):
            words = command.strip().split()
            if words:
                target = os.path.basename(words[0])
                # A subcommand ("git push", "npm test") says what is going on. An option,
                # a path, an assignment or a quoted string is left out.
                if len(words) > 1 and words[1].isalnum() and len(words[1]) <= 16:
                    target += " " + words[1]
    elif name in ("Agent", "Task"):
        kind = params.get("subagent_type")
        target = kind if isinstance(kind, str) else None
    elif name == "WebFetch":
        url = params.get("url")
        if isinstance(url, str) and "//" in url:
            target = url.split("//", 1)[1].split("/", 1)[0].split("@")[-1]
    if name.startswith("mcp__"):
        parts = name.split("__")
        name = parts[-1] if len(parts) > 2 else name
    return clip(name, 24), clip(target) if target else None


def publish(provider):
    directory = os.environ.get("GHOSTTY_AGENT_ACTIVITY_DIR")
    if not directory:
        return

    event = json.load(sys.stdin)
    name = event.get("hook_event_name")
    session = event.get("session_id")
    if name not in EVENTS[provider] or not isinstance(session, str) or not session:
        return
    # Store a stable token for ordering events, never the session id itself.
    session_key = hashlib.sha256(session.encode()).hexdigest()
    folder = Path(directory)
    state_file = folder / (provider + ".json")

    with (folder / ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            previous = json.loads(state_file.read_text())
        except (FileNotFoundError, ValueError):
            previous = {}
        if previous.get("session") not in (None, session_key) and name != "SessionStart":
            return
        phase = EVENTS[provider][name]
        if phase == "end":
            state_file.unlink(missing_ok=True)
            return
        new = apply(dict(previous), name, phase, event)
        new["session"] = session_key
        if previous != new:
            atomic_json(state_file, new)


def apply(state, name, phase, event):
    """The pane's state after one lifecycle event."""
    if name == "SessionStart":
        state = {"usage": state.get("usage")} if state.get("usage") else {}
        model = event.get("model")
        if isinstance(model, str) and model:
            state["model"] = clip(model.removeprefix("claude-"), 24)
    mode = event.get("permission_mode")
    if isinstance(mode, str) and mode:
        state["mode"] = clip(mode, 24)

    # Inside a subagent the event is about that subagent, not the session's own turn.
    agent_id = event.get("agent_id")
    agents = [dict(agent) for agent in state.get("agents", []) if isinstance(agent, dict)]
    if name == "SubagentStart" and isinstance(agent_id, str):
        if not any(agent.get("id") == agent_id[:16] for agent in agents):
            kind = event.get("agent_type")
            agents.append({"id": agent_id[:16], "type": clip(kind, 24) if isinstance(kind, str) else "agent"})
        state["agents"] = agents[-MAX_AGENTS:]
        return state
    if name == "SubagentStop" and isinstance(agent_id, str):
        for agent in agents:
            if agent.get("id") == agent_id[:16]:
                agent["done"] = True
                agent.pop("tool", None)
        state["agents"] = agents
        return state
    if isinstance(agent_id, str) and name in ("PreToolUse", "PostToolUse", "PostToolUseFailure"):
        tool, target = describe_tool(event)
        for agent in agents:
            if agent.get("id") == agent_id[:16] and name == "PreToolUse" and tool:
                agent["tool"] = tool if not target else f"{tool} {target}"
        state["agents"] = agents
        return state

    if name in ("TaskCreated", "TaskCompleted"):
        task = event.get("task_id")
        if isinstance(task, str) and task:
            tasks = dict(state.get("tasks") or {})
            tasks[task[:24]] = name == "TaskCompleted" or bool(tasks.get(task[:24]))
            state["tasks"] = dict(list(tasks.items())[-MAX_TASKS:])
        return state
    if name == "Notification":
        # Waiting for an answer is the one notification that changes what the pane shows.
        if event.get("notification_type") in ("permission_prompt", "agent_needs_input", "elicitation_dialog"):
            state["phase"] = "approval"
        return state
    if name == "PostCompact":
        # Compaction in the middle of a turn goes back to work; one asked for by hand is done.
        state["phase"] = "running" if event.get("trigger") == "auto" and state.get("started") else "ready"
        return state

    if phase:
        state["phase"] = phase
    if name == "PostToolUse" and event.get("tool_name") in EDIT_TOOLS:
        # Which files the session has changed, to count them. Only a short hash of each
        # path is kept: enough to tell two files apart, and nothing that names one.
        params = event.get("tool_input") if isinstance(event.get("tool_input"), dict) else {}
        path = params.get("file_path") or params.get("notebook_path")
        if isinstance(path, str) and path:
            mark = hashlib.sha256(path.encode()).hexdigest()[:10]
            edited = [item for item in state.get("edited", []) if isinstance(item, str)]
            if mark not in edited:
                state["edited"] = (edited + [mark])[-MAX_EDITED:]
    if name == "UserPromptSubmit":
        state["started"] = int(time.time())
        for key in ("agents", "tasks", "tool", "target"):
            state.pop(key, None)
    if name in TOOL_EVENTS:
        tool, target = describe_tool(event)
        if tool:
            state["tool"] = tool
            state.pop("target", None)
            if target:
                state["target"] = target
    if name in ("Stop", "StopFailure", "Interrupt"):
        for key in ("tool", "target", "started"):
            state.pop(key, None)
    return state


def number(value, kind=float):
    return kind(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def permission_mode(payload):
    """The permission mode, wherever a payload carries it. Claude Code runs the status
    line again when the mode changes, which a hook only hears about at the next event."""
    for value in (payload.get("permission_mode"), payload.get("permissionMode")):
        if isinstance(value, str) and value:
            return clip(value, 24)
    for key in ("permission", "permissions"):
        holder = payload.get(key)
        if isinstance(holder, dict) and isinstance(holder.get("mode"), str) and holder["mode"]:
            return clip(holder["mode"], 24)
    return None


def record_usage(provider, payload):
    """Keeps the numbers Claude Code hands its status line: context, tokens, cost, lines."""
    directory = os.environ.get("GHOSTTY_AGENT_ACTIVITY_DIR")
    session = payload.get("session_id")
    if not directory or not isinstance(session, str) or not session:
        return
    session_key = hashlib.sha256(session.encode()).hexdigest()
    window = payload.get("context_window") if isinstance(payload.get("context_window"), dict) else {}
    current = window.get("current_usage") if isinstance(window.get("current_usage"), dict) else {}
    cost = payload.get("cost") if isinstance(payload.get("cost"), dict) else {}
    model = payload.get("model") if isinstance(payload.get("model"), dict) else {}
    tokens = [number(current.get(key), int) for key in
              ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")]
    usage = {
        "context": number(window.get("used_percentage")),
        "tokens": sum(count for count in tokens if count) or None,
        "cost": number(cost.get("total_cost_usd")),
        "added": number(cost.get("total_lines_added"), int),
        "removed": number(cost.get("total_lines_removed"), int),
    }
    usage = {key: value for key, value in usage.items() if value is not None}
    if "cost" in usage:
        usage["cost"] = round(usage["cost"], 2)
    if "context" in usage:
        usage["context"] = round(usage["context"])

    folder = Path(directory)
    state_file = folder / (provider + ".json")
    with (folder / ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            previous = json.loads(state_file.read_text())
        except (FileNotFoundError, ValueError):
            return
        if previous.get("session") != session_key:
            return
        new = dict(previous)
        new["usage"] = usage
        name = model.get("display_name")
        if isinstance(name, str) and name:
            new["model"] = clip(name, 24)
        mode = permission_mode(payload)
        if mode:
            new["mode"] = mode
        if previous != new:
            atomic_json(state_file, new)


def configuration_path(provider):
    if provider == "claude":
        config = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude") / "settings.json"
    else:
        config = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex") / "hooks.json"
    return config.resolve() if config.is_symlink() else config


def is_own_command(command, action, provider):
    try:
        args = shlex.split(command or "")
    except ValueError:
        return False
    if len(args) != 4 or args[2:] != [action, provider]:
        return False
    script = Path(args[1])
    return (
        script.is_absolute()
        and script.name == "agent-activity.py"
        and (script.parent.name == "scripts" or script.parent.parts[-2:] == ("Contents", "Resources"))
    )


def is_activity_group(group, provider):
    handlers = group.get("hooks", [])
    if set(group) != {"hooks"} or len(handlers) != 1:
        return False
    if set(handlers[0]) != {"type", "command", "timeout"} or handlers[0].get("type") != "command":
        return False
    return is_own_command(handlers[0].get("command"), "publish", provider)


def own_command(action, provider):
    return shlex.join([sys.executable, str(Path(__file__).resolve()), action, provider])


def configure(provider, action):
    config = configuration_path(provider)

    try:
        settings = json.loads(config.read_text())
    except FileNotFoundError:
        if action == "status":
            print("disabled")
            return
        if action == "disable":
            return
        settings = {}

    command = own_command("publish", provider)
    hooks = settings.setdefault("hooks", {})
    if action == "status":
        enabled = all(any(is_activity_group(group, provider) for group in hooks.get(event, []))
                      for event in EVENTS[provider])
        print("enabled" if enabled else "disabled")
        return
    enabled = action == "enable"
    for event in EVENTS[provider]:
        groups = hooks.get(event, [])
        bridge = {"hooks": [{"type": "command", "command": command, "timeout": 2}]}
        remaining = [group for group in groups if not is_activity_group(group, provider)]
        if enabled:
            remaining.append(bridge)
        if remaining:
            hooks[event] = remaining
        elif event in hooks:
            del hooks[event]
    config.parent.mkdir(parents=True, exist_ok=True)
    atomic_json(config, settings)
    print(f"{'Enabled' if enabled else 'Disabled'} Ghostty X status in {config}")


# --- Status line: Claude Code gives context and cost only to its status line command.
# Ghostty X puts itself in front of whatever command was there, records the numbers, and
# then runs that command so the status line looks exactly as it did.

def original_statusline_path(provider):
    return configuration_path(provider).parent / "ghostty-x-statusline.json"


def is_own_statusline(value, provider):
    return (isinstance(value, dict) and value.get("type") == "command"
            and is_own_command(value.get("command"), "statusline", provider))


def configure_usage(provider, action):
    if provider != "claude":
        if action == "usage-status":
            print("unavailable")
            return
        raise ValueError("only Claude Code has a status line to read usage from")
    config = configuration_path(provider)
    try:
        settings = json.loads(config.read_text())
    except FileNotFoundError:
        settings = {}
    current = settings.get("statusLine")
    wrapped = is_own_statusline(current, provider)
    if action == "usage-status":
        print("enabled" if wrapped else "disabled")
        return
    keep = original_statusline_path(provider)
    if action == "usage-enable":
        if not wrapped:
            # Remember what was there (or that nothing was), to run it and to put it back.
            atomic_json(keep, {"statusLine": current})
        own = {"type": "command", "command": own_command("statusline", provider)}
        if isinstance(current, dict) and not wrapped:
            own.update({key: value for key, value in current.items() if key not in ("type", "command")})
        settings["statusLine"] = own
    else:
        if not wrapped:
            return
        try:
            original = json.loads(keep.read_text()).get("statusLine")
        except (FileNotFoundError, ValueError):
            original = None
        if original is None:
            settings.pop("statusLine", None)
        else:
            settings["statusLine"] = original
        keep.unlink(missing_ok=True)
    config.parent.mkdir(parents=True, exist_ok=True)
    atomic_json(config, settings)
    print(f"{'Enabled' if action == 'usage-enable' else 'Disabled'} Ghostty X usage in {config}")


def statusline(provider):
    raw = sys.stdin.read()
    try:
        record_usage(provider, json.loads(raw))
    except (OSError, ValueError, TypeError, AttributeError):
        pass
    try:
        original = json.loads(original_statusline_path(provider).read_text()).get("statusLine")
    except (OSError, ValueError, AttributeError):
        original = None
    if isinstance(original, dict) and original.get("type") == "command" and original.get("command"):
        # The user's own status line command, run the way Claude Code would run it.
        result = subprocess.run(original["command"], shell=True, input=raw, text=True, check=False)
        sys.exit(result.returncode)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=(
        "enable", "disable", "status", "publish",
        "usage-enable", "usage-disable", "usage-status", "statusline"))
    parser.add_argument("provider", choices=EVENTS)
    args = parser.parse_args()
    if args.action == "publish":
        try:
            publish(args.provider)
        except (OSError, ValueError, AttributeError, TypeError):
            # A missing pane or unavailable status channel must never interrupt the CLI.
            pass
    elif args.action == "statusline":
        statusline(args.provider)
    else:
        try:
            if args.action.startswith("usage-"):
                configure_usage(args.provider, args.action)
            else:
                configure(args.provider, args.action)
        except (OSError, ValueError, TypeError, AttributeError) as error:
            parser.exit(1, f"Could not update hooks: {error}\n")


if __name__ == "__main__":
    main()
