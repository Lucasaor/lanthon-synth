/**
 * GET  /api/state → { activeSetlist, songName, artist, playing, state,
 *                     tuning, key, positionSec, durationSec, songIndex,
 *                     songCount }
 *
 * Reads state.json written by the playback engine — the engine is the
 * single source of truth for playback state. The web dashboard sends OSC
 * commands to the engine, and the engine updates state.json.
 */
import { json } from '@sveltejs/kit';
import { readConfig } from '$lib/config.js';

const STATE_FILE = 'state.json';

export async function GET() {
  const state = await readConfig(STATE_FILE) ?? {};
  return json({
    activeSetlist: state.activeSetlist ?? null,
    songName:      state.songName ?? null,
    artist:        state.artist ?? null,
    playing:       state.playing === true || state.playing === 'true',
    state:         state.state ?? null,
    tuning:        state.tuning ?? null,
    key:           state.key ?? null,
    positionSec:   state.positionSec ?? 0,
    durationSec:   state.durationSec ?? 0,
    seekSec:       state.seekSec ?? null,
    cueError:      state.cueError ?? null,
    songIndex:     state.songIndex ?? 0,
    songCount:     state.songCount ?? 0,
  });
}
