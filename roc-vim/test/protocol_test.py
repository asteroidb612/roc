#!/usr/bin/env python3
"""Exercise a compiled Roc plugin by pretending to be Vim.

Vim talks to a job over a JSON channel: it writes `[number, value]` messages on
the job's stdin, and reads channel commands like `["ex", "echo 1"]` on its
stdout. This script plays Vim's side, so the platform can be tested without
starting an editor.

Usage: protocol_test.py [path/to/plugin]   (defaults to examples/hello)
"""

import json
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class FakeVim:
    """Vim's end of a channel: reads commands, answers requests, sends events."""

    def __init__(self, plugin_path, plugin_id=1):
        self.process = subprocess.Popen(
            [plugin_path, "--roc-plugin-id", str(plugin_id)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        self.decoder = json.JSONDecoder()
        self.buffer = ""
        self.next_id = 1
        # What the plugin asked Vim to do, in order.
        self.ex_commands = []
        # Canned answers, by ("expr", text) or ("call", function name).
        self.answers = {}

    def send(self, value, message_id=None):
        """Send `[id, value]`, the way ch_sendexpr() does."""
        if message_id is None:
            message_id = self.next_id
            self.next_id += 1
        payload = json.dumps([message_id, value]) + "\n"
        self.process.stdin.write(payload.encode())
        self.process.stdin.flush()
        return message_id

    def read_message(self, timeout=5.0):
        """Read one JSON message the plugin sent, or None if it went quiet."""
        deadline = time.time() + timeout
        while True:
            stripped = self.buffer.lstrip()
            if stripped:
                try:
                    value, end = self.decoder.raw_decode(stripped)
                    self.buffer = stripped[end:]
                    return value
                except json.JSONDecodeError:
                    pass  # need more bytes
            if time.time() > deadline:
                return None
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                return None
            self.buffer += chunk.decode()

    def pump(self, until=None, timeout=5.0):
        """Handle messages until `until(message)` is true, or time runs out.

        Returns the message that matched, or None.
        """
        deadline = time.time() + timeout
        while time.time() < deadline:
            message = self.read_message(timeout=max(0.05, deadline - time.time()))
            if message is None:
                return None
            if not isinstance(message, list) or not message:
                continue

            head = message[0]
            if head == "ex":
                self.ex_commands.append(message[1])
            elif head == "normal":
                self.ex_commands.append("normal " + message[1])
            elif head == "redraw":
                pass
            elif head == "expr":
                expression = message[1]
                if len(message) > 2:
                    self.send(self.answers.get(("expr", expression), 0), message[2])
            elif head == "call":
                function_name, arguments = message[1], message[2]
                if len(message) > 3:
                    answer = self.answers.get(("call", function_name), 0)
                    if callable(answer):
                        answer = answer(arguments)
                    self.send(answer, message[3])

            if until is not None and until(message):
                return message
        return None

    def stderr_text(self):
        try:
            os.set_blocking(self.process.stderr.fileno(), False)
            return (os.read(self.process.stderr.fileno(), 65536) or b"").decode()
        except BlockingIOError:
            return ""

    def close(self):
        try:
            self.process.stdin.close()
        except Exception:
            pass
        try:
            return self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            return None


FAILURES = []


def check(condition, description):
    if condition:
        print("  ok   %s" % description)
    else:
        print("  FAIL %s" % description)
        FAILURES.append(description)


def main():
    plugin = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "examples", "hello")
    if not os.path.exists(plugin):
        print("no plugin at %s - build it first with `roc build`" % plugin)
        return 2

    print("testing %s" % plugin)
    vim = FakeVim(plugin)
    subscriptions = []
    commands = []
    vim.answers[("call", "roc#subscribe")] = lambda args: subscriptions.extend(args[1]) or 0
    vim.answers[("call", "roc#add_command")] = lambda args: commands.append(args[1]) or 0
    vim.answers[("expr", "expand('%')")] = "notes.txt"

    # 1. On startup the plugin registers what it wants from Vim. The command
    #    is registered last, so seeing it means the rest is in place.
    vim.pump(until=lambda m: m[0] == "call" and m[1] == "roc#add_command", timeout=10)
    check("RocHello" in commands, "plugin defined the :RocHello command")
    check("BufWritePost" in subscriptions, "plugin subscribed to BufWritePost")

    # 2. A user command reaches the plugin, and its answer comes back as an
    #    ex command that mentions the buffer the plugin asked Vim about.
    vim.send({"event": "command:RocHello", "data": {"args": ""}})
    vim.pump(until=lambda m: m[0] == "ex" and "hello from Roc" in m[1], timeout=5)
    greeting = [c for c in vim.ex_commands if "hello from Roc" in c]
    check(bool(greeting), "plugin answered :RocHello")
    check(
        bool(greeting) and "notes.txt" in greeting[0],
        "plugin asked Vim which file is open, and used the answer",
    )

    # 3. State survives between events: the second write is counted as the
    #    second, which only works if the plugin keeps running.
    vim.send({"event": "BufWritePost", "data": {"file": "notes.txt"}})
    vim.pump(until=lambda m: m[0] == "ex" and "1 write" in m[1], timeout=5)
    vim.send({"event": "BufWritePost", "data": {"file": "notes.txt"}})
    vim.pump(until=lambda m: m[0] == "ex" and "2 write" in m[1], timeout=5)
    check(
        any("2 write" in c for c in vim.ex_commands),
        "plugin kept state across events (counted two writes)",
    )

    # 4. Closing the channel ends the plugin, the way quitting Vim does.
    exit_code = vim.close()
    check(exit_code == 0, "plugin exited cleanly when the channel closed")

    stderr = vim.stderr_text()
    if stderr.strip():
        print("  plugin log:")
        for line in stderr.strip().split("\n"):
            print("    | %s" % line)

    if FAILURES:
        print("\n%d check(s) failed" % len(FAILURES))
        return 1
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
