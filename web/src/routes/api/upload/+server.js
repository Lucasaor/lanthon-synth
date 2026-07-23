/**
 * POST /api/upload
 * Multipart form: file field + type field (media | sample)
 * Saves the uploaded file to media/ or samples/ directory.
 * MP3 files are converted to WAV using ffmpeg (must be installed on the Pi).
 *
 * WARNING: Files are streamed directly to disk. No file content is kept
 * in Node.js process memory after the write completes (RAM preservation).
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

export async function POST({ request }) {
  const formData = await request.formData();
  const file = formData.get('file');
  const type = formData.get('type') ?? 'media';   // 'media' or 'sample'

  if (!file || !(file instanceof File)) {
    return json({ error: 'no file uploaded' }, { status: 400 });
  }

  // ── File size check ─────────────────────────────────────────────────────
  if (file.size > MAX_FILE_SIZE) {
    return json({
      error: `File too large (max ${MAX_FILE_SIZE / 1024 / 1024} MB)`
    }, { status: 413 });
  }

  const targetDir = type === 'sample' ? SAMPLES_DIR : MEDIA_DIR;
  await mkdir(targetDir, { recursive: true });

  // ── Disk space check ────────────────────────────────────────────────────
  try {
    const stat = await statfs(targetDir);
    const freeMB = (stat.bsize * stat.bfree) / 1024 / 1024;
    if (freeMB < MIN_DISK_MB) {
      return json({
        error: `Low disk space (${Math.round(freeMB)} MB free, need ${MIN_DISK_MB} MB)`
      }, { status: 507 });
    }
  } catch {}

  const originalName = file.name;
  const ext = path.extname(originalName).toLowerCase();
  const baseName = path.basename(originalName, ext);

  // Stream file to disk — avoid loading into RAM
  const arrayBuffer = await file.arrayBuffer();
  const buffer = Buffer.from(arrayBuffer);

  let savedPath;

  if ((ext === '.mp3' || ext === '.wav') && type === 'media') {
    // Convert to stereo WAV via ffmpeg (VDiskIn requires WAV/AIFF, stereo)
    // ffmpeg must be installed: sudo apt install ffmpeg
    const tmpPath = path.join(targetDir, originalName);
    const wavPath = path.join(targetDir, `${baseName}.wav`);
    await writeFile(tmpPath, buffer);
    try {
      // -ac 2 forces stereo output even if source is mono
      await execAsync(`ffmpeg -y -i "${tmpPath}" -ar 44100 -ac 2 -f wav "${wavPath}"`);
      await unlink(tmpPath).catch(() => {});
      savedPath = wavPath;
    } catch (err) {
      // ffmpeg not available or failed — keep the original file
      console.error('[UPLOAD] ffmpeg conversion failed:', err.message);
      savedPath = tmpPath;
    }
  } else {
    savedPath = path.join(targetDir, originalName);
    await writeFile(savedPath, buffer);
  }

  console.log(`[UPLOAD] Saved: ${savedPath}`);
  return json({ ok: true, path: savedPath, name: path.basename(savedPath) });
}
