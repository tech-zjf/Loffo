#!/usr/bin/env python3
"""Temporary-repository probes for architecture assumptions, not app tests.

Runs only our own generated filter. Does not read/write user repository config.
Prints JSON evidence; all fixtures are deleted on exit.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
           GIT_TERMINAL_PROMPT="0", LC_ALL="C")
results = []
with tempfile.TemporaryDirectory(prefix="loffo-git-probe-") as folder:
    root = Path(folder)

    def git(*args):
        return subprocess.run(["git", *args], cwd=root, env=env,
                              check=True, capture_output=True, timeout=10).stdout

    version = git("--version").decode().strip()
    git("init", "-q")
    (root / ".gitattributes").write_text("*.txt text eol=crlf\n*.demo filter=demo\n")
    (root / "example.txt").write_bytes(b"first\r\nsecond\r\n")
    git("add", "--", ".gitattributes", "example.txt")
    disk = (root / "example.txt").read_bytes()
    index = git("show", ":example.txt")
    result = index != disk and not git("diff", "--no-ext-diff", "--no-textconv", "--", "example.txt")
    results.append({"id": "raw-bytes-not-git-equality", "passed": result})

    # This is our controlled fixture, never a repository-supplied executable.
    (root / "filter.py").write_text(
        "import sys\nfrom pathlib import Path\n"
        "Path('filter-invoked').write_text('yes')\n"
        "sys.stdout.buffer.write(sys.stdin.buffer.read().lower())\n")
    import shlex
    git("config", "filter.demo.clean", shlex.quote(sys.executable) + " filter.py")
    git("config", "filter.demo.required", "true")
    (root / "sample.demo").write_text("HELLO\n")
    git("add", "--", "sample.demo")
    marker = root / "filter-invoked"
    marker.unlink()
    (root / "sample.demo").write_text("HELLO WORLD\n")
    git("diff", "--no-ext-diff", "--no-textconv", "--", "sample.demo")
    results.append({"id": "no-ext-diff-does-not-disable-clean", "passed": marker.exists()})
    marker.unlink(missing_ok=True)
    overrides = ("-c", "filter.demo.clean=", "-c", "filter.demo.smudge=",
                 "-c", "filter.demo.process=", "-c", "filter.demo.required=false")
    git(*overrides, "diff", "--no-ext-diff", "--no-textconv", "--", "sample.demo")
    results.append({"id": "known-clean-driver-command-override", "passed": not marker.exists()})

    # Same canonical content, but disabled filter must not be treated as Git parity.
    (root / "sample.demo").write_text("HELLO\n")
    normal = git("diff", "--no-ext-diff", "--no-textconv", "--", "sample.demo")
    marker.unlink(missing_ok=True)
    disabled = git(*overrides, "diff", "--no-ext-diff", "--no-textconv", "--", "sample.demo")
    results.append({"id": "disabled-filter-changes-status-semantics", "passed": not normal and bool(disabled) and not marker.exists()})

print(json.dumps({"git": version, "scope": "Git assumption probes only; no app, parser, renderer or performance validation", "results": results}, indent=2))
sys.exit(0 if all(item["passed"] for item in results) else 1)
