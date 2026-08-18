import { listSetlists, listMedia, readConfig } from '$lib/config.js';
export async function load() {
  const state = await readConfig('state.json') ?? {};
  return {
    setlists: await listSetlists(),
    media: await listMedia(),
    activeSetlist: state.activeSetlist ?? null,
  };
}
