"""Structured log lines: `<utc> LEVEL run=<id> event=<name> key="value"`. stdout (journal) + rotating file.

Values are scrubbed (control characters, tokens, PEM markers) and truncated. Subprocess stdout is never logged.
"""

from __future__ import annotations

import os
import re
import sys
import time
from typing import Optional, TextIO

MAX_VALUE = 300
ROTATE_BYTES = 1024 * 1024

_SCRUBS = [
    (re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}"), "[token]"),
    (re.compile(r"github_pat_[A-Za-z0-9_]{20,}"), "[token]"),
    (re.compile(r"(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}"), "Bearer [token]"),
    (re.compile(r"(?i)authorization:\s*\S+(\s+\S+)?"), "authorization: [redacted]"),
    (re.compile(r"-----BEGIN [A-Z ]+-----"), "[pem]"),
    (re.compile(r"MII[A-Za-z0-9+/=]{40,}"), "[der]"),
]


def scrub(value: object) -> str:
    s = str(value)
    s = "".join(ch if (ch >= " " and ch != "\x7f") else " " for ch in s)
    for rx, repl in _SCRUBS:
        s = rx.sub(repl, s)
    s = s.replace("\\", "\\\\").replace('"', '\\"')
    if len(s) > MAX_VALUE:
        s = s[:MAX_VALUE] + "..."
    return s


class Logger:
    def __init__(self, run_id: str, logfile: Optional[str] = None, stream: Optional[TextIO] = None,
                 clock=time.time) -> None:
        self.run_id = run_id
        self.logfile = logfile
        self.stream = stream if stream is not None else sys.stdout
        self.clock = clock

    def _rotate(self) -> None:
        if not self.logfile:
            return
        try:
            if os.path.getsize(self.logfile) > ROTATE_BYTES:
                os.replace(self.logfile, self.logfile + ".1")
        except OSError:
            pass

    def log(self, level: str, event: str, **kv: object) -> None:
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(self.clock()))
        parts = ["%s" % ts, level, "run=%s" % self.run_id, "event=%s" % scrub(event).replace(" ", "_")]
        for k, v in kv.items():
            parts.append('%s="%s"' % (re.sub(r"[^A-Za-z0-9_]", "_", k), scrub(v)))
        line = " ".join(parts)
        try:
            self.stream.write(line + "\n")
            self.stream.flush()
        except (OSError, ValueError):
            pass
        if self.logfile:
            try:
                self._rotate()
                fd = os.open(self.logfile, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
                try:
                    os.write(fd, (line + "\n").encode("utf-8", "replace"))
                finally:
                    os.close(fd)
            except OSError:
                pass  # logging must never break the run (e.g. disk full)

    def info(self, event: str, **kv: object) -> None:
        self.log("INFO", event, **kv)

    def warn(self, event: str, **kv: object) -> None:
        self.log("WARN", event, **kv)

    def error(self, event: str, **kv: object) -> None:
        self.log("ERROR", event, **kv)
