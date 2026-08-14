"""Engine entry point.

Run headless on the Pi via lanthon-engine.service, or locally:

    python3 -m engine.main --offline --setlist "Night 1"

(NOTE: always run as `python3 -m engine.main` from the project root —
executing engine/main.py directly shadows the engine package with
engine/engine.py and breaks the relative imports.)

Environment:
    LANTH0N_PROJECT_DIR   project root (default: repo root)
    LANTH0N_OFFLINE=1     offline driver (no audio hardware; tests)
    LANTH0N_DEVICE        audio output device name or index
    LANTH0N_MIDI_OUT      MIDI automation output port name or index
    LANTH0N_MIDI_IN=0     disable MIDI input
    LANTH0N_OSC_PORT      control OSC port (default 57120)
    LANTH0N_OLED_PORT     OLED daemon OSC port (default 9000)
    LANTH0N_SR            sample rate (default 48000)
    LANTH0N_BLOCK         audio block size (default 512)
"""

import argparse
import logging
import os
import sys

from engine import paths
from engine.engine import DEFAULT_BLOCK, DEFAULT_SR, Engine


def main() -> int:
    parser = argparse.ArgumentParser(description="LANTH0N 5YNTH playback engine")
    parser.add_argument("--offline", action="store_true",
                        help="offline driver (no audio hardware)")
    parser.add_argument("--setlist", default=None, help="setlist name to load")
    parser.add_argument("--song", nargs="+", metavar=("WAV", "MID"),
                        help="play a single song: WAV [MID]")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="[ENGINE] %(asctime)s %(levelname)s %(name)s: %(message)s",
        datefmt="%H:%M:%S",
    )
    paths.ensure_dirs()

    sr = int(os.environ.get("LANTH0N_SR", DEFAULT_SR))
    block = int(os.environ.get("LANTH0N_BLOCK", DEFAULT_BLOCK))
    offline = args.offline or os.environ.get("LANTH0N_OFFLINE", "0") == "1"
    osc_port = int(os.environ.get("LANTH0N_OSC_PORT", "57120"))
    oled_port = int(os.environ.get("LANTH0N_OLED_PORT", "9000"))
    midi_in = os.environ.get("LANTH0N_MIDI_IN", "1") == "1"

    engine = Engine(
        offline=offline,
        sample_rate=sr,
        block_size=block,
        osc_port=osc_port,
        oled_port=oled_port,
        midi_out_port=os.environ.get("LANTH0N_MIDI_OUT"),
        midi_in_enabled=midi_in,
    )
    engine.start()

    if args.song:
        from engine.song import Song
        import json

        wav, *rest = args.song
        song = Song(
            name=os.path.basename(wav), artist="", tuning="standard", key="E",
            wav_path=wav, mid_path=rest[0] if rest else None, sample_rate=sr,
        )
        song.cue()
        engine._plans = engine.build_plans(song)
        engine.transport.set_song(song)
    elif args.setlist:
        engine.load_setlist(args.setlist)
    else:
        engine.auto_load_last_setlist()

    if offline:
        # pump renders while OSC control stays available — good for
        # hardware-free integration tests and headless demo runs
        rate = float(os.environ.get("LANTH0N_OFFLINE_RATE", "1.0") or 1.0)
        engine.start_offline_pump(rate)
        print("OFFLINE ENGINE RUNNING (Ctrl+C to stop)")
        try:
            engine.serve_forever()
        except KeyboardInterrupt:
            print("\nShutting down.")
        finally:
            engine.shutdown()
        return 0

    print("============================================")
    print("  LANTH0N 5YNTH — PLAYBACK ENGINE READY")
    print("============================================")
    print(f"  OSC control : udp:{osc_port}")
    print(f"  OLED        : udp:{oled_port}")
    print("")
    try:
        engine.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
    finally:
        engine.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
