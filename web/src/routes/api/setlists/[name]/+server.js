import { json } from '@sveltejs/kit';
import { readSetlist, writeSetlist, deleteSetlist } from '$lib/config.js';

export async function GET({ params }) {
  const data = await readSetlist(params.name);
  if (!data) return json({ error: 'not found' }, { status: 404 });
  return json(data);
}

export async function PUT({ params, request }) {
  const data = await request.json();
  await writeSetlist(params.name, data);
  return json({ ok: true });
}

export async function DELETE({ params }) {
  await deleteSetlist(params.name);
  return json({ ok: true });
}
