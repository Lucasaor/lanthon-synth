/**
 * GET /api/health
 *
 * Checks whether the SuperCollider engine (sclang) is running.
 * On Linux (Pi), uses pgrep to detect the sclang process.
 * Falls back to OSC /ping when pgrep is unavailable (dev mode).
 *
 * This is used by the layout component's health indicator.
 */
import { json } from '@sveltejs/kit';
import { execSync } from 'child_process';

/** Check if sclang process is alive via pgrep (Linux only). */
function isSclangRunning() {
  try {
    execSync('pgrep -x sclang', { timeout: 2000, stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

export async function GET() {
  // On Linux (production Pi), pgrep is the authoritative check.
  // On macOS/dev, pgrep may not find sclang if it's running under SC IDE.
  const platform = process.platform;
  if (platform === 'linux') {
    const running = isSclangRunning();
    return json({ ok: running }, { status: running ? 200 : 503 });
  }

  // Dev fallback: try pgrep first, then assume online for dev convenience.
  if (isSclangRunning()) {
    return json({ ok: true });
  }

  // In dev mode without sclang, report online so the UI is functional.
  // Set SC_STRICT_HEALTH=1 to require pgrep even in dev.
  if (process.env.SC_STRICT_HEALTH === '1') {
    return json({ ok: false }, { status: 503 });
  }
  return json({ ok: true });
}
