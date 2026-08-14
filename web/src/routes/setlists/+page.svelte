<script>
  export let data;
  let setlists = data.setlists;
  let mediaFiles = data.media ?? [];
  let editing = null;   // currently edited setlist object
  let newName = '';

  const TUNINGS = ['standard', 'drop'];
  const KEYS = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];

  async function load(name) {
    const r = await fetch(`/api/setlists/${name}`);
    editing = await r.json();
    editing._name = name;
    // Each song = one multichannel WAV + one companion MIDI file.
    editing.songs = (editing.songs ?? []).map(s => {
      const song = { wav: '', mid: '', tuning: 'standard', key: 'E', ...s };
      delete song.tempo;       // legacy BPM field no longer used
      delete song.vs; delete song.click; delete song.dica;  // legacy split tracks
      return song;
    });
    // Auto-fill files for each song
    for (const song of editing.songs) {
      autoFillFiles(song);
    }
  }

  async function save() {
    // Strip legacy fields before persisting
    editing.songs = (editing.songs ?? []).map(
      ({ tempo, vs, click, dica, ...song }) => song);
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
      { name: 'New Song', artist: '', tuning: 'standard', key: 'E', wav: '', mid: '' }];
  }

  /** Move a song up (-1) or down (+1) in the setlist. */
  function moveSong(i, dir) {
    const songs = editing.songs ?? [];
    const j = i + dir;
    if (j < 0 || j >= songs.length) return;
    editing.songs = songs.slice();
    const song = editing.songs.splice(i, 1)[0];
    editing.songs.splice(j, 0, song);
  }

  async function activateSetlist(name) {
    await fetch('/api/osc', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ address: '/backtrack/load', args: [name] }),
    });
  }

  /** Filter media files matching a song name for smarter defaults. */
  function matchingFiles(songName, suffix) {
    if (!songName) return mediaFiles;
    const lower = songName.toLowerCase();
    const matched = mediaFiles.filter(f => f.toLowerCase().includes(lower));
    const rest = mediaFiles.filter(f => !f.toLowerCase().includes(lower));
    return [...matched, ...rest];
  }

  /**
   * Auto-detect the song's WAV and MID files based on the song name.
   * Searches media files for the song name and the right extension:
   *   "<Song Name>.wav" / "<Song Name> (...).wav"  → WAV
   *   "<Song Name>.mid" / "<Song Name> (...).mid"  → MID
   * Only fills fields that have no explicit selection yet.
   */
  function autoFillFiles(song) {
    if (!song?.name) return;
    const lower = song.name.toLowerCase();
    const found = { wav: null, mid: null };

    for (const f of mediaFiles) {
      const fLower = f.toLowerCase();
      if (!fLower.includes(lower)) continue;
      if (!found.wav && /\.(wav|flac|aiff?)$/.test(fLower)) found.wav = f;
      if (!found.mid && /\.(midi?)$/.test(fLower)) found.mid = f;
    }

    for (const key of ['wav', 'mid']) {
      if (song[key] === undefined || song[key] === '') {
        song[key] = found[key] ?? '';
      }
    }
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
  <p style="color:#888; font-size:0.85rem">Upload files via <a href="/files">Files</a> page first, then assign them below.</p>
  {#each (editing.songs ?? []) as song, i}
    <div class="card" style="padding:10px; margin-bottom:8px">
      <div class="row">
        <span style="color:#aaa">#{i+1}</span>
        <button on:click={() => moveSong(i, -1)} disabled={i === 0} title="Move up">▲</button>
        <button on:click={() => moveSong(i, 1)} disabled={i === (editing.songs?.length ?? 1) - 1} title="Move down">▼</button>
        <input bind:value={song.name} placeholder="Song name" style="flex:2"
          on:input={() => autoFillFiles(song)} />
        <input bind:value={song.artist} placeholder="Artist" style="flex:2" />
        <select bind:value={song.tuning} style="width:96px; flex:none" title="Tuning">
          {#each TUNINGS as t}
            <option value={t}>{t === 'drop' ? 'Drop' : 'Standard'}</option>
          {/each}
        </select>
        <select bind:value={song.key} style="width:64px; flex:none" title="Key">
          {#each KEYS as k}
            <option value={k}>{k}</option>
          {/each}
        </select>
        <button class="danger" on:click={() => editing.songs.splice(i, 1) && (editing.songs = editing.songs)}>✕</button>
      </div>
      <div class="row" style="margin-top:6px; gap:4px; flex-wrap:wrap">
        <label style="font-size:0.8rem; flex:none; width:40px">WAV:</label>
        <select bind:value={song.wav} style="flex:1; min-width:180px; font-size:0.8rem"
          title="Multichannel backing track (L, R, Click, Cue + optional Timecode)">
          <option value="">(none)</option>
          {#each matchingFiles(song.name, 'wav') as f}
            <option value={f}>{f}</option>
          {/each}
        </select>
        <label style="font-size:0.8rem; flex:none; width:36px">MID:</label>
        <select bind:value={song.mid} style="flex:1; min-width:140px; font-size:0.8rem"
          title="MIDI automation file (PC/CC to the pedalboard, synced to the audio)">
          <option value="">(none)</option>
          {#each matchingFiles(song.name, 'mid') as f}
            <option value={f}>{f}</option>
          {/each}
        </select>
      </div>
    </div>
  {/each}
  <div class="row">
    <button on:click={addSong}>+ Add Song</button>
    <button class="primary" on:click={save}>Save Setlist</button>
  </div>
</div>
{/if}
