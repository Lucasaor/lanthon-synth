/**
 * lib/config.js — Read/write JSON config files in the project's config/ dir.
 * Runs server-side only (used in +server.js API routes).
 */

import fs from 'fs/promises';
import path from 'path';

// Project root is two levels above web/src/lib/
const PROJECT_ROOT = path.resolve(import.meta.dirname, '../../../..');

export const CONFIG_DIR   = path.join(PROJECT_ROOT, 'config');
export const SETLISTS_DIR = path.join(PROJECT_ROOT, 'setlists');
export const MEDIA_DIR    = path.join(PROJECT_ROOT, 'media');
export const SAMPLES_DIR  = path.join(PROJECT_ROOT, 'samples');

/** Read and parse a JSON config file. Returns null if file doesn't exist. */
export async function readConfig(filename) {
  const filepath = path.join(CONFIG_DIR, filename);
  try {
    const content = await fs.readFile(filepath, 'utf-8');
    return JSON.parse(content);
  } catch {
    return null;
  }
}

/** Write a JSON config file, creating parent directory if needed. */
export async function writeConfig(filename, data) {
  await fs.mkdir(CONFIG_DIR, { recursive: true });
  const filepath = path.join(CONFIG_DIR, filename);
  await fs.writeFile(filepath, JSON.stringify(data, null, 2), 'utf-8');
}

/** List all .json files in the setlists directory. */
export async function listSetlists() {
  try {
    await fs.mkdir(SETLISTS_DIR, { recursive: true });
    const files = await fs.readdir(SETLISTS_DIR);
    return files.filter((f) => f.endsWith('.json')).map((f) => f.replace('.json', ''));
  } catch {
    return [];
  }
}

/** Read a single setlist JSON file by name. */
export async function readSetlist(name) {
  try {
    const content = await fs.readFile(path.join(SETLISTS_DIR, `${name}.json`), 'utf-8');
    return JSON.parse(content);
  } catch {
    return null;
  }
}

/** Write a setlist JSON file. */
export async function writeSetlist(name, data) {
  await fs.mkdir(SETLISTS_DIR, { recursive: true });
  await fs.writeFile(
    path.join(SETLISTS_DIR, `${name}.json`),
    JSON.stringify(data, null, 2),
    'utf-8'
  );
}

/** Delete a setlist file. */
export async function deleteSetlist(name) {
  try {
    await fs.unlink(path.join(SETLISTS_DIR, `${name}.json`));
  } catch {}
}

/** List uploaded media files. */
export async function listMedia() {
  try {
    await fs.mkdir(MEDIA_DIR, { recursive: true });
    return await fs.readdir(MEDIA_DIR);
  } catch {
    return [];
  }
}

/** List uploaded sample files. */
export async function listSamples() {
  try {
    await fs.mkdir(SAMPLES_DIR, { recursive: true });
    return await fs.readdir(SAMPLES_DIR);
  } catch {
    return [];
  }
}
