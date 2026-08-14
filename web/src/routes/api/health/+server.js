/**
 * GET /api/health
 *
 * Checks whether the playback engine is alive by reading the heartbeat
 * timestamp the engine refreshes in config/state.json every 5 s.
 * A heartbeat older than 15 s means the engine is offline.
 */
import { json } from '@sveltejs/kit';
import { readConfig } from '$lib/config.js';

const STALE_SEC = 15;

export async function GET() {
  const state = await readConfig('state.json') ?? {};
  const hb = Number(state.engineHeartbeat ?? 0);
  const age = Date.now() / 1000 - hb;
  const online = Number.isFinite(hb) && hb > 0 && age >= 0 && age < STALE_SEC;
  return json({ ok: online, ageSec: Math.round(age) }, { status: online ? 200 : 503 });
}
