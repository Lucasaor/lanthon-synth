<script>
  export let data;
  let routing = data.routing ?? { vs: 'foh', click: 'iem', dica: 'iem', synth: 'foh' };

  const CHANNELS = ['foh', 'iem', 'both'];

  async function save() {
    await fetch('/api/config/audio_routing.json', {
      method: 'PUT',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(routing),
    });
    await fetch('/api/osc', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ address: '/config/routing_reload' }),
    });
    alert('Routing saved.');
  }
</script>

<h1>Output Routing</h1>
<p>Assign each audio stream to FOH (main speaker), IEM (monitor/click), or both.</p>

<div class="card">
  {#each Object.entries(routing) as [key, val]}
    <div class="row" style="margin-bottom:10px">
      <label style="width:80px; flex:none; text-transform:uppercase; font-weight:bold">{key}</label>
      {#each CHANNELS as ch}
        <label>
          <input type="radio" bind:group={routing[key]} value={ch} />
          {ch.toUpperCase()}
        </label>
      {/each}
    </div>
  {/each}
  <button class="primary" on:click={save}>Save Routing</button>
</div>

<div class="card">
  <h2>Channel Guide</h2>
  <ul>
    <li><strong>FOH</strong>: outputs 1–2 (main PA / house)</li>
    <li><strong>IEM</strong>: outputs 3–4 (monitor / in-ear)</li>
    <li><strong>BOTH</strong>: outputs 1–4</li>
  </ul>
</div>
