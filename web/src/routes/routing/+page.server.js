import { readConfig } from '$lib/config.js';

const DEFAULTS = {
  clock_device: 'auto',
  tracks: {
    playback_l: { device: 'auto', channel: 1 },
    playback_r: { device: 'auto', channel: 2 },
    click: { device: 'auto', channel: 3 },
    cue: { device: 'auto', channel: 4 },
    timecode: { device: 'auto', channel: 5, enabled: false },
    midi_automation: { device: 'auto' },
  },
};

export async function load() {
  const routing = { ...DEFAULTS, ...(await readConfig('audio_routing.json') ?? {}) };
  routing.tracks = { ...DEFAULTS.tracks, ...(routing.tracks ?? {}) };
  const devices = await readConfig('devices.json') ?? {};
  return { routing, devices };
}
