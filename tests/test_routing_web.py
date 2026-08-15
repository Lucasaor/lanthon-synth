"""Routing screen verification (Step 7) — full HTTP end-to-end.

Runs the built SvelteKit server (subprocess node) against an in-process
offline engine, over real HTTP + OSC:

1. /api/devices reflects the engine's live enumeration (mock devices).
2. PUT audio_routing.json + /config/routing_reload → engine rebuilds its
   audio plans with the configured per-track device/channel assignments.
3. Swapping the mock device list (simulating an interface hot-plug) and
   refreshing shows the new devices without restarting anything, and a
   routing referencing a disconnected device falls back to the default.

Skipped if web/build is missing or node is unavailable.
"""

import http.client
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import wave
import math
import struct

TMP = tempfile.mkdtemp(prefix="lanth0n-routing-web-")
os.environ["LANTH0N_PROJECT_DIR"] = TMP

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(REPO, "web", "build")

MOCK_A = json.dumps({
    "audio": [
        {"key": "audio:0", "name": "Mock A 8ch", "index": 0, "max_out_channels": 8},
        {"key": "audio:1", "name": "Mock A 2ch", "index": 1, "max_out_channels": 2},
    ],
    "midi_out": [{"key": "midi_out:0", "name": "Mock Pedalboard", "index": 0}],
    "midi_in": [{"key": "midi_in:0", "name": "Mock Controller", "index": 0}],
})
MOCK_B = json.dumps({
    "audio": [
        {"key": "audio:0", "name": "Mock B 12ch", "index": 0, "max_out_channels": 12},
    ],
    "midi_out": [{"key": "midi_out:0", "name": "Mock B Synth", "index": 0}],
    "midi_in": [],
})

sys.path.insert(0, REPO)

from engine import devices  # noqa: E402
from engine import paths  # noqa: E402
from engine.engine import Engine  # noqa: E402
from engine.smf import write_smf  # noqa: E402

SR = 48000
BLOCK = 512

EXIT_CALLS = []   # engine restart recorder (never actually exit the test process)


def free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def http_call(method, port, path, body=None):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    headers = {}
    payload = None
    if body is not None:
        payload = json.dumps(body)
        headers["content-type"] = "application/json"
    conn.request(method, path, payload, headers)
    resp = conn.getresponse()
    data = resp.read().decode()
    conn.close()
    return resp.status, json.loads(data) if data else None


def make_song(dirp, name):
    wav = os.path.join(dirp, f"{name}.wav")
    mid = os.path.join(dirp, f"{name}.mid")
    n = int(2.0 * SR)
    with wave.open(wav, "wb") as w:
        w.setnchannels(4)
        w.setsampwidth(2)
        w.setframerate(SR)
        fr = bytearray()
        for i in range(n):
            fr += struct.pack("<hhhh",
                              int(0.3 * math.sin(2 * math.pi * 220 * i / SR) * 32767),
                              int(0.3 * math.sin(2 * math.pi * 440 * i / SR) * 32767),
                              int(0.2 * math.sin(2 * math.pi * 1000 * i / SR) * 32767),
                              int(0.2 * math.sin(2 * math.pi * 2000 * i / SR) * 32767))
        w.writeframes(bytes(fr))
    write_smf(mid, [(480, bytes([0xC0, 1]))])
    return os.path.basename(wav), os.path.basename(mid)


@unittest.skipUnless(os.path.isdir(BUILD) and os.path.isfile(os.path.join(BUILD, "index.js"))
                     and shutil.which("node"), "web build or node unavailable")
class TestRoutingWeb(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._prev_devices = os.environ.get("LANTH0N_DEVICES_JSON")
        os.environ["LANTH0N_DEVICES_JSON"] = MOCK_A
        # fixture song + setlist in the engine project dir
        media = str(paths.MEDIA_DIR)
        os.makedirs(media, exist_ok=True)
        wav, mid = make_song(TMP, "R")
        shutil.copy(os.path.join(TMP, wav), os.path.join(media, wav))
        shutil.copy(os.path.join(TMP, mid), os.path.join(media, mid))
        setdir = str(paths.SETLISTS_DIR)
        os.makedirs(setdir, exist_ok=True)
        with open(os.path.join(setdir, "r.json"), "w") as f:
            json.dump({"name": "Routing Set", "songs": [
                {"name": "R", "wav": wav, "mid": mid, "tuning": "standard", "key": "E"}]}, f)

        cls.osc_port = free_port()
        cls.web_port = free_port()

        cls.engine = Engine(offline=True, sample_rate=SR, block_size=BLOCK,
                            osc_port=cls.osc_port, midi_in_enabled=False,
                            exit_fn=lambda code: EXIT_CALLS.append(code))
        cls.engine.start()
        # serve the OSC control interface (web UI targets it)
        import threading
        cls._osc_thread = threading.Thread(target=cls.engine.serve_forever, daemon=True)
        cls._osc_thread.start()
        cls.engine.load_setlist("r")
        cls._wait_cued()

        # engine publishes its live snapshot (mocked) for the web UI
        devices.write_devices_snapshot()

        # production-like web dir: <project root>/web/build + node_modules link
        # (must live under the SAME project root the engine resolves, so the
        # web server reads/writes the same config/ the engine uses)
        web_dir = os.path.join(str(paths.CONFIG_DIR.parent), "web")
        shutil.copytree(BUILD, os.path.join(web_dir, "build"))
        os.symlink(os.path.join(REPO, "web", "node_modules"),
                   os.path.join(web_dir, "node_modules"))

        env = dict(os.environ)
        env.update({
            "PORT": str(cls.web_port),
            "ENGINE_HOST": "127.0.0.1",
            "ENGINE_PORT": str(cls.osc_port),
        })
        cls.node = subprocess.Popen(
            ["node", "build/index.js"], cwd=web_dir, env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        # wait for the server to listen
        deadline = time.monotonic() + 20
        buf = ""
        while time.monotonic() < deadline:
            line = cls.node.stdout.readline()
            if line:
                buf += line
                if "Listening" in line:
                    break
            elif cls.node.poll() is not None:
                raise AssertionError(f"web server died:\n{buf}")
        else:
            cls.node.kill()
            raise AssertionError(f"web server never listened:\n{buf}")
        time.sleep(0.5)

    @classmethod
    def tearDownClass(cls):
        try:
            cls.node.kill()
        except Exception:
            pass
        cls.engine.shutdown()
        if cls._prev_devices is None:
            os.environ.pop("LANTH0N_DEVICES_JSON", None)
        else:
            os.environ["LANTH0N_DEVICES_JSON"] = cls._prev_devices

    @classmethod
    def _wait_cued(cls, timeout=10.0):
        t0 = time.monotonic()
        while time.monotonic() - t0 < timeout:
            s = cls.engine.transport.song
            if s is not None and s.open and s.name == "R":
                return
            time.sleep(0.05)
        raise AssertionError("song never cued")

    def test_media_delete_endpoint(self):
        """DELETE /api/media/<name>: blocked while a setlist references it,
        allowed otherwise; never touches files outside media/."""
        media = str(paths.MEDIA_DIR)
        extra = os.path.join(media, "ToDelete.wav")
        shutil.copy(os.path.join(media, "R.wav"), extra)
        self.assertTrue(os.path.exists(extra))

        # setlist that references the file
        tmp_setlist = os.path.join(str(paths.SETLISTS_DIR), "tmpdel.json")
        with open(tmp_setlist, "w") as f:
            json.dump({"name": "tmpdel", "songs": [
                {"name": "X", "wav": "ToDelete.wav", "mid": ""}]}, f)

        # 1) referenced → 409
        status, data = http_call("DELETE", self.web_port, "/api/media/ToDelete.wav")
        self.assertEqual(status, 409)
        self.assertIn("tmpdel", data.get("referencing", []))
        self.assertTrue(os.path.exists(extra), "file must survive the 409")

        # 2) unreferenced → deleted
        with open(tmp_setlist, "w") as f:
            json.dump({"name": "tmpdel", "songs": []}, f)
        status, data = http_call("DELETE", self.web_port, "/api/media/ToDelete.wav")
        self.assertEqual(status, 200)
        self.assertTrue(data.get("ok"))
        self.assertFalse(os.path.exists(extra), "file should be gone")

        # 3) gone → 404
        status, _ = http_call("DELETE", self.web_port, "/api/media/ToDelete.wav")
        self.assertEqual(status, 404)

        # 4) traversal attempts are rejected
        status, _ = http_call("DELETE", self.web_port,
                              "/api/media/..%2F..%2Fetc%2Fpasswd")
        self.assertIn(status, (400, 404))

        os.unlink(tmp_setlist)

    def test_engine_restart_endpoint(self):
        """POST /api/engine/restart reaches the engine over OSC when online."""
        before = len(EXIT_CALLS)
        status, data = http_call("POST", self.web_port, "/api/engine/restart")
        self.assertEqual(status, 200)
        self.assertTrue(data["ok"])
        self.assertEqual(data["method"], "osc")  # engine heartbeat is fresh
        deadline = time.monotonic() + 5.0
        while len(EXIT_CALLS) == before and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertEqual(len(EXIT_CALLS), before + 1)
        self.assertEqual(EXIT_CALLS[-1], 42)

    def test_devices_endpoint_reflects_engine_snapshot(self):
        # force a fresh snapshot so this test is order-independent
        devices.write_devices_snapshot()
        status, data = http_call("GET", self.web_port, "/api/devices")
        self.assertEqual(status, 200)
        names = [d["name"] for d in data["audio"]]
        self.assertIn("Mock A 8ch", names)
        self.assertIn("Mock A 2ch", names)
        self.assertEqual([d["name"] for d in data["midi_out"]], ["Mock Pedalboard"])

    def test_routing_save_applies_to_engine(self):
        routing = {
            "clock_device": "Mock A 8ch",
            "tracks": {
                "playback_l": {"device": "Mock A 8ch", "channel": 1},
                "playback_r": {"device": "Mock A 8ch", "channel": 2},
                "click": {"device": "Mock A 2ch", "channel": 1},
                "cue": {"device": "Mock A 8ch", "channel": 3},
                "timecode": {"device": "auto", "channel": 5, "enabled": False},
                "midi_automation": {"device": "Mock Pedalboard"},
            },
        }
        status, _ = http_call("PUT", self.web_port, "/api/config/audio_routing.json", routing)
        self.assertEqual(status, 200)
        status, _ = http_call("POST", self.web_port, "/api/osc",
                         {"address": "/config/routing_reload"})
        self.assertEqual(status, 200)
        time.sleep(0.5)

        plans = {p.key: p for p in self.engine._plans}
        self.assertEqual(set(plans), {"audio:0", "audio:1"})
        main = plans["audio:0"]
        routes = {(r.wav_ch, r.out_ch) for r in main.routes}
        self.assertEqual(routes, {(0, 0), (1, 1), (3, 2)})  # L, R, Cue→ch3
        self.assertTrue(main.is_master)
        second = plans["audio:1"]
        self.assertEqual([(r.wav_ch, r.out_ch) for r in second.routes], [(2, 0)])

    def test_device_swap_reflected_without_restart(self):
        # "unplug" interface A, "plug in" interface B
        os.environ["LANTH0N_DEVICES_JSON"] = MOCK_B
        status, _ = http_call("POST", self.web_port, "/api/osc",
                         {"address": "/devices/refresh"})
        self.assertEqual(status, 200)
        time.sleep(0.5)

        status, data = http_call("GET", self.web_port, "/api/devices")
        self.assertEqual(status, 200)
        names = [d["name"] for d in data["audio"]]
        self.assertIn("Mock B 12ch", names)
        self.assertNotIn("Mock A 8ch", names)
        self.assertEqual([d["name"] for d in data["midi_out"]], ["Mock B Synth"])

        # routing still references the now-disconnected Mock A → apply → the
        # engine falls back to the default device instead of crashing
        status, _ = http_call("POST", self.web_port, "/api/osc",
                         {"address": "/config/routing_reload"})
        self.assertEqual(status, 200)
        time.sleep(0.5)
        plans = self.engine._plans
        self.assertEqual(len(plans), 1)
        self.assertEqual(plans[0].key, "audio:0")     # default Mock B device
        wav_chs = sorted(r.wav_ch for r in plans[0].routes)
        self.assertEqual(wav_chs, [0, 1, 2, 3])       # all tracks survived

        # restore mock A for other tests / repeatability
        os.environ["LANTH0N_DEVICES_JSON"] = MOCK_A


if __name__ == "__main__":
    unittest.main(verbosity=2)
