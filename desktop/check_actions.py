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
    print("ok")


if __name__ == "__main__":
    main()
