/**
 * POST /api/upload/chunk
 *
 * Chunked, disk-spooled upload — the only memory-safe way to move large
 * multichannel WAV renders onto the 512 MB Pi (buffering a whole ~200 MB
 * multipart body in RAM OOM-kills node — see the Aug 15 incident).
 *
 * The browser slices the file into small pieces and POSTs each chunk as a
 * raw binary body. Chunks are appended to media/.uploading/<name>.part and
 * renamed into media/ when the final chunk arrives.
 *
 * Headers:
 *   x-file-name    URL-encoded destination file name
 *   x-chunk-index  0-based chunk index
 *   x-chunk-total  total number of chunks
 *
 * Also: POST /api/upload/cancel  body { name }  — discards a partial upload.
 */
import { json } from '@sveltejs/kit';
import { mkdir, writeFile, appendFile, rename, statfs, unlink } from 'fs/promises';
import path from 'path';
import { MEDIA_DIR } from '$lib/config.js';

const SPOOL = path.join(MEDIA_DIR, '.uploading');
const MIN_DISK_MB = 500;
const MAX_FILE_MB = parseInt(process.env.LANTH0N_MAX_UPLOAD_MB ?? '1024', 10);
const MAX_CHUNKS = Math.ceil((MAX_FILE_MB * 1024 * 1024) / (64 * 1024)); // sanity cap

export async function POST({ request }) {
  const name = decodeURIComponent(request.headers.get('x-file-name') ?? '');
  const idx = parseInt(request.headers.get('x-chunk-index') ?? '', 10);
  const total = parseInt(request.headers.get('x-chunk-total') ?? '', 10);

  // Trim surrounding whitespace — filenames with leading/trailing spaces
  // are stored verbatim but engine.load_setlist() strips them, so a file
  // named " song.wav" could never be cued. Normalize at the upload edge.
  const safe = path.basename(name).trim();
  if (!safe || /[\\/]/.test(safe) || safe.startsWith('.') ||
      !Number.isInteger(idx) || !Number.isInteger(total) ||
      idx < 0 || total < 1 || idx >= total || total > MAX_CHUNKS) {
    return json({ error: 'invalid chunk request' }, { status: 400 });
  }

  const buf = Buffer.from(await request.arrayBuffer());
  const partPath = path.join(SPOOL, `${safe}.part`);
  const finalPath = path.join(MEDIA_DIR, safe);

  await mkdir(SPOOL, { recursive: true });

  if (idx === 0) {
    // disk-space check once, on the first chunk
    try {
      const stat = await statfs(MEDIA_DIR);
      const freeMB = (stat.bsize * stat.bfree) / 1024 / 1024;
      if (freeMB < MIN_DISK_MB) {
        return json({
          error: `Low disk space (${Math.round(freeMB)} MB free, need ${MIN_DISK_MB} MB)`
        }, { status: 507 });
      }
    } catch {}
    await writeFile(partPath, buf);   // fresh start (overwrites stale parts)
  } else {
    await appendFile(partPath, buf);
  }

  if (idx === total - 1) {
    await rename(partPath, finalPath);
    return json({ ok: true, done: true, name: safe });
  }
  return json({ ok: true, done: false, index: idx + 1 });
}
