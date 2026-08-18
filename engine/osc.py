"""OSC server (web UI control) + OLED update sender.

The engine listens on UDP 57120 — the same address SuperCollider used —
and keeps the legacy /backtrack/* command vocabulary, so the existing web
UI transport code works unchanged. It also feeds the OLED daemon on
UDP 9000 with the legacy /oled/update and /oled/heartbeat messages.
"""

from __future__ import annotations

import logging
import threading
from typing import Callable, Optional

from pythonosc.dispatcher import Dispatcher
from pythonosc.osc_server import BlockingOSCUDPServer
from pythonosc.udp_client import SimpleUDPClient

log = logging.getLogger("engine.osc")


class _TolerantOSCUDPServer(BlockingOSCUDPServer):
    """BlockingOSCUDPServer that never dies on malformed datagrams.

    python-osc raises inside the request handler for unknown/corrupt OSC
    content (e.g. unsupported type tags); without this guard the exception
    escapes serve_forever() and takes the whole engine down with it.
    """

    def _handle_request_noblock(self):
        try:
            super()._handle_request_noblock()
        except Exception:
            log.debug("dropped malformed OSC datagram", exc_info=True)


class OscControl:
    def __init__(self, host: str = "0.0.0.0", port: int = 57120,
                 oled_host: str = "127.0.0.1", oled_port: int = 9000):
        self.host = host
        self.port = port
        self._oled: Optional[SimpleUDPClient] = None
        self._oled_addr = (oled_host, oled_port)
        self._handlers: dict = {}
        self._server: Optional[BlockingOSCUDPServer] = None

    # -- handlers registry -------------------------------------------------

    def on(self, address: str, fn: Callable) -> None:
        self._handlers[address] = fn

    # -- OLED --------------------------------------------------------------

    def oled_update(self, setlist: str, artist: str, song: str,
                    state: str, tuning: str,
                    position_sec: float = 0.0,
                    duration_sec: float = 0.0) -> None:
        try:
            if self._oled is None:
                self._oled = SimpleUDPClient(*self._oled_addr)
            # python-osc send_message(address, value): multiple args go
            # inside a single list value
            self._oled.send_message(
                "/oled/update", [setlist, artist, song, state, tuning,
                                 position_sec, duration_sec])
        except Exception:
            log.debug("OLED update failed (daemon not running?)")

    def oled_heartbeat(self, online: bool, playing: bool) -> None:
        try:
            if self._oled is None:
                self._oled = SimpleUDPClient(*self._oled_addr)
            self._oled.send_message(
                "/oled/heartbeat",
                [1 if online else 0, 1 if playing else 0])
        except Exception:
            log.debug("OLED heartbeat failed")

    # -- server ------------------------------------------------------------

    def serve_forever(self) -> None:
        dispatcher = Dispatcher()
        for address, fn in self._handlers.items():
            dispatcher.map(address, fn)
        dispatcher.set_default_handler(
            lambda addr, *args: log.debug("unhandled OSC: %s %s", addr, args))
        self._server = _TolerantOSCUDPServer((self.host, self.port), dispatcher)
        log.info("OSC control server on %s:%d", self.host, self.port)
        self._server.serve_forever()

    def stop(self) -> None:
        if self._server is not None:
            try:
                self._server.shutdown()
            except Exception:
                pass
            self._server = None
        if self._oled is not None:
            try:
                self._oled._sock.close()
            except Exception:
                pass
            self._oled = None
