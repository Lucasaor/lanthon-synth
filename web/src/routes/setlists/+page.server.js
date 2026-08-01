import { listSetlists, listMedia } from '$lib/config.js';
export async function load() {
  return {
    setlists: await listSetlists(),
    media: await listMedia(),
  };
}
