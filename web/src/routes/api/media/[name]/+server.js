/**
 * DELETE /api/media/[name]
 *
 * Deletes an uploaded media file from the media/ directory.
 * Refuses to delete files still referenced by a setlist (409 with the
 * referencing setlist names) so setlists never silently break.
 */
import { json } from '@sveltejs/kit';
import { unlink, access } from 'fs/promises';
import path from 'path';
import { MEDIA_DIR, listSetlists, readSetlist } from '$lib/config.js';

/** Resolve a URL-encoded file name safely inside media/ (no traversal). */
function safePath(name) {
  const base = path.basename(String(name ?? ''));
  if (!base || base === '.' || base === '..') return null;
  return path.join(MEDIA_DIR, base);
}

async function referencingSetlists(filename) {
  const refs = [];
  for (const name of await listSetlists()) {
    const data = await readSetlist(name);
    const songs = data?.songs ?? [];
    if (songs.some((s) => s.wav === filename || s.mid === filename)) {
      refs.push(name);
    }
  }
  return refs;
}

export async function DELETE({ params }) {
  const filepath = safePath(params.name);
  if (!filepath) {
    return json({ error: 'invalid file name' }, { status: 400 });
  }
  const filename = path.basename(filepath);

  try {
    await access(filepath);
  } catch {
    return json({ error: 'file not found' }, { status: 404 });
  }

  const refs = await referencingSetlists(filename);
  if (refs.length) {
    return json(
      {
        error: `referenced by setlist(s): ${refs.join(', ')} — remove it from the setlist first`,
        referencing: refs,
      },
      { status: 409 }
    );
  }

  await unlink(filepath);
  return json({ ok: true });
}
