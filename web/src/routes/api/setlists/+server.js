/**
 * GET  /api/setlists            — list all setlists
 * POST /api/setlists            — create a new setlist
 *
 * GET  /api/setlists/[name]     — read a setlist
 * PUT  /api/setlists/[name]     — update a setlist
 * DELETE /api/setlists/[name]   — delete a setlist
 */
import { json } from '@sveltejs/kit';
import { listSetlists, readSetlist, writeSetlist, deleteSetlist } from '$lib/config.js';

export async function GET() {
  const names = await listSetlists();
  return json(names);
}

export async function POST({ request }) {
  const { name, data } = await request.json();
  if (!name) return json({ error: 'name required' }, { status: 400 });
  await writeSetlist(name, data ?? { name, songs: [] });
  return json({ ok: true });
}
