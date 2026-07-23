/**
 * GET  /api/config/[name]   — read a config file
 * PUT  /api/config/[name]   — write a config file
 */
import { json } from '@sveltejs/kit';
import { readConfig, writeConfig } from '$lib/config.js';

const ALLOWED = ['midi_map.json', 'pads_worlde.json', 'audio_routing.json',
                 'apc_config.json', 'pc_snapshots.json'];

export async function GET({ params }) {
  if (!ALLOWED.includes(params.name)) return json({ error: 'forbidden' }, { status: 403 });
  const data = await readConfig(params.name);
  return json(data ?? {});
}

export async function PUT({ params, request }) {
  if (!ALLOWED.includes(params.name)) return json({ error: 'forbidden' }, { status: 403 });
  const data = await request.json();
  await writeConfig(params.name, data);
  return json({ ok: true });
}
