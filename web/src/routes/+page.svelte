<script>
  import { onMount } from 'svelte';

  export let data;

  let activeSetlist = data.activeSetlist ?? '(none)';
  let playing = data.playing ?? false;
  let engineState = data.state ?? 'stopped';
  let songName = data.songName ?? '';
  let artist = data.artist ?? '';
  let tuning = data.tuning ?? '';
  let positionSec = data.positionSec ?? 0;
  let durationSec = data.durationSec ?? 0;
  let seekSec = data.seekSec ?? null;
  let cueError = data.cueError ?? null;
  let fetchedAt = Date.now();
  let tickNow = Date.now();
  let scrubPos = null;   // non-null while dragging the trackbar
  let seekText = '';
  let seekMsg = '';
  let busy = false;   // true during OSC request

  // Position shown on the trackbar: interpolate between polls while
  // playing; honour the scrubber while dragging.
  $: shownPos = scrubPos ?? (playing
    ? Math.min(durationSec || 0, positionSec + (tickNow - fetchedAt) / 1000)
    : positionSec);

  function fmt(sec) {
    sec = Math.max(0, Math.floor(sec ?? 0));
    const h = Math.floor(sec / 3600);
    const m = Math.floor((sec % 3600) / 60);
    const s = sec % 60;
    const mm = String(m).padStart(2, '0');
    const ss = String(s).padStart(2, '0');
    return h > 0 ? `${h}:${mm}:${ss}` : `${m}:${ss}`;
  }

  onMount(() => {
    // Poll state every second to stay in sync with the engine
    const poll = setInterval(async () => {
      try {
        const r = await fetch('/api/state');
        if (r.ok) {
          const s = await r.json();
          activeSetlist = s.activeSetlist ?? '(none)';
          playing = s.playing ?? false;
          engineState = s.state ?? 'stopped';
          songName = s.songName ?? '';
          artist = s.artist ?? '';
          tuning = s.tuning ?? '';
          positionSec = s.positionSec ?? 0;
          durationSec = s.durationSec ?? 0;
          seekSec = s.seekSec ?? null;
          cueError = s.cueError ?? null;
          fetchedAt = Date.now();
          tickNow = Date.now();
        }
      } catch {}
    }, 1000);
    // tick the interpolated position 4×/s
    const ticker = setInterval(() => { tickNow = Date.now(); }, 250);
    return () => { clearInterval(poll); clearInterval(ticker); };
  });

  async function sendOSC(address, args = []) {
    busy = true;
    try {
      await fetch('/api/osc', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ address, args }),
      });
    } finally {
      busy = false;
    }
  }

  async function loadSetlist(name) {
    if (!name || name === '(none)') return;
    await sendOSC('/backtrack/load', [name]);
    activeSetlist = name;
  }

  async function play() {
    await sendOSC('/backtrack/play');
    playing = true;
  }

  async function stop() {
    await sendOSC('/backtrack/stop');
    playing = false;
  }

  async function prev() { await sendOSC('/backtrack/prev'); }
  async function next() { await sendOSC('/backtrack/next'); }

  // ---- seek ----------------------------------------------------------

  async function seekTo(sec) {
    sec = Math.max(0, Math.min(sec, durationSec || sec));
    await sendOSC('/backtrack/seek', [sec]);
    positionSec = sec;
    seekSec = sec;
    fetchedAt = Date.now();
    tickNow = Date.now();
  }

  async function seekBy(delta) {
    await seekTo(shownPos + delta);
  }

  function parseTime(text) {
    const t = String(text ?? '').trim().replace(',', '.');
    if (!t) return null;
    if (t.includes(':')) {
      const parts = t.split(':');
      if (parts.length > 3 || parts.some((p) => p.trim() === '' || isNaN(Number(p)))) {
        return null;
      }
      let sec = 0;
      for (const p of parts) sec = sec * 60 + Number(p);
      return sec;
    }
    const v = parseFloat(t);
    return Number.isFinite(v) ? v : null;
  }

  async function submitSeek() {
    const sec = parseTime(seekText);
    if (sec === null) {
      seekMsg = `Invalid time "${seekText}" — use m:ss (e.g. 1:54)`;
      return;
    }
    await seekTo(sec);
    seekMsg = `Seek to ${fmt(sec)}`;
    seekText = '';
  }

  function onScrub(e) {
    scrubPos = Number(e.currentTarget.value);
  }

  async function commitScrub(e) {
    const sec = Number(e.currentTarget.value);
    scrubPos = null;
    await seekTo(sec);
  }

  let restarting = false;
  let restartMsg = '';

  async function restartEngine() {
    if (!confirm('Restart the playback engine? Playback will stop for a few seconds.')) return;
    restarting = true;
    restartMsg = 'Restarting engine…';
    try {
      const r = await fetch('/api/engine/restart', { method: 'POST' });
      const d = await r.json();
      restartMsg = r.ok
        ? `✓ Engine restarting (${d.method}) — back in a few seconds`
        : `✗ ${d.error ?? 'restart failed'}`;
    } catch {
      restartMsg = '✗ Request failed';
    }
    restarting = false;
  }
</script>

<h1>Dashboard</h1>

{#if playing}
  <div class="status-banner playing">
    🔊 LIVE — <strong>{songName || 'Playing...'}</strong>
    {#if artist}by {artist}{/if}
    {#if tuning} — {tuning}{/if}
    — Setlist: {activeSetlist}
  </div>
{:else}
  <div class="status-banner stopped">
    {#if songName}
      ⏸ Ready — <strong>{songName}</strong>
      {#if artist} by {artist}{/if}
      {#if tuning} — {tuning}{/if}
      — Setlist: <strong>{activeSetlist}</strong>
    {:else}
      ⏸ Ready — Setlist: <strong>{activeSetlist}</strong>
      <span style="color:#777"> (no song cued)</span>
    {/if}
  </div>
  {#if cueError}
    <div class="status-banner error">⚠ {cueError}</div>
  {/if}
{/if}

<div class="card">
  <h2>Transport</h2>
  <div class="transport-row">
    <button class="primary" style="font-size:1.4rem; padding:12px 28px"
      on:click={play} disabled={busy || activeSetlist === '(none)'}>
      {busy ? '…' : '▶'}
    </button>
    <button style="font-size:1.2rem; padding:10px 22px"
      on:click={stop} disabled={busy}>
      {busy ? '…' : '■'}
    </button>
    <button style="font-size:1.2rem; padding:10px 18px"
      on:click={prev} disabled={busy}>
      {busy ? '…' : '⏮'}
    </button>
    <button style="font-size:1.2rem; padding:10px 18px"
      on:click={next} disabled={busy}>
      {busy ? '…' : '⏭'}
    </button>
  </div>
  <p style="color:#888; margin-top:8px; font-size:0.85rem">
    Play/Stop/Prev/Next send commands to the playback engine (same action path
    as the physical MIDI controllers).
    <strong>Load a setlist first</strong> before pressing Play.
    Engine state: <strong>{engineState}</strong>
  </p>
</div>

<div class="card">
  <h2>Position / Seek</h2>
  <div class="seek-row">
    <span class="mono">{fmt(shownPos)}</span>
    <input type="range" min="0" max={Math.max(1, Math.ceil(durationSec || 1))} step="1"
      value={shownPos}
      disabled={busy || !(durationSec > 0)}
      on:input={onScrub}
      on:change={commitScrub}
      title="Seek within the song"
    />
    <span class="mono">{fmt(durationSec)}</span>
  </div>
  <div class="row" style="margin-top:10px">
    <button on:click={() => seekBy(-5)} disabled={busy || !(durationSec > 0)}
      title="Seek 5 seconds back">⏪ −5s</button>
    <button on:click={() => seekBy(5)} disabled={busy || !(durationSec > 0)}
      title="Seek 5 seconds forward">+5s ⏩</button>
    <input type="text" bind:value={seekText} placeholder="m:ss (e.g. 1:54)"
      style="width:130px"
      disabled={busy || !(durationSec > 0)}
      on:keydown={(e) => e.key === 'Enter' && submitSeek()}
    />
    <button class="primary" on:click={submitSeek} disabled={busy || !(durationSec > 0)}>
      {busy ? '…' : 'Seek'}
    </button>
  </div>
  {#if seekMsg}
    <p style="color:#8f8; margin:8px 0 0; font-size:0.85rem">{seekMsg}</p>
  {/if}
  {#if !playing && seekSec !== null}
    <p style="color:#c90; margin:8px 0 0; font-size:0.85rem">
      ⏯ Next play starts at <strong>{fmt(seekSec)}</strong> — press Stop again to
      start from the beginning.
    </p>
  {/if}
  <p style="color:#888; margin:8px 0 0; font-size:0.8rem">
    Drag the bar, type a time (m:ss), or use ±5 s. Seek is also mappable from MIDI
    (<code>btSeekFwd</code> / <code>btSeekBack</code>) and works while playing or stopped.
  </p>
</div>

<div class="card">
  <h2>Load Setlist</h2>
  <div class="row">
    <select bind:value={activeSetlist}>
      <option value="(none)">(none)</option>
      {#each data.setlists as s}
        <option value={s}>{s}</option>
      {/each}
    </select>
    <button class="primary" on:click={() => loadSetlist(activeSetlist)}
      disabled={busy || activeSetlist === '(none)'}>
      {busy ? 'Loading…' : 'Load to Rig'}
    </button>
  </div>
</div>

<div class="card">
  <h2>Engine</h2>
  <div class="row">
    <button class="danger" on:click={restartEngine} disabled={restarting}>
      {restarting ? 'Restarting…' : '🔄 Restart Engine'}
    </button>
    {#if restartMsg}<span style="color:#8f8; font-size:0.9rem">{restartMsg}</span>{/if}
  </div>
  <p style="color:#888; margin:0; font-size:0.8rem">
    Stops playback and restarts the playback engine process (also mappable to a MIDI CC).
  </p>
</div>

<div class="card">
  <h2>Quick Links</h2>
  <div class="row">
    <a href="/files"><button>Upload Files</button></a>
    <a href="/setlists"><button>Manage Setlists</button></a>
    <a href="/midi"><button>MIDI Map</button></a>
    <a href="/routing"><button>Routing</button></a>
  </div>
</div>

<style>
  .transport-row {
    display: flex;
    gap: 12px;
    align-items: center;
    flex-wrap: wrap;
  }
  .seek-row {
    display: flex;
    gap: 12px;
    align-items: center;
  }
  .seek-row input[type="range"] {
    flex: 1;
    accent-color: #4a6;
  }
  .mono {
    font-family: monospace;
    font-size: 0.95rem;
  }
  .status-banner {
    padding: 10px 16px;
    border-radius: 6px;
    margin-bottom: 16px;
    font-size: 1.05rem;
  }
  .status-banner.playing {
    background: #1a3a1a;
    border: 1px solid #4a6;
    color: #8f8;
  }
  .status-banner.stopped {
    background: #1a1a2e;
    border: 1px solid #446;
    color: #aac;
  }
  .status-banner.error {
    background: #3a1a1a;
    border: 1px solid #a44;
    color: #f99;
  }
</style>