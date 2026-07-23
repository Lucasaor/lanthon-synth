import { readConfig } from '$lib/config.js';
export async function load() { return { routing: await readConfig('audio_routing.json') }; }
