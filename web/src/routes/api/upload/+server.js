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

const MAX_FILE_SIZE = 100 * 1024 * 1024;        // 100 MB
const MIN_DISK_MB  = 500;                        // require 500 MB free
const ALLOWED_EXT = new Set(['.wav', '.flac', '.aiff', '.aif', '.mid', '.midi']);

async function saveOneFile(file) {
  if (!file || !(file instanceof File)) {
    return { ok: false, error: 'invalid file' };
  }
  if (file.size > MAX_FILE_SIZE) {
    return { ok: false, error: `File too large (max ${MAX_FILE_SIZE / 1024 / 1024} MB)` };
  }
  const ext = path.extname(file.name).toLowerCase();
  if (!ALLOWED_EXT.has(ext)) {
    return {
      ok: false,
      name: file.name,
      error: `Unsupported type "${ext}" — upload WAV/FLAC/AIFF audio and MID files`,
    };
  }
  const buffer = Buffer.from(await file.arrayBuffer());
  const savedPath = path.join(MEDIA_DIR, file.name);
  await writeFile(savedPath, buffer);
  console.log(`[UPLOAD] Saved: ${savedPath}`);
  return { ok: true, name: file.name, path: savedPath };
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
