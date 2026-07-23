import { readConfig } from '$lib/config.js';
export async function load() { return { cfg: await readConfig('apc_config.json') }; }
