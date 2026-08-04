/**
 * POST /api/upload
 * Multipart form: one or more file fields + type field (media | sample).
 * Supports multiple files via repeated "file" fields or "files[]" array.
 * Saves uploaded files to media/ or samples/ directory.
 * MP3 files are converted to WAV using ffmpeg (must be installed on the Pi).
 *
 * Response: { results: [{ ok, name, path, error? }] }
 */
import { json } from '@sveltejs/kit';
import { writeFile, mkdir, unlink, statfs } from 'fs/promises';
import path from 'path';
import { MEDIA_DIR, SAMPLES_DIR } from '$lib/config.js';
import { exec } from 'child_process';
import { promisify } from 'util';

const execAsync = promisify(exec);
const MAX_FILE_SIZE = 100 * 1024 * 1024;        // 100 MB
const MIN_DISK_MB  = 500;                        // require 500 MB free

async function saveOneFile(file, targetDir, isMedia) {
  if (!file || !(file instanceof File)) {
    return { ok: false, error: 'invalid file' };
  }

  if (file.size > MAX_FILE_SIZE) {
    return { ok: false, error: `File too large (max ${MAX_FILE_SIZE / 1024 / 1024} MB)` };
  }

  const originalName = file.name;
  const ext = path.extname(originalName).toLowerCase();
  const baseName = path.basename(originalName, ext);
  const arrayBuffer = await file.arrayBuffer();
  const buffer = Buffer.from(arrayBuffer);
  let savedPath;

  if ((ext === '.mp3' || ext === '.wav') && isMedia) {
    const tmpPath = path.join(targetDir, originalName);
    const wavPath = path.join(targetDir, `${baseName}.wav`);
    await writeFile(tmpPath, buffer);
    try {
      await execAsync(`ffmpeg -y -i "${tmpPath}" -ar 48000 -ac 2 -f wav "${wavPath}"`);
      await unlink(tmpPath).catch(() => {});
      savedPath = wavPath;
    } catch (err) {
      console.error('[UPLOAD] ffmpeg conversion failed:', err.message);
      savedPath = tmpPath;
    }
  } else {
    savedPath = path.join(targetDir, originalName);
    await writeFile(savedPath, buffer);
  }

  console.log(`[UPLOAD] Saved: ${savedPath}`);
  return { ok: true, name: path.basename(savedPath), path: savedPath };
}

export async function POST({ request }) {
  const formData = await request.formData();
  const type = formData.get('type') ?? 'media';
  const isMedia = type !== 'sample';
  const targetDir = isMedia ? MEDIA_DIR : SAMPLES_DIR;

  // Collect all files — supports both single "file" and multiple "file" / "files[]"
  const files = [];
  for (const [, value] of formData) {
    if (value instanceof File) {
      files.push(value);
    }
  }

  if (files.length === 0) {
    return json({ error: 'no file uploaded' }, { status: 400 });
  }

  await mkdir(targetDir, { recursive: true });

  // Disk space check (once)
  try {
    const stat = await statfs(targetDir);
    const freeMB = (stat.bsize * stat.bfree) / 1024 / 1024;
    if (freeMB < MIN_DISK_MB) {
      return json({
        error: `Low disk space (${Math.round(freeMB)} MB free, need ${MIN_DISK_MB} MB)`
      }, { status: 507 });
    }
  } catch {}

  // Process each file
  const results = [];
  for (const file of files) {
    const result = await saveOneFile(file, targetDir, isMedia);
    results.push(result);
  }

  return json({ results });
}
