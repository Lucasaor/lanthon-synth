<script>
  import { invalidateAll } from '$app/navigation';

  export let data;

  let uploading = false;
  let uploadProgress = 0;
  let messages = [];

  // Large files are uploaded in 8 MB chunks (POST /api/upload/chunk) so the
  // Pi never buffers a whole ~200 MB render in RAM (that OOM-killed node).
  const CHUNK_BYTES = 8 * 1024 * 1024;

  /** Upload one file in chunks; calls onProgress(0..100). */
  async function uploadOne(file, onProgress) {
    const total = Math.max(1, Math.ceil(file.size / CHUNK_BYTES));
    for (let i = 0; i < total; i++) {
      const blob = file.slice(i * CHUNK_BYTES, Math.min(file.size, (i + 1) * CHUNK_BYTES));
      const r = await fetch('/api/upload/chunk', {
        method: 'POST',
        headers: {
          'x-file-name': encodeURIComponent(file.name),
          'x-chunk-index': String(i),
          'x-chunk-total': String(total),
        },
        body: blob,
      });
      if (!r.ok) {
        let err = `chunk ${i + 1}/${total} failed (${r.status})`;
        try { err = (await r.json()).error ?? err; } catch {}
        throw new Error(err);
      }
      onProgress(Math.round(((i + 1) / total) * 100));
    }
  }

  async function upload() {
    const input = document.getElementById('mediaInput');
    if (!input?.files?.length) return;

    uploading = true;
    uploadProgress = 0;
    messages = [];

    const files = [...input.files];
    let completed = 0;
    for (const file of files) {
      try {
        await uploadOne(file, (p) => {
          uploadProgress = Math.round(completed + p / files.length);
        });
        messages = [...messages, `✓ ${file.name}`];
      } catch (err) {
        // discard any partial spool file from the failed upload
        fetch('/api/upload/cancel', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ name: file.name }),
        }).catch(() => {});
        messages = [...messages, `✗ ${file.name}: ${err.message ?? err}`];
      }
      completed += 100 / files.length;
      uploadProgress = Math.round(completed);
    }

    uploading = false;
    input.value = '';  // reset so same file can be re-uploaded

    // Refresh the file lists — await to ensure load() completes
    await invalidateAll();
  }

  /** Delete an uploaded media file (refused if a setlist still uses it). */
  async function removeFile(name) {
    if (!confirm(`Delete "${name}"?`)) return;
    const r = await fetch(`/api/media/${encodeURIComponent(name)}`, { method: 'DELETE' });
    if (r.ok) {
      messages = [`✓ Deleted ${name}`];
      await invalidateAll();
    } else {
      let err = 'Delete failed';
      try {
        err = (await r.json()).error ?? err;
      } catch {}
      messages = [`✗ ${name}: ${err}`];
    }
  }
</script>

<h1>File Upload</h1>
<p class="yellow">Upload per-song files: one multichannel WAV (L, R, Click, Cue — optional Timecode) + one companion MIDI automation file per song. Multiple files at once.</p>

{#if uploading}
  <div class="progress-bar">
    <div class="progress-fill" style="width:{uploadProgress}%"></div>
    <span class="progress-text">{uploadProgress}%</span>
  </div>
{/if}

{#each messages as msg}
  <p class:green={msg.startsWith('✓')} class:red={msg.startsWith('✗')} class:yellow={msg.startsWith('⚠')}>{msg}</p>
{/each}

<div class="card">
  <h2>Song Files (WAV + MID)</h2>
  <p>Name format: <code>Song Name.wav</code> + <code>Song Name.mid</code> (exported from Reaper).</p>
  <div class="upload-row">
    <input id="mediaInput" type="file" accept=".wav,.flac,.aiff,.aif,.mid,.midi" multiple disabled={uploading} />
    <button on:click={() => upload()} disabled={uploading}>
      {uploading ? 'Uploading…' : 'Upload Files'}
    </button>
  </div>
</div>

<div class="card">
  <h2>Uploaded Media</h2>
  {#each data.media as f}
    <div class="row" style="justify-content:space-between; border-bottom:1px solid #333; padding:4px 0">
      <span>📄 {f}</span>
      <button class="danger" style="padding:2px 10px" on:click={() => removeFile(f)}>✕ Delete</button>
    </div>
  {/each}
  {#if !data.media.length}<p style="color:#666">No media files uploaded yet.</p>{/if}
</div>

<style>
  .progress-bar {
    width: 100%;
    height: 24px;
    background: #222;
    border: 1px solid #444;
    border-radius: 4px;
    margin: 12px 0;
    position: relative;
    overflow: hidden;
  }
  .progress-fill {
    height: 100%;
    background: linear-gradient(90deg, #4a9, #4a9);
    border-radius: 3px;
    transition: width 0.2s ease;
  }
  .progress-text {
    position: absolute;
    top: 0;
    left: 50%;
    transform: translateX(-50%);
    line-height: 24px;
    font-size: 12px;
    color: #fff;
    text-shadow: 0 0 4px #000;
  }
  .upload-row {
    display: flex;
    gap: 12px;
    align-items: center;
    flex-wrap: wrap;
  }
  .upload-row input[type="file"] {
    color: #aaa;
    font-family: monospace;
    flex: 1;
    min-width: 200px;
  }
  .green { color: #4a9; }
  .red { color: #e55; }
  .yellow { color: #ffcc00; }
</style>
