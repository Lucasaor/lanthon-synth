<script>
  import { enhance } from '$app/forms';
  export let data;
  let selectedSetlist = data.setlists?.[0] ?? '';

  async function action(path) {
    await fetch('/api/osc', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ address: path }),
    });
  }

  async function loadSetlist() {
    await fetch('/api/osc', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ address: '/backtrack/load', args: [selectedSetlist] }),
    });
  }

  async function toggleNotesMode() {
    await fetch('/api/osc', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ address: '/notes_mode_toggle' }),
    });
  }
</script>

<h1>Dashboard</h1>

<div class="card">
  <h2>Backtrack Control</h2>
  <div class="row">
    <button class="primary" on:click={() => action('/backtrack/play')}>▶ PLAY</button>
    <button on:click={() => action('/backtrack/stop')}>■ STOP</button>
    <button on:click={() => action('/backtrack/prev')}>⏮ PREV</button>
    <button on:click={() => action('/backtrack/next')}>⏭ NEXT</button>
  </div>
</div>

<div class="card">
  <h2>APC Mini Notes Mode</h2>
  <div class="row">
    <button on:click={toggleNotesMode}>Toggle Notes Mode</button>
    <span style="color:#aaa">Fallback toggle if auto-detection fails</span>
  </div>
</div>

<div class="card">
  <h2>Setlist</h2>
  <p>Active: <strong>{data.activeSetlist ?? '(none loaded)'}</strong></p>
  <form method="POST" action="/api/osc" use:enhance>
    <div class="row">
      <select name="setlist" bind:value={selectedSetlist}>
        {#each data.setlists as s}
          <option value={s}>{s}</option>
        {/each}
      </select>
      <button on:click={() => loadSetlist()}>Load</button>
    </div>
  </form>
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

