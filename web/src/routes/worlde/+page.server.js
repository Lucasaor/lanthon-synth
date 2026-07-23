import { readConfig, listSamples } from '$lib/config.js';
export async function load() {
  return { pads: (await readConfig('pads_worlde.json'))?.pads, samples: await listSamples() };
}
