import { listSetlists, readConfig } from '$lib/config.js';

export async function load() {
  const setlists = await listSetlists();
  const state = await readConfig('state.json') ?? {};
  return {
    setlists,
    activeSetlist: state.activeSetlist ?? null,
    songName:      state.songName ?? null,
    artist:        state.artist ?? null,
    playing:       state.playing === true || state.playing === 'true',
    bpm:           state.bpm ?? 0,
  };
}
