import { json } from '@sveltejs/kit';
import { readSetlist, writeSetlist, deleteSetlist, listSetlists } from '$lib/config.js';

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

/**
 * PATCH /api/setlists/[name]   body: { newName }
 * Renames the setlist file and its display name. 409 if the target name
 * is already taken; 400 for unsafe names.
 */
export async function PATCH({ params, request }) {
  const { newName } = await request.json().catch(() => ({}));
  const clean = String(newName ?? '').replace(/\.json$/i, '').trim();
  if (!clean || clean === '.' || clean === '..' ||
      /[\\/]/.test(clean) || clean.length > 64) {
    return json({ error: 'invalid name' }, { status: 400 });
  }
  if (clean === params.name) return json({ ok: true });

  const existing = await readSetlist(params.name);
  if (!existing) return json({ error: 'setlist not found' }, { status: 404 });

  const names = await listSetlists();
  if (names.includes(clean)) {
    return json({ error: `a setlist named "${clean}" already exists` }, { status: 409 });
  }

  existing.name = clean;
  await writeSetlist(clean, existing);
  await deleteSetlist(params.name);
  return json({ ok: true, name: clean });
}
