/**
 * POST /api/upload/cancel   body: { name }
 * Discards a partial chunked upload (removes the .part spool file).
 */
import { json } from '@sveltejs/kit';
import { unlink } from 'fs/promises';
import path from 'path';
import { MEDIA_DIR } from '$lib/config.js';

const SPOOL = path.join(MEDIA_DIR, '.uploading');

export async function POST({ request }) {
  const { name } = await request.json().catch(() => ({}));
  const safe = path.basename(String(name ?? ''));
  if (!safe) return json({ error: 'invalid name' }, { status: 400 });
  try {
    await unlink(path.join(SPOOL, `${safe}.part`));
  } catch {}
  return json({ ok: true });
}
