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
  async function upload(type) {
    const inputId = type === 'sample' ? 'sampleInput' : 'mediaInput';
    const input = document.getElementById(inputId);
    if (!input?.files?.length) return;

    uploading = true;
    uploadProgress = 0;
    messages = [];

    const fd = new FormData();
    fd.append('type', type);
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

    // Refresh the file lists
    invalidateAll();
  }
</script>

<h1>File Upload</h1>
<p class="yellow">MP3 files are automatically converted to WAV using ffmpeg. Select multiple files at once.</p>

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
  <h2>Backtrack Files (VS / Click / Cue)</h2>
  <p>Name format: <code>Song Name (VS).mp3</code>, <code>Song Name (click).mp3</code>, <code>Song Name (Dica).mp3</code></p>
  <div class="upload-row">
    <input id="mediaInput" type="file" accept=".mp3,.wav,.aiff" multiple disabled={uploading} />
    <button on:click={() => upload('media')} disabled={uploading}>
      {uploading ? 'Uploading…' : 'Upload Media'}
    </button>
  </div>
</div>

<div class="card">
  <h2>Sample Files (Worlde Pads)</h2>
  <div class="upload-row">
    <input id="sampleInput" type="file" accept=".wav,.mp3,.aiff" multiple disabled={uploading} />
    <button on:click={() => upload('sample')} disabled={uploading}>
      {uploading ? 'Uploading…' : 'Upload Samples'}
    </button>
  </div>
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
