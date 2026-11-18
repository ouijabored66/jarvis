#!/usr/bin/env python3
"""Self-check for pending computer tasks. No network and no provider key."""

from __future__ import annotations

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import actions


def main() -> None:
    prose = actions.proposal_from_text("Disk space looks fine today.")
    assert prose is None, prose

    parsed = actions.proposal_from_text('{"title":"Check disk space","command":"df -h"}')
    assert parsed == {"title": "Check disk space", "command": "df -h"}, parsed

    fenced = actions.proposal_from_text('Sure.\n```json\n{"title":"Open notes","command":"ls"}\n```')
    assert fenced and fenced["command"] == "ls", fenced

    tool = {
        "choices": [{
            "message": {
                "content": "",
                "tool_calls": [{
                    "function": {
                        "name": "propose_command",
                        "arguments": '{"title":"List files","command":"ls"}',
                    }
                }],
            }
        }]
    }
    from_tool = actions.proposal_from_response("groq", tool, "")
    assert from_tool == {"title": "List files", "command": "ls"}, from_tool

    line = actions.waiting_line("Check disk space")
    assert "approval" in line and "iPhone" in line and "Watch" in line, line
    banned = "ask" + " and " + "watch"
    assert banned not in line.lower()

    marker = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".action-check")
    try:
        os.remove(marker)
    except OSError:
        pass
    command = f'{sys.executable} -c "open({marker!r}, \'w\').write(\'ok\')"'
    queue = actions.Queue()
    card = queue.enqueue("Write a marker", command)
    assert not os.path.exists(marker), "queued command must not run"
    assert card["id"] and card["status"] == "pending"
    assert command in card["task"]
    listed = queue.pending()
    assert [row["id"] for row in listed] == [card["id"]]

    cancelled = queue.cancel(card["id"])
    assert cancelled and cancelled["status"] == "cancelled"
    assert queue.pending() == []
    assert not os.path.exists(marker)

    live = queue.enqueue("Write a marker", command)
    done = queue.approve(live["id"])
    assert done and done["status"] == "done", done
    assert done.get("spoken", "").startswith("Done.")
    with open(marker, encoding="utf-8") as handle:
        assert handle.read() == "ok"
    again = queue.approve(live["id"])
    assert again and again["status"] == "done"

    old = queue.enqueue("Stale", "echo stale")
    with queue._lock:
        queue._items[old["id"]]["created"] = time.time() - (actions.TTL + 5)
    assert all(row["id"] != old["id"] for row in queue.pending())
    assert queue.approve(old["id"]) is None

    os.remove(marker)

    df = (
        "Filesystem Size Used Avail Use% Mounted on\n"
        "/dev/root 500G 210G 280G 42% /\n"
        "/dev/home 200G 20G 180G 10% /home\n"
        "df: /mnt/broken: missing\n"
    )
    local = actions.summarize("partial", df, "Check disk space", "df -h")
    assert "42%" in local and "280 GB" in local and "Home" in local, local
    assert "Filesystem Size" not in local, local
    assert "didn't work" not in local.lower(), local

    def _fake_provider(*_args):
        return "Your main drive is 42% full with 280 GB free. Home is 10% full with 180 GB free."

    actions.SPEAK = _fake_provider
    heard = actions.summarize("partial", df, "Check disk space", "df -h", 4)
    assert heard.startswith("Your main drive is 42% full"), heard
    assert "180 GB" in heard

    def _broken_provider(*_args):
        raise RuntimeError("no provider")

    actions.SPEAK = _broken_provider
    fallback = actions.summarize("done", "alpha\nbeta 2\n", "List", "echo")
    assert fallback.startswith("Done.") and "alpha" in fallback and "beta 2" in fallback, fallback
    actions.SPEAK = None

    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".df-check.py")
    with open(script, "w", encoding="utf-8") as handle:
        handle.write(
            "import sys\n"
            "sys.stdout.write(" + repr(df) + ")\n"
            "sys.stderr.write('df: /mnt/broken: missing\\n')\n"
            "raise SystemExit(1)\n"
        )
    try:
        partial = queue.enqueue("Check disk space", f"{sys.executable} {script}")
        reported = queue.approve(partial["id"])
    finally:
        try:
            os.remove(script)
        except OSError:
            pass
    assert reported and reported["status"] == "partial", reported
    assert "280G" in reported["result"] and "Filesystem Size" in reported["result"], reported
    assert "42%" in reported["spoken"] and "didn't work" not in reported["spoken"].lower(), reported

    fail_cmd = f"{sys.executable} -c \"import sys; sys.stderr.write('nope\\n'); sys.exit(2)\""
    missed = queue.enqueue("Fail", fail_cmd)
    failed = queue.approve(missed["id"])
    assert failed and failed["status"] == "failed", failed
    assert "didn't work" in failed["spoken"].lower(), failed

    assert actions.host_label("linux") == "linux"
    assert actions.host_label("win32") == "windows"
    assert actions.host_label("darwin") == ""
    win_argv, win_shell = actions.command_invocation("Get-PSDrive -PSProvider FileSystem", "win32")
    assert win_shell is False
    assert win_argv[0] == "powershell.exe"
    assert win_argv[-1].startswith("Get-PSDrive")
    posix_argv, posix_shell = actions.command_invocation("df -h", "linux")
    assert posix_shell is True and posix_argv == "df -h"
    hint = actions.shell_hint("win32").lower()
    assert "powershell" in hint and "cmd" in hint
    assert ("ask" + " and " + "watch") not in hint
    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "server.py"), encoding="utf-8").read()
    assert 'send_header("X-Server-OS", host_os())' in src
    assert "actions.host_label" in src

    print("ok")


if __name__ == "__main__":
    main()
