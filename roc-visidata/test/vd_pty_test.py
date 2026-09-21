"""The real `vd` binary, in a real terminal, running a real Roc plugin.

Everything else in this directory tests roc-visidata with VisiData imported but
not running. This one starts `vd` in a pty the way a person does, lets it load
a plugin from the plugin directory at startup, presses the key that plugin
registered, and reads the status line off the screen.

It is the test that found the two bugs the others could not: a plugin outside
the repository could not reach the platform, and the key the example used was
already VisiData's.

    python3 test/vd_pty_test.py
"""

import os
import pty
import select
import shutil
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")


def drain(fd, seconds, into):
    end = time.time() + seconds
    while time.time() < end:
        readable, _, _ = select.select([fd], [], [], 0.2)
        if readable:
            try:
                into.append(os.read(fd, 65536))
            except OSError:
                break


def check(condition, what):
    if not condition:
        raise AssertionError(what)
    print(f"  ok: {what}")


def main():
    work = tempfile.mkdtemp(prefix="roc-visidata-pty-")
    try:
        plugins = os.path.join(work, "roc")
        os.makedirs(plugins)
        shutil.copy(os.path.join(ROOT, "examples", "hello.roc"), plugins)

        data = os.path.join(work, "data.tsv")
        with open(data, "w") as f:
            f.write("name\tamount\nalpha\t1\nbeta\t2\n")

        rc = os.path.join(work, "rc.py")
        with open(rc, "w") as f:
            f.write(
                "import sys\n"
                f"sys.path.insert(0, {os.path.join(ROOT, 'python')!r})\n"
                "import visidata_roc\n"
                "from visidata import vd\n"
                f"vd.options.roc_plugin_dir = {plugins!r}\n"
                # The compiled tier has its own test; keep this one about
                # whether a plugin loads and runs at all.
                "vd.options.roc_compile = False\n")

        pid, fd = pty.fork()
        if pid == 0:
            os.environ.update(TERM="xterm-256color", LINES="24", COLUMNS="100")
            os.execvp("python3", ["python3", "-m", "visidata", "-p", "/dev/null",
                                  "--config", rc, data])

        chunks = []
        drain(fd, 10, chunks)          # start up and compile the plugin
        os.write(fd, b"zR")            # the key hello.roc registered
        drain(fd, 8, chunks)
        os.write(fd, b"gq")            # quit
        drain(fd, 2, chunks)
        try:
            os.close(fd)
        except OSError:
            pass

        screen = b"".join(chunks).decode("utf-8", "replace")
        check("data.tsv" in screen, "vd started and opened the file")
        check("hello from Roc" in screen,
              "the plugin loaded at startup and its key ran it")
        check("2 rows" in screen,
              "the plugin read the real sheet through eval!")
        print("\nvd_pty_test: all checks passed")
        return 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
