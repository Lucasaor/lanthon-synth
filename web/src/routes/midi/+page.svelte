<script>
  export let data;
  let map = data.map ?? { mappings: [] };
  let learning = null;   // { index, type } — active learn slot

  const ACTIONS = ['btPlay', 'btStop', 'btNext', 'btPrev'];

  function addMapping() {
    map.mappings = [...(map.mappings ?? []),
      { action: 'btPlay', type: 'note', value: 0, srcID: 0 }];
  }

  async function save() {
    await fetch('/api/config/midi_map.json', {
      method: 'PUT',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(map),
    });
    await fetch('/api/osc', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ address: '/config/midi_map_reload' }),
    });
    alert('MIDI map saved and reloaded.');
  }
</script>

<h1>MIDI Mapping</h1>
<p>Map controller note/CC messages to backtrack actions (play, stop, next, prev).</p>
<p class="yellow">After saving, the SuperCollider engine reloads the map automatically.</p>

<div class="card">
  {#each (map.mappings ?? []) as m, i}
    <div class="row" style="border-bottom:1px solid #333; padding-bottom:6px; margin-bottom:6px">
      <select bind:value={m.action} style="width:100px; flex:none">
        {#each ACTIONS as a}<option value={a}>{a}</option>{/each}
      </select>
      <select bind:value={m.type} style="width:70px; flex:none">
        <option value="note">Note</option>
        <option value="cc">CC</option>
      </select>
      <label style="flex:none">Value:</label>
      <input type="number" bind:value={m.value} style="width:60px; flex:none" />
      <label style="flex:none">srcID:</label>
      <input type="number" bind:value={m.srcID} style="width:90px; flex:none" />
      <button class="danger" on:click={() => (map.mappings.splice(i, 1), map.mappings = map.mappings)}>✕</button>
    </div>
  {/each}
  <div class="row">
    <button on:click={addMapping}>+ Add Mapping</button>
    <button class="primary" on:click={save}>Save Map</button>
  </div>
</div>
