import { listSetlists } from '$lib/config.js';
export async function load() { return { setlists: await listSetlists() }; }
