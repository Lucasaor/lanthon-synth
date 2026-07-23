<script>
  export let data;
  let uploading = false;
  let msg = '';

  async function upload(event, type) {
    const input = event.target;
    if (!input.files?.length) return;
    uploading = true; msg = 'Uploading…';
    const fd = new FormData();
    fd.append('file', input.files[0]);
    fd.append('type', type);
    const r = await fetch('/api/upload', { method: 'POST', body: fd });
    const j = await r.json();
    msg = j.ok ? `✓ Saved: ${j.name}` : `✗ Error: ${j.error}`;
    uploading = false;
  }
</script>

<h1>File Upload</h1>
<p class="yellow">MP3 files are automatically converted to WAV using ffmpeg.</p>
{#if msg}<p class:green={msg.startsWith('✓')} class:red={msg.startsWith('✗')}>{msg}</p>{/if}

<div class="card">
  <h2>Backtrack Files (VS / Click / Cue)</h2>
  <p>Name format: <code>Song Name (VS).mp3</code>, <code>Song Name (click).mp3</code>, <code>Song Name (Dica).mp3</code></p>
  <label>Upload media file:
    <input type="file" accept=".mp3,.wav,.aiff" on:change={(e) => upload(e, 'media')} disabled={uploading} />
  </label>
</div>

<div class="card">
  <h2>Sample Files (Worlde Pads)</h2>
  <label>Upload sample:
    <input type="file" accept=".wav,.mp3,.aiff" on:change={(e) => upload(e, 'sample')} disabled={uploading} />
  </label>
</div>

<div class="card">
  <h2>Uploaded Media</h2>
  {#each data.media as f}<div>📄 {f}</div>{/each}
  {#if !data.media.length}<p style="color:#666">No media files uploaded yet.</p>{/if}
</div>

<div class="card">
  <h2>Uploaded Samples</h2>
  {#each data.samples as f}<div>🥁 {f}</div>{/each}
  {#if !data.samples.length}<p style="color:#666">No samples uploaded yet.</p>{/if}
</div>
