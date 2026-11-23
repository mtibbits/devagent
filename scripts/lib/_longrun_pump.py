#!/usr/bin/env python3
"""scripts/lib/_longrun_pump.py — #932: the byte pump libexec/long-run.sh puts
between a wrapped command and its caller. Stdlib only, Python 3.8 syntax; the
wrapper starts it as `python3 -I -B`.

    _longrun_pump.py <stream> <log> <cap> <heartbeat> <every> <threshold> <run>
    _longrun_pump.py --probe          exit 0: this python3 can run the pump

    <stream>     stdout | stderr | merged: the name in the `closed` line
    <log>        the file this pump appends to, and it alone; empty = no log
    <cap>        bytes the log never passes (default 5242880)
    <heartbeat>  the run's heartbeat file, `wrap.<run>`; empty = an attended
                 run, or one with no session id: copy and log only
    <every>      seconds between refreshes of the heartbeat; 0 = every chunk
    <threshold>  a gap longer than this many seconds is noted as `quiet`;
                 0 = never
    <run>        the run id, printed in this pump's lines

It copies fd 0 to fd 1 a chunk at a time, unchanged and unbuffered. The copy
comes first and nothing else can stop it: the heartbeat and the log are each
tried once per chunk and a failure of either is dropped. The pump ends when
its input ends, or when its output is closed (it then stops reading, so the
command sees the closed pipe as it would without the pump).

Heartbeat. The file's mtime is the time of the last output this run carried.
A refresh moves it to the chunk's arrival time, at most once per <every>
seconds, and never earlier than it already is: the other stream's pump moves
the same file. At the end of input one final refresh moves it to the last
chunk's time if a chunk since the last refresh is still owed. `refreshes=<n>`
counts the times this pump moved the mtime forward.

Gaps. A chunk's gap is its arrival time minus the later of this pump's
previous chunk and the heartbeat's mtime; before the first chunk, the pump's
own start. Whole seconds, rounded down. A gap above <threshold> appends one
`quiet` line when it ends, that is, before the chunk that ended it. An
attended run has no heartbeat and writes no `quiet` line.

Log. One writer per file, so appends cannot overwrite each other on Windows,
where O_APPEND is a seek and a write. The file is opened per append. When an
append would take a non-empty log past <cap> less 256 bytes (room for the
wrapper's `end` line), the log is renamed to `<log>.1` first; if the rename
fails (a reader holds the file open on Windows) the log is emptied in place
instead, so it never grows past the cap.

    [long-run] quiet <gap>s > <threshold>s ended <ISO-UTC> run=<run>
    [long-run] closed <stream> <ISO-UTC> run=<run> longest-gap=<gap>s refreshes=<n>
"""

import os
import signal
import sys
import time

CHUNK = 65536
RESERVE = 256
DEFAULT_CAP = 5242880
DEFAULT_EVERY = 5
DIGITS = "0123456789"


def number(text, digits, default):
    """<text> as an int when it is 1..<digits> ASCII digits, else <default>.
    The length is checked before int(), so no argument makes a huge number."""
    if 0 < len(text) <= digits and all(c in DIGITS for c in text):
        return int(text)
    return default


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def write_all(fd, data):
    view = memoryview(data)
    while view:
        view = view[os.write(fd, view):]


class Log(object):
    def __init__(self, path, cap):
        self.path = path
        self.limit = max(cap - RESERVE, CHUNK)
        self.at_line_start = True

    def append(self, data):
        if not self.path:
            return
        flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_BINARY", 0)
        fd = os.open(self.path, flags, 0o644)
        try:
            size = os.fstat(fd).st_size
            if size > 0 and size + len(data) > self.limit:
                os.close(fd)
                fd = -1
                extra = 0
                try:
                    os.replace(self.path, self.path + ".1")
                except OSError:
                    extra = os.O_TRUNC
                fd = os.open(self.path, flags | extra, 0o644)
            write_all(fd, data)
        finally:
            if fd >= 0:
                os.close(fd)
        self.at_line_start = data.endswith(b"\n")

    def note(self, text):
        """One [long-run] line, on a line of its own."""
        lead = b"" if self.at_line_start else b"\n"
        self.append(lead + text.encode("ascii", "replace") + b"\n")


def main(argv):
    if argv[1:2] == ["--probe"]:
        return 0
    args = argv[1:8] + [""] * 7
    stream, log_path, cap, heartbeat, every, threshold, run = args[:7]
    if stream not in ("stdout", "stderr", "merged"):
        stream = "merged"
    cap = number(cap, 10, DEFAULT_CAP)
    every = number(every, 4, DEFAULT_EVERY)
    threshold = number(threshold, 6, 0)
    log = Log(log_path, cap)

    try:
        # Ctrl-C reaches the whole foreground group; the pump outlives it to
        # carry what the command still prints, and ends with its input.
        signal.signal(signal.SIGINT, signal.SIG_IGN)
    except (OSError, ValueError):
        pass

    start = time.time()
    previous = None        # arrival of this pump's previous chunk
    refreshed = None       # arrival of the chunk that last tried a refresh
    owed = False           # a chunk arrived since the last refresh
    longest = 0
    refreshes = 0

    while True:
        try:
            data = os.read(0, CHUNK)
        except OSError:
            break
        if not data:
            break
        now = time.time()
        try:
            write_all(1, data)
        except OSError:
            break

        quiet = None
        try:
            since = start if previous is None else previous
            mtime = None
            if heartbeat:
                try:
                    mtime = os.stat(heartbeat).st_mtime
                except FileNotFoundError:
                    # Removed mid-run: put it back, or the rest of the run's
                    # output would not be progress. A missing directory raises
                    # here too and skips this chunk's heartbeat work.
                    open(heartbeat, "a").close()
                    mtime = os.stat(heartbeat).st_mtime
                since = min(max(since, mtime), now)
            gap = int(now - since)
            if gap > longest:
                longest = gap
            if heartbeat and threshold and gap > threshold:
                quiet = "[long-run] quiet %ds > %ds ended %s run=%s" % (gap, threshold, iso(now), run)
            if heartbeat:
                if refreshed is None or every == 0 or now - refreshed >= every:
                    refreshed = now
                    owed = False
                    if now > mtime:
                        os.utime(heartbeat, (now, now))
                        refreshes += 1
                else:
                    owed = True
        except Exception:
            pass
        previous = now

        try:
            if quiet:
                log.note(quiet)
            log.append(data)
        except Exception:
            pass

    try:
        if heartbeat and owed and previous is not None:
            if previous > os.stat(heartbeat).st_mtime:
                os.utime(heartbeat, (previous, previous))
                refreshes += 1
    except Exception:
        pass
    try:
        log.note("[long-run] closed %s %s run=%s longest-gap=%ds refreshes=%d"
                 % (stream, iso(time.time()), run, longest, refreshes))
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
