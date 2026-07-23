/**
 * lib/osc.js — OSC client that sends messages to SuperCollider (sclang).
 * Uses the node-osc package. Runs server-side only.
 *
 * SC must have an OSCdef listening on SC_OSC_PORT (default 57120 — the
 * standard sclang port). The backtrack.scd file registers OSCdefs for
 * /backtrack/* and /config/* paths.
 */

import { Client } from 'node-osc';

const SC_HOST = process.env.SC_HOST ?? '127.0.0.1';
const SC_PORT = parseInt(process.env.SC_PORT ?? '57120', 10);

let _client = null;

function getClient() {
  if (!_client) {
    _client = new Client(SC_HOST, SC_PORT);
  }
  return _client;
}

/**
 * Send an OSC message to SuperCollider.
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
