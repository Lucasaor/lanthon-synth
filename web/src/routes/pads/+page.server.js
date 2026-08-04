import { readConfig } from '$lib/config.js';

export async function load() {
  const cfg = await readConfig('apc_config.json');
  // If config is empty object or null, return null so client uses buildDefault()
  if (!cfg || (typeof cfg === 'object' && Object.keys(cfg).length === 0)) {
    return { cfg: null };
  }
  return { cfg };
}
