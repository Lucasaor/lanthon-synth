import { readConfig } from '$lib/config.js';

const ACTIONS = [
  { value: 'btPlay',  label: '▶ Play' },
  { value: 'btStop',  label: '■ Stop' },
  { value: 'btNext',  label: '⏭ Next Song' },
  { value: 'btPrev',  label: '⏮ Previous Song' },
  { value: 'btPanic', label: '🛑 Panic (All Notes Off)' },
];

export async function load() {
  const map = await readConfig('midi_map.json') ?? { mappings: [] };
  return {
    mappings: map.mappings ?? [],
    actions: ACTIONS,
  };
}
