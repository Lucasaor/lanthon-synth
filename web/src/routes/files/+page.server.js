import { listMedia } from '$lib/config.js';
export async function load() {
  return { media: await listMedia() };
}
