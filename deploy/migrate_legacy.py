#!/usr/bin/env python3
"""migrate_legacy.py — migrate legacy split-track setlists to the new model.

Old model: one file per track — "<song> (VS).wav" + "<song> (Click).wav" +
"<song> (Dica).wav" (fields vs/click/dica in the setlist JSON).
New model: ONE multichannel WAV per song — ch1 Playback L, ch2 Playback R,
ch3 Click, ch4 Cue — plus a companion MID file.

This script merges the legacy tracks into a 4-channel interleaved WAV at
48 kHz (the engine's sample rate) with ffmpeg, rewrites the setlist to
`wav`/`mid` fields, and keeps a `.legacy.json` backup. The `mid` field is
left empty — automation files are authored in Reaper and uploaded via the
web UI (or added by hand).

Run on the Pi (or any machine with ffmpeg + the project dir):

    python3 deploy/migrate_legacy.py

Only songs that still carry legacy fields are touched; already-migrated
songs (with `wav`) are skipped.
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

PROJECT = Path(os.environ.get("LANTH0N_PROJECT_DIR") or Path(__file__).resolve().parent.parent)
MEDIA = PROJECT / "media"
SETLISTS = PROJECT / "setlists"

FFMPEG = "ffmpeg"

# three legacy inputs → 4ch interleaved output:
#   VS (stereo) L/R → ch 1/2, Click L → ch 3, Dica L → ch 4
FILTER = (
    "[0:a]aresample=48000,pan=stereo|c0=c0|c1=c1[vsa];"
    "[1:a]aresample=48000,pan=stereo|c0=c0|c1=c1[cla];"
    "[2:a]aresample=48000,pan=stereo|c0=c0|c1=c1[dl];"
    "[vsa][cla][dl]join=inputs=3:channel_layout=5.1[j];"
    "[j]pan=4c|c0=c0|c1=c1|c2=c2|c3=c4[a]"
)


def safe_name(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9 _-]+", "_", name).strip() or "song"


def merge(song_name: str, vs_path, click_path, dica_path) -> Path:
    out = MEDIA / f"{safe_name(song_name)}.multichannel.wav"
    cmd = [FFMPEG, "-y", "-loglevel", "error"]
    for p in (vs_path, click_path, dica_path):
        if p:
            cmd += ["-i", str(p)]
        else:
            cmd += ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo"]
    cmd += ["-filter_complex", FILTER, "-map", "[a]", "-ac", "4", "-ar", "48000", str(out)]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0 or not out.exists():
        raise RuntimeError(f"ffmpeg failed for '{song_name}': {result.stderr[-400:]}")
    return out


def resolve(media_files, field_value):
    if not field_value or field_value in ("none", ""):
        return None
    if os.path.isabs(field_value):
        return Path(field_value)
    p = MEDIA / field_value
    if p.exists():
        return p
    return None


def migrate_setlist(path: Path) -> dict:
    original = path.read_text()
    data = json.loads(original)
    migrated = 0
    for song in data.get("songs", []) or []:
        if song.get("wav"):
            continue  # already migrated
        if not any(k in song for k in ("vs", "click", "dica")):
            continue
        vs = resolve(None, song.get("vs"))
        click = resolve(None, song.get("click"))
        dica = resolve(None, song.get("dica"))
        if not vs and not click and not dica:
            print(f"  skip '{song.get('name')}' — no legacy files found")
            continue
        out = merge(song.get("name") or "song", vs, click, dica)
        song["wav"] = out.name
        song["mid"] = ""
        for k in ("vs", "click", "dica", "tempo"):
            song.pop(k, None)
        migrated += 1
        print(f"  ✓ '{song.get('name')}' → {out.name}")
    if migrated:
        # backup the ORIGINAL setlist, then persist the migrated one
        path.with_suffix(".json.legacy").write_text(original)
        path.write_text(json.dumps(data, indent=2))
    return migrated


def main() -> int:
    if not SETLISTS.is_dir():
        print(f"no setlists dir: {SETLISTS}")
        return 1
    total = 0
    for path in sorted(SETLISTS.glob("*.json")):
        if path.name.endswith(".legacy"):
            continue
        print(f"setlist: {path.name}")
        total += migrate_setlist(path)
    print(f"migrated {total} song(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
