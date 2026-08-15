/**
 * POST /api/engine/restart
 *
 * Restarts the playback engine:
 *  1. If the engine is online (fresh state.json heartbeat), an OSC
 *     /engine/restart command makes it exit non-zero, and systemd's
 *     Restart=on-failure brings it right back.
 *  2. If the engine is already dead, fall back to
 *     `sudo systemctl restart lanthon-engine` (the sudoers file installed
 *     by deploy/setup.sh permits this for the service user).
 */
import { json } from '@sveltejs/kit';
import { exec } from 'child_process';
import { promisify } from 'util';
import { readConfig } from '$lib/config.js';
import { sendOSC } from '$lib/osc.js';

const execAsync = promisify(exec);
const STALE_SEC = 15;
const SERVICE = 'lanthon-engine';

export async function POST() {
  const state = await readConfig('state.json') ?? {};
  const hb = Number(state.engineHeartbeat ?? 0);
  const online =
    Number.isFinite(hb) && hb > 0 && Date.now() / 1000 - hb < STALE_SEC;

  if (online) {
    sendOSC('/engine/restart');
    return json({ ok: true, method: 'osc' });
  }

  try {
    await execAsync(`sudo -n systemctl restart ${SERVICE}`, { timeout: 20000 });
    return json({ ok: true, method: 'systemctl' });
  } catch {
    return json(
      { ok: false, error: 'engine is offline and systemctl restart failed' },
      { status: 500 }
    );
  }
}
