/**
 * GET /api/devices
 *
 * Returns the live device snapshot the playback engine refreshes every
 * 5 s (config/devices.json): connected audio outputs + MIDI in/out ports.
 * The routing screen polls this to reflect hot-plug changes without a
 * restart.
 */
import { json } from '@sveltejs/kit';
import { readConfig } from '$lib/config.js';

export async function GET() {
  const devices = await readConfig('devices.json') ?? {};
  return json({
    audio: devices.audio ?? [],
    midi_out: devices.midi_out ?? [],
    midi_in: devices.midi_in ?? [],
    default_audio: devices.default_audio ?? null,
    default_midi_out: devices.default_midi_out ?? null,
  });
}
