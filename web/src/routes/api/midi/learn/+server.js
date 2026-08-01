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
    // If empty object ({}), no event yet
    if (data.srcID === undefined || data.srcID === null) return null;
    if (data.srcID === -1) return null;
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

    // Check for conflicts: same srcID + type + value already mapped
    const conflictIdx = mappings.findIndex(
      (existing) =>
        existing.srcID === m.srcID &&
        existing.type === m.type &&
        existing.value === m.value
    );

    // Check if the action is already mapped elsewhere (duplicate action)
    const actionConflict = mappings.find(
      (existing) =>
        existing.action === m.action &&
        !(existing.srcID === m.srcID && existing.type === m.type && existing.value === m.value)
    );

    if (body.replace === true) {
      // Remove conflicting mapping
      if (conflictIdx >= 0) {
        const replaced = mappings[conflictIdx];
        mappings.splice(conflictIdx, 1);
        // Also remove any other mapping with the same action (disable old)
        for (let i = mappings.length - 1; i >= 0; i--) {
          if (mappings[i].action === m.action) {
            mappings.splice(i, 1);
          }
        }
      }
      // Add new mapping
      mappings.push({ srcID: m.srcID, type: m.type, value: m.value, action: m.action });
    } else {
      // Check for conflicts
      if (conflictIdx >= 0) {
        return json({
          ok: false,
          conflict: true,
          existing: mappings[conflictIdx],
          message: `This MIDI key is already mapped to "${mappings[conflictIdx].action}". Replace it?`
        });
      }
      if (actionConflict) {
        return json({
          ok: false,
          conflict: true,
          existing: actionConflict,
          message: `Action "${m.action}" is already mapped to ${actionConflict.type} ${actionConflict.value}. Replace it?`
        });
      }
      // No conflicts — add
      mappings.push({ srcID: m.srcID, type: m.type, value: m.value, action: m.action });
    }

    map.mappings = mappings;
    await writeConfig(MAP_FILE, map);

    // Tell SC to reload the MIDI action map
    sendOSC('/midi/reload');

    return json({ ok: true, saved: true });
  }

  return json({ ok: false, error: 'unknown action' });
}
