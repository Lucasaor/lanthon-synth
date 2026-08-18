/**
 * POST /api/upload
 * Multipart form: one or more file fields.
 * Accepts per-song media only: WAV/FLAC/AIFF audio + MID (.mid/.midi).
 * Files are saved verbatim to media/ (no conversion — the engine streams
 * whatever soundfile supports; channel layout must match the documented
 * L, R, Click, Cue (+Timecode) convention).
 *
 * Response: { results: [{ ok, name, path, error? }] }
 */
import { json } from '@sveltejs/kit';
import { writeFile, mkdir, statfs } from 'fs/promises';
import path from 'path';
import { MEDIA_DIR } from '$lib/config.js';

const MAX_FILE_SIZE = (parseInt(process.env.LANTH0N_MAX_UPLOAD_MB ?? '1024', 10)) * 1024 * 1024;  // default 1 GB
const MIN_DISK_MB  = 500;                        // require 500 MB free
const ALLOWED_EXT = new Set(['.wav', '.flac', '.aiff', '.aif', '.m4a', '.mp4', '.aac', '.mid', '.midi']);

async function saveOneFile(file) {
  if (!file || !(file instanceof File)) {
    return { ok: false, error: 'invalid file' };
  }
  if (!file.size) {
    return {
      ok: false,
      name: file.name,
      error: 'File is empty (0 bytes) — check the source file and re-upload',
    };
  }
  if (file.size > MAX_FILE_SIZE) {
    return { ok: false, error: `File too large (max ${MAX_FILE_SIZE / 1024 / 1024} MB)` };
  }
  const ext = path.extname(file.name).toLowerCase();
  if (!ALLOWED_EXT.has(ext)) {
    return {
      ok: false,
      name: file.name,
      error: `Unsupported type "${ext}" — upload WAV/M4A/FLAC/AIFF audio and MID files`,
    };
  }
  // Normalize the file name: trim surrounding whitespace (leading/trailing
  // spaces break engine cueing — engine.load_setlist() strips them) and
  // ensure it stays inside media/.
  const safeName = path.basename(file.name).trim();
  if (!safeName || safeName.startsWith('.')) {
    return { ok: false, name: file.name, error: 'invalid file name' };
  }
  const buffer = Buffer.from(await file.arrayBuffer());
  const savedPath = path.join(MEDIA_DIR, safeName);
  await writeFile(savedPath, buffer);
  console.log(`[UPLOAD] Saved: ${savedPath}`);
  return { ok: true, name: safeName, path: savedPath };
}

export async function POST({ request }) {
  const formData = await request.formData();

  const files = [];
  for (const [, value] of formData) {
    if (value instanceof File) {
      files.push(value);
    }
  }
  if (files.length === 0) {
    return json({ error: 'no file uploaded' }, { status: 400 });
  }

  await mkdir(MEDIA_DIR, { recursive: true });

  // Disk space check (once)
  try {
    const stat = await statfs(MEDIA_DIR);
    const freeMB = (stat.bsize * stat.bfree) / 1024 / 1024;
    if (freeMB < MIN_DISK_MB) {
      return json({
        error: `Low disk space (${Math.round(freeMB)} MB free, need ${MIN_DISK_MB} MB)`
      }, { status: 507 });
    }
  } catch {}

  const results = [];
  for (const file of files) {
    results.push(await saveOneFile(file));
  }
  return json({ results });
}
