import { readConfig } from '$lib/config.js';
export async function load() {
  const cfg = await readConfig('pc_snapshots.json');
  return { snapshots: cfg?.snapshots ?? Array(16).fill(null) };
}
