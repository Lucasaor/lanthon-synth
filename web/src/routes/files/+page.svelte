<script>
  import { invalidateAll } from '$app/navigation';

  export let data;

  let uploading = false;
  let uploadProgress = 0;
  let messages = [];

  /**
   * Upload files with progress tracking via XMLHttpRequest.
   * Supports multiple files at once.
   */
  async function upload() {
    const input = document.getElementById('mediaInput');
    if (!input?.files?.length) return;

    uploading = true;
    uploadProgress = 0;
    messages = [];

    const fd = new FormData();
    fd.append('type', 'media');
    for (const file of input.files) {
      fd.append('file', file);
    }

    await new Promise((resolve, reject) => {
      const xhr = new XMLHttpRequest();
      xhr.open('POST', '/api/upload');

      xhr.upload.addEventListener('progress', (e) => {
        if (e.lengthComputable) {
          uploadProgress = Math.round((e.loaded / e.total) * 100);
        }
      });

      xhr.addEventListener('load', () => {
        try {
          const json = JSON.parse(xhr.responseText);
          if (json.results) {
            messages = json.results.map((r) =>
              r.ok ? `✓ ${r.name}` : `✗ ${r.name}: ${r.error}`
            );
          } else if (json.error) {
            messages = [`✗ ${json.error}`];
          }
        } catch {
          messages = [`✗ Upload failed (status ${xhr.status})`];
        }
        resolve();
      });

      xhr.addEventListener('error', () => {
        messages = ['✗ Network error — upload failed'];
        resolve();
      });

      xhr.addEventListener('abort', () => {
        messages = ['⚠ Upload cancelled'];
        resolve();
      });

      xhr.send(fd);
    });

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
