#!/usr/bin/env python3
"""A Source RCON client, small enough to read, for driving a dedicated server.

This is the portable copy that ships WITH the addon so `tools/server/bmx-test`
has something to type into a server with no tty. It is deliberately standalone:
no dependencies, no config file, password from --password or the environment.

WHY RCON AT ALL. A dedicated test server has no client, no GPU, and a console
that lives inside a service manager with no tty. RCON is the only way to type
into it, which is what makes a headless loop possible at all:

    rcon.py "bmx_test"        run the regression suite
    rcon.py "bmx_selftest"    check the force-units assumption
    rcon.py "bmx_debug 1"     (a client convar, so this one does nothing here)

WIRE FORMAT, little-endian throughout:

    int32   size of everything after this field
    int32   request id, echoed back so replies can be matched
    int32   type
    bytes   body, NUL-terminated
    byte    0x00, a second empty NUL-terminated string

    types:  3 = AUTH            (client -> server)
            2 = AUTH_RESPONSE   (server -> client)
            2 = EXECCOMMAND     (client -> server; yes, same number)
            0 = RESPONSE_VALUE  (server -> client)

AUTH: the server answers with an empty RESPONSE_VALUE and then an
AUTH_RESPONSE whose id is the request id on success, or **-1 on failure**. The
id is the only signal; a wrong password does not produce an error string.

MULTI-PACKET REPLIES: a long reply arrives as several RESPONSE_VALUE packets
with no terminator, so a client has to fence the end itself.

*** DO NOT USE THE STANDARD SENTINEL TRICK HERE. *** Every Source RCON tutorial
says to follow the real command with an empty SERVERDATA_RESPONSE_VALUE (type 0)
packet and treat its reply as the end marker. Garry's Mod rejects that. Its RCON
is hardened against HTTP probes, and a type-0 packet arriving FROM a client is
one of the shapes it treats as an attack:

    192.168.x.x tried to get banned using the HTTP(S) request to RCON. 26

The connection is closed, offences are counted, and enough of them get the
source address banned outright. The symptom is maddening: short commands appear
to work (their reply races in before the server reacts) while anything slower
dies with "connection closed by the server mid-packet", so it reads like a
timeout or a crash in the command you ran rather than a protocol violation in
the client.

So the fence here is a second EXECCOMMAND running `echo <marker>` -- a perfectly
ordinary command whose reply is unambiguous and which nothing objects to.

*** AND ONE COMMAND LENGTH IS REJECTED OUTRIGHT. *** Measured by sweeping every
body length from 0 to 25 against a live server (2026-08-20): a packet whose
TOTAL WIRE SIZE is exactly 26 bytes is refused with the same "tried to get
banned" message and the connection dropped. Every other size from 19 to 44
works. Wire size is 14 + len(body), so the poison length is a body of exactly
**12 characters** -- which `bmx_selftest` happens to be, and which is how this
was found: one command failed reliably while its neighbours worked, and it
looked for an hour like a bug in that command.

The fix is to pad a 12-character command with a trailing space, which Source's
tokeniser ignores. It is applied to COMMANDS ONLY. It must never be applied to
the AUTH packet, because padding a password changes the password; a 12-character
RCON password is instead rejected up front with a real explanation.

The password comes from --password or the GMOD_RCON_PASSWORD environment
variable, and is never printed -- not in an error, not in a traceback.
"""

from __future__ import annotations

import argparse
import os
import socket
import struct
import sys

SERVERDATA_AUTH = 3
SERVERDATA_AUTH_RESPONSE = 2
SERVERDATA_EXECCOMMAND = 2
SERVERDATA_RESPONSE_VALUE = 0

END_MARKER = "__BMX_RCON_END__"


class RconError(Exception):
    pass


class Rcon:
    def __init__(self, host: str, port: int = 27015, timeout: float = 20.0):
        self.host, self.port, self.timeout = host, port, timeout
        self.sock = None
        self._id = 0

    def __enter__(self):
        self.sock = socket.create_connection((self.host, self.port), self.timeout)
        self.sock.settimeout(self.timeout)
        return self

    def __exit__(self, *exc):
        if self.sock:
            self.sock.close()

    # -- framing ---------------------------------------------------------
    def _next_id(self) -> int:
        self._id += 1
        return self._id

    def _send(self, ptype: int, body: str) -> int:
        rid = self._next_id()
        payload = struct.pack("<ii", rid, ptype) + body.encode("utf-8") + b"\x00\x00"
        self.sock.sendall(struct.pack("<i", len(payload)) + payload)
        return rid

    def _recv_exact(self, n: int) -> bytes:
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise RconError("connection closed by the server mid-packet")
            buf += chunk
        return buf

    def _recv(self):
        size = struct.unpack("<i", self._recv_exact(4))[0]
        if size < 10 or size > 4_194_304:
            raise RconError("implausible packet size %d" % size)
        data = self._recv_exact(size)
        rid, ptype = struct.unpack("<ii", data[:8])
        body = data[8:-2].decode("utf-8", errors="replace")
        return rid, ptype, body

    # -- protocol --------------------------------------------------------
    def auth(self, password: str) -> None:
        # Cannot pad our way out of this one: a padded password is a different
        # password. Say so plainly rather than letting it fail as a dropped
        # connection that looks like a wrong credential.
        if self._OVERHEAD + len(password) == self.POISON_WIRE_SIZE:
            raise RconError(
                "this RCON password is %d characters, which produces the one "
                "packet size GMod's RCON refuses (see the module docstring). "
                "Change rcon_password to any other length."
                % len(password))
        rid = self._send(SERVERDATA_AUTH, password)
        while True:
            got_id, ptype, _ = self._recv()
            if ptype == SERVERDATA_AUTH_RESPONSE:
                if got_id == -1:
                    raise RconError("RCON auth rejected (wrong password)")
                if got_id != rid:
                    raise RconError("RCON auth response id mismatch")
                return
            # the empty RESPONSE_VALUE that precedes it: ignore and keep reading

    # Wire size = 4 (size field) + 4 (id) + 4 (type) + len(body) + 2 (two NULs).
    POISON_WIRE_SIZE = 26
    _OVERHEAD = 14

    @classmethod
    def _pad(cls, body: str) -> str:
        """Nudge a command off the one packet size GMod's RCON refuses."""
        while cls._OVERHEAD + len(body) == cls.POISON_WIRE_SIZE:
            body += " "        # Source tokenises on whitespace; a trailing
                               # space cannot change what the command does
        return body

    def command(self, cmd: str) -> str:
        real = self._send(SERVERDATA_EXECCOMMAND, self._pad(cmd))

        # The fence. An ordinary command, NOT a bare type-0 packet: see the
        # module docstring for why the usual sentinel gets you banned here.
        fence = self._send(SERVERDATA_EXECCOMMAND, "echo " + END_MARKER)

        out = []
        while True:
            rid, _ptype, body = self._recv()

            # GMod echoes console output back on the connection, so the marker
            # can arrive on either id. Match the text as well as the id.
            if END_MARKER in body:
                head = body.split(END_MARKER)[0]
                if head:
                    out.append(head)
                break
            if rid == fence:
                break
            if rid == real or rid == 0:
                out.append(body)

        text = "".join(out)
        # The server echoes the command it just ran; that is noise, not output.
        lines = [ln for ln in text.splitlines()
                 if not ln.startswith("rcon from ")
                 and END_MARKER not in ln]
        return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", nargs="+", help="console command to run")
    ap.add_argument("--host", default=os.environ.get("GMOD_RCON_HOST", "127.0.0.1"))
    ap.add_argument("--port", type=int,
                    default=int(os.environ.get("GMOD_RCON_PORT", "27015")))
    ap.add_argument("--timeout", type=float, default=20.0)
    ap.add_argument("--password", default=None,
                    help="prefer GMOD_RCON_PASSWORD: an argument is visible in ps")
    args = ap.parse_args()

    password = args.password or os.environ.get("GMOD_RCON_PASSWORD")
    if not password:
        print("no RCON password: pass --password or set GMOD_RCON_PASSWORD",
              file=sys.stderr)
        return 2

    cmd = " ".join(args.command)

    try:
        with Rcon(args.host, args.port, args.timeout) as r:
            r.auth(password)
            reply = r.command(cmd)
    except (OSError, RconError) as e:
        # Never echo the password, not even in a traceback.
        print("RCON %s:%d failed: %s" % (args.host, args.port, e), file=sys.stderr)
        return 1

    sys.stdout.write(reply)
    if reply and not reply.endswith("\n"):
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
