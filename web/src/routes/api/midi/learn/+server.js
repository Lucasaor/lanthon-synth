/**
 * GET  /api/midi/learn  → { active, event }
 * POST /api/midi/learn  body: { action: "start"|"stop"|"cancel" }
 *
 * Proxies MIDI learn mode OSC commands to SC and reads back the captured event.
 *
 * POST /api/midi/learn body: { action: "save", mapping: { srcID, type, value, action } }
 * Saves a new mapping to midi_map.json, checking for conflicts.
 */
import { json } from '@sveltejs/kit';
import { readConfig, writeConfig } from '$lib/config.js';
import { sendOSC } from '$lib/osc.js';
import fs from 'fs/promises';
import path from 'path';
import { CONFIG_DIR } from '$lib/config.js';

const LEARN_FILE = 'midi_learn.json';
const MAP_FILE   = 'midi_map.json';

/** Read the latest captured MIDI event from SC's learn file. */
async function readLearnEvent() {
  try {
    const raw = await fs.readFile(path.join(CONFIG_DIR, LEARN_FILE), 'utf-8');
    const data = JSON.parse(raw);
    // If empty object ({}), no event yet. Check for channel field (new format).
    if (data.chan === undefined || data.chan === null) return null;
    if (data.value === undefined) return null;
    return data;
  } catch {
    return null;
  }
}

export async function GET() {
  const event = await readLearnEvent();
  // We can't query SC's ~midiLearnActive directly, so we infer it
  // from the file: if we're polling and the file has a recent event,
  // we assume active.
  return json({ event });
}

export async function POST({ request }) {
  const body = await request.json().catch(() => ({}));

  // ── Learn mode control (forward to SC via OSC) ─────────────────────
  if (body.action === 'start') {
    sendOSC('/midi/learn/start');
    return json({ ok: true, active: true });
  }
  if (body.action === 'stop') {
    sendOSC('/midi/learn/stop');
    return json({ ok: true, active: false });
  }
  if (body.action === 'cancel') {
    sendOSC('/midi/learn/cancel');
    return json({ ok: true, active: false });
  }

  // ── Save a mapping ─────────────────────────────────────────────────
  if (body.action === 'save' && body.mapping) {
    const m = body.mapping;
    const map = await readConfig(MAP_FILE) ?? { mappings: [] };
    const mappings = map.mappings ?? [];

    // Only check for channel-level conflict: same chan + type + value already mapped.
    const conflictIdx = mappings.findIndex(
      (existing) =>
        existing.chan === m.chan &&
        existing.type === m.type &&
        existing.value === m.value
    );

    if (body.replace === true) {
      if (conflictIdx >= 0) {
        mappings.splice(conflictIdx, 1);
      }
      mappings.push({ chan: m.chan, type: m.type, value: m.value, action: m.action });
    } else {
      if (conflictIdx >= 0) {
        return json({
          ok: false,
          conflict: true,
          existing: mappings[conflictIdx],
          message: `This MIDI key is already mapped to "${mappings[conflictIdx].action}". Replace it?`
        });
      }
      mappings.push({ chan: m.chan, type: m.type, value: m.value, action: m.action });
    }

    map.mappings = mappings;
    await writeConfig(MAP_FILE, map);

    // Tell SC to reload the MIDI action map
    sendOSC('/midi/reload');

    return json({ ok: true, saved: true });
  }

  return json({ ok: false, error: 'unknown action' });
}
