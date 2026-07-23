import { listSetlists } from '$lib/config.js';

export async function load() {
  const setlists = await listSetlists();
  return { setlists };
}
