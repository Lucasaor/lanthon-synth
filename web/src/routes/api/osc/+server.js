/**
 * POST /api/osc
 * Body: { address: string, args?: any[] }
 * Forwards an OSC message to SuperCollider.
 */
import { json } from '@sveltejs/kit';
import { sendOSC } from '$lib/osc.js';

export async function POST({ request }) {
  const { address, args = [] } = await request.json();
  if (!address || typeof address !== 'string') {
    return json({ error: 'address required' }, { status: 400 });
  }
  sendOSC(address, ...args);
  return json({ ok: true });
}
