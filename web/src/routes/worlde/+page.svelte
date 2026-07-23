<script>
  export let data;
  let pads = data.pads ?? Array.from({ length: 12 }, (_, i) => ({
    pad: i, file: '', note: 36 + i,
    attack: 0.005, decay: 0.1, sustain: 0.8, release: 0.3, amp: 0.8
  }));
  let samples = data.samples ?? [];

  async function save() {
    await fetch('/api/config/pads_worlde.json', {
      method: 'PUT',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ pads }),
    });
    alert('Worlde pad config saved.');
  }
</script>

<h1>Worlde Easypad 12 — Sample Configuration</h1>
<p>Assign a sample file and ADSR envelope to each of the 12 pads.</p>

<div class="card" style="display:grid; grid-template-columns:1fr 1fr; gap:10px">
  {#each pads as pad}
    <div class="card" style="padding:10px">
      <div style="font-weight:bold; color:#ffcc00; margin-bottom:6px">Pad {pad.pad + 1} <span style="color:#666">(note {pad.note})</span></div>
      <div class="row">
        <label style="flex:none; width:50px">File:</label>
        <select bind:value={pad.file} style="flex:1">
          <option value="">(none)</option>
          {#each samples as s}<option value={s}>{s}</option>{/each}
        </select>
      </div>
      <div class="row">
        <label style="width:50px; flex:none">Note:</label>
        <input type="number" bind:value={pad.note} style="width:60px; flex:none" />
      </div>
      <div class="row">
        <label style="width:50px; flex:none">Atk:</label>
        <input type="number" step="0.001" bind:value={pad.attack} style="width:70px; flex:none" />
        <label style="width:30px; flex:none">Dec:</label>
        <input type="number" step="0.01" bind:value={pad.decay} style="width:70px; flex:none" />
      </div>
      <div class="row">
        <label style="width:50px; flex:none">Sus:</label>
        <input type="number" step="0.01" min="0" max="1" bind:value={pad.sustain} style="width:70px; flex:none" />
        <label style="width:30px; flex:none">Rel:</label>
        <input type="number" step="0.01" bind:value={pad.release} style="width:70px; flex:none" />
      </div>
      <div class="row">
        <label style="width:50px; flex:none">Amp:</label>
        <input type="range" min="0" max="1" step="0.01" bind:value={pad.amp} style="flex:1" />
        <span style="width:35px; flex:none">{Number(pad.amp).toFixed(2)}</span>
      </div>
    </div>
  {/each}
</div>

<button class="primary" on:click={save}>Save Pad Config</button>
