import { readConfig } from '$lib/config.js';
export async function load() { return { map: await readConfig('midi_map.json') }; }
