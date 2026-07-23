<script>
  export let data;
  let setlists = data.setlists;
  let editing = null;   // currently edited setlist object
  let newName = '';

  async function load(name) {
    const r = await fetch(`/api/setlists/${name}`);
    editing = await r.json();
    editing._name = name;
  }

  async function save() {
    await fetch(`/api/setlists/${editing._name}`, {
      method: 'PUT',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(editing),
    });
    alert('Saved!');
  }

  async function create() {
    if (!newName) return;
    await fetch('/api/setlists', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ name: newName }),
    });
    setlists = [...setlists, newName]; newName = '';
  }

  async function del(name) {
    if (!confirm(`Delete "${name}"?`)) return;
    await fetch(`/api/setlists/${name}`, { method: 'DELETE' });
    setlists = setlists.filter((s) => s !== name);
    if (editing?._name === name) editing = null;
  }

  function addSong() {
    editing.songs = [...(editing.songs ?? []),
      { name: 'New Song', artist: '', tempo: 120 }];
  }

  async function activateSetlist(name) {
    await fetch('/api/osc', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ address: '/backtrack/load', args: [name] }),
    });
  }
</script>

<h1>Setlists</h1>

<div class="card">
  <h2>New Setlist</h2>
  <div class="row">
    <input bind:value={newName} placeholder="Setlist name" />
    <button class="primary" on:click={create}>Create</button>
  </div>
</div>

<div class="card">
  <h2>Existing Setlists</h2>
  {#each setlists as s}
    <div class="row">
      <span style="flex:1">{s}</span>
      <button on:click={() => load(s)}>Edit</button>
      <button class="primary" on:click={() => activateSetlist(s)}>Load to Rig</button>
      <button class="danger" on:click={() => del(s)}>Delete</button>
    </div>
  {/each}
  {#if !setlists.length}<p style="color:#666">No setlists yet.</p>{/if}
</div>

{#if editing}
<div class="card">
  <h2>Editing: {editing._name}</h2>
  {#each (editing.songs ?? []) as song, i}
    <div class="card" style="padding:10px; margin-bottom:8px">
      <div class="row">
        <span style="color:#aaa">#{i+1}</span>
        <input bind:value={song.name} placeholder="Song name" style="flex:2" />
        <input bind:value={song.artist} placeholder="Artist" style="flex:2" />
        <input type="number" bind:value={song.tempo} placeholder="BPM" style="width:70px; flex:none" />
        <button class="danger" on:click={() => editing.songs.splice(i, 1) && (editing.songs = editing.songs)}>✕</button>
      </div>
    </div>
  {/each}
  <div class="row">
    <button on:click={addSong}>+ Add Song</button>
    <button class="primary" on:click={save}>Save Setlist</button>
  </div>
</div>
{/if}
