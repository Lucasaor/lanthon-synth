<script>
  import { onMount } from 'svelte';

  export let data;

  let activeSetlist = data.activeSetlist ?? '(none)';
  let playing = data.playing ?? false;
  let songName = data.songName ?? '';
  let artist = data.artist ?? '';
  let bpm = data.bpm ?? 0;
  let busy = false;   // true during OSC request

  onMount(() => {
    // Poll state every 3 seconds to stay in sync with SC
    const poll = setInterval(async () => {
      try {
        const r = await fetch('/api/state');
        if (r.ok) {
          const s = await r.json();
          activeSetlist = s.activeSetlist ?? '(none)';
          playing = s.playing ?? false;
          songName = s.songName ?? '';
          artist = s.artist ?? '';
          bpm = s.bpm ?? 0;
        }
      } catch {}
    }, 3000);
    return () => clearInterval(poll);
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
</script>

<h1>Dashboard</h1>

{#if playing}
  <div class="status-banner playing">
    🔊 LIVE — <strong>{songName || 'Playing...'}</strong>
    {#if artist}by {artist}{/if}
    {#if bpm > 0} @ {bpm} BPM{/if}
    — Setlist: {activeSetlist}
  </div>
{:else}
  <div class="status-banner stopped">
    ⏸ Ready — Setlist: <strong>{activeSetlist}</strong>
  </div>
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
    Play/Stop/Prev/Next buttons send OSC commands to the SC engine.
    <strong>Load a setlist first</strong> before pressing Play.
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
  <h2>Quick Links</h2>
  <div class="row">
    <a href="/files"><button>Upload Files</button></a>
    <a href="/setlists"><button>Manage Setlists</button></a>
    <a href="/pads"><button>APC Pads</button></a>
    <a href="/worlde"><button>Worlde Pads</button></a>
  </div>
</div>

<style>
  .transport-row {
    display: flex;
    gap: 12px;
    align-items: center;
    flex-wrap: wrap;
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
</style>