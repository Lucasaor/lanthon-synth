/**
 * GET  /api/state → { activeSetlist, songName, artist, playing, tuning }
 *
 * Reads state.json written by the SuperCollider backtrack engine.
 * SC writes this file on every playback state change (play/stop/next/prev/load).
 *
 * POST /api/state is NOT used — SC is the source of truth for playback state.
 * The web dashboard sends OSC commands directly to SC, and SC updates state.json.
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
    tuning:        state.tuning ?? null,
  });
}
