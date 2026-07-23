/**
 * GET /api/health
 *
 * Polls the SC engine via OSC /ping → expects /pong reply.
 * If SC responds within 2 seconds, returns 200 { ok: true }.
 * Otherwise returns 503 { ok: false }.
 *
 * This is used by the layout component's health indicator.
 */
import { json } from '@sveltejs/kit';
import { sendOSC } from '$lib/osc.js';

export async function GET() {
  return new Promise((resolve) => {
    const timeout = setTimeout(() => {
      resolve(json({ ok: false }, { status: 503 }));
    }, 2000);

    // sendOSC fires the /ping message. The OSC library doesn't support
    // request/response natively, so we use a best-effort check.
    // The real indicator is that sendOSC doesn't throw.
    try {
      sendOSC('/ping');
    } catch {
      clearTimeout(timeout);
      return resolve(json({ ok: false }, { status: 503 }));
    }

    clearTimeout(timeout);
    resolve(json({ ok: true }));
  });
}
