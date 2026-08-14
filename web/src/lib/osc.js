/**
 * lib/osc.js — OSC client that sends commands to the playback engine
 * (Python process listening on ENGINE_PORT, default 57120). Uses the
 * node-osc package. Runs server-side only.
 *
 * The engine registers OSC handlers for /backtrack/*, /midi/* and
 * /config/* paths (engine/osc.py).
 */

import { Client } from 'node-osc';

const ENGINE_HOST = process.env.ENGINE_HOST ?? '127.0.0.1';
const ENGINE_PORT = parseInt(process.env.ENGINE_PORT ?? '57120', 10);

let _client = null;

function getClient() {
  if (!_client) {
    _client = new Client(ENGINE_HOST, ENGINE_PORT);
  }
  return _client;
}

/**
 * Send an OSC message to the playback engine.
 * @param {string} address  OSC path, e.g. '/backtrack/play'
 * @param {...*} args       Any additional typed args
 */
export function sendOSC(address, ...args) {
  try {
    getClient().send(address, ...args, (err) => {
      if (err) console.error('[OSC] send error:', err);
    });
  } catch (err) {
    console.error('[OSC] fatal error:', err);
  }
}
