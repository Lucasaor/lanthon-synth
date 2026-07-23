import { listMedia, listSamples } from '$lib/config.js';
export async function load() {
  return { media: await listMedia(), samples: await listSamples() };
}
