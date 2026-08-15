/**
 * POST /api/engine/restart
 *
 * Restarts the playback engine:
 *  1. If the engine is online (fresh state.json heartbeat), an OSC
 *     /engine/restart command makes it exit non-zero, and systemd's
 *     Restart=on-failure brings it right back. The endpoint then waits a
 *     few seconds and confirms a NEW heartbeat — if none appeared (the
 *     engine died right before the command landed), it falls through.
 *  2. Fallback: `sudo systemctl restart lanthon-engine` (the sudoers file
 *     installed by deploy/setup.sh permits this for the service user) —
 *     covers a dead or unresponsive engine.
 */
import { json } from '@sveltejs/kit';
import { exec } from 'child_process';
import { promisify } from 'util';
import { readConfig } from '$lib/config.js';
import { sendOSC } from '$lib/osc.js';

const execAsync = promisify(exec);
const STALE_SEC = 15;
const SERVICE = 'lanthon-engine';
const VERIFY_MS = 6000;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export async function POST() {
  const state = await readConfig('state.json') ?? {};
  const hb = Number(state.engineHeartbeat ?? 0);
  const online =
    Number.isFinite(hb) && hb > 0 && Date.now() / 1000 - hb < STALE_SEC;

  if (online) {
    sendOSC('/engine/restart');
    await sleep(VERIFY_MS);
    const after = await readConfig('state.json') ?? {};
    const hbAfter = Number(after.engineHeartbeat ?? 0);
    if (Number.isFinite(hbAfter) && hbAfter > hb) {
      // a fresh heartbeat appeared → the restarted engine is up
      return json({ ok: true, method: 'osc' });
    }
    // heartbeat did not advance: the engine died before the command landed
  }

  try {
    await execAsync(`sudo -n systemctl restart ${SERVICE}`, { timeout: 20000 });
    return json({ ok: true, method: 'systemctl' });
  } catch {
    return json(
      { ok: false, error: 'restart failed — engine offline and systemctl unavailable' },
      { status: 500 }
    );
  }
}
