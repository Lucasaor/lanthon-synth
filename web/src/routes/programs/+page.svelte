<script>
  export let data;
  let snapshots = data.snapshots ?? Array(16).fill(null);

  async function exportSlot(i) {
    const snap = snapshots[i];
    if (!snap) return;
    const blob = new Blob([JSON.stringify(snap, null, 2)], { type: 'application/json' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = `pc_${i + 1}.json`;
    a.click();
  }

  async function importSlot(i, event) {
    const file = event.target.files[0];
    if (!file) return;
    const text = await file.text();
    const json = JSON.parse(text);
    snapshots[i] = json;
    await saveAll();
  }

  async function clearSlot(i) {
    if (!confirm(`Clear PC pad ${i + 1}?`)) return;
    snapshots[i] = null;
    await saveAll();
  }

  async function saveAll() {
    const cfg = await fetch('/api/config/pc_snapshots.json').then(r => r.json()).catch(() => ({}));
    const updated = { ...cfg, snapshots };
    await fetch('/api/config/pc_snapshots.json', {
      method: 'PUT',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(updated),
    });
    alert('PC snapshots saved.');
  }
</script>

<h1>Program Change Pads</h1>
<p>Each of the 16 PC pads (APC Mini columns 7–8, all rows) can store a full FX pad snapshot.</p>

<div class="card" style="display:grid; grid-template-columns:repeat(4,1fr); gap:10px">
  {#each snapshots as snap, i}
    <div class="card" style="padding:10px; text-align:center">
      <div style="font-weight:bold; color:{snap ? '#4f4' : '#666'}">PC {i + 1}</div>
      <div style="color:#aaa; font-size:0.8rem; margin:4px 0">{snap ? 'SAVED' : 'empty'}</div>
      <div class="row" style="justify-content:center; gap:6px">
        <button on:click={() => exportSlot(i)} disabled={!snap}>Export</button>
        <label class="import-btn">Import
          <input type="file" accept=".json" on:change={(e) => importSlot(i, e)} style="display:none" />
        </label>
        {#if snap}<button class="danger" on:click={() => clearSlot(i)}>Clear</button>{/if}
      </div>
    </div>
  {/each}
</div>

<style>
  .import-btn {
    background: #333; color: #eee; border: 1px solid #555;
    padding: 6px 14px; border-radius: 4px; cursor: pointer; font-family: monospace;
    font-size: 1rem;
  }
  .import-btn:hover { background: #555; }
</style>
