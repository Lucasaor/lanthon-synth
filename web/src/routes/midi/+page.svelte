<script>
  import { onDestroy } from 'svelte';

  export let data;

  let mappings = data.mappings ?? [];
  let actions  = data.actions ?? [];
  let learnActive = false;
  let capturedEvent = null;
  let selectedAction = 'btPlay';
  let conflict = null;
  let learnPoll = null;
  let status = '';

  async function startLearn() {
    status = 'Listening for MIDI input... press a key or turn a knob on your controller';
    capturedEvent = null;
    conflict = null;
    learnActive = true;
    await fetch('/api/midi/learn', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ action: 'start' }),
    });
    // Poll for captured event every 300ms; auto-stop once an event arrives
    learnPoll = setInterval(async () => {
      try {
        const r = await fetch('/api/midi/learn');
        if (r.ok) {
          const d = await r.json();
          if (d.event && d.event.chan !== undefined && d.event.value !== undefined) {
            capturedEvent = d.event;
            // Build status line for all MIDI event types
            const t = d.event.type ?? 'unknown';
            let detail = '';
            if (t === 'note')  detail = ' (vel: ' + d.event.vel + ')';
            else if (t === 'cc')   detail = ' (val: ' + d.event.ccVal + ')';
            else if (t === 'pgm')  detail = ' (PC)';
            else if (t === 'bend') detail = ' (pitch bend)';
            else if (t === 'sysex') detail = ' (' + d.event.sysexData + ')';
            status = 'Captured: ' + t.toUpperCase() + ' ' + d.event.value + detail +
              '  ch:' + d.event.chan;
            // Single-shot: engine already deactivated; confirm and stop polling
            if (learnPoll) { clearInterval(learnPoll); learnPoll = null; }
            learnActive = false;
            fetch('/api/midi/learn', {
              method: 'POST', headers: { 'content-type': 'application/json' },
              body: JSON.stringify({ action: 'stop' }),
            }).catch(() => {});
          }
        }
      } catch {}
    }, 300);
  }

  async function stopLearn() {
    learnActive = false;
    if (learnPoll) { clearInterval(learnPoll); learnPoll = null; }
    await fetch('/api/midi/learn', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ action: 'stop' }),
    });
    status = capturedEvent ? 'Ready to save' : 'Learn cancelled';
  }

  async function cancelLearn() {
    learnActive = false;
    capturedEvent = null;
    conflict = null;
    if (learnPoll) { clearInterval(learnPoll); learnPoll = null; }
    await fetch('/api/midi/learn', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ action: 'cancel' }),
    });
    status = '';
  }

  async function saveMapping(replaceExisting = false) {
    if (!capturedEvent) return;
    const mapping = {
      chan:   capturedEvent.chan,
      type:   capturedEvent.type,
      value:  capturedEvent.value,
      action: selectedAction,
    };
    const r = await fetch('/api/midi/learn', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ action: 'save', mapping, replace: replaceExisting }),
    });
    const result = await r.json();
    if (result.ok) {
      status = 'Saved: ' + mapping.type + ' ' + mapping.value + ' → ' + selectedAction;
      capturedEvent = null;
      conflict = null;
      // Refresh mappings
      const refresh = await fetch('/midi?_data=1');
      if (refresh.ok) {
        const d = await refresh.json();
        mappings = d.mappings ?? [];
      }
    } else if (result.conflict) {
      conflict = result;
      status = result.message;
    }
  }

  async function deleteMapping(index) {
    const updated = mappings.filter((_, i) => i !== index);
    await fetch('/api/config/midi_map.json', {
      method: 'PUT',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ mappings: updated }),
    });
    mappings = updated;
    await fetch('/api/osc', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ address: '/midi/reload' }),
    });
  }

  onDestroy(() => {
    if (learnPoll) clearInterval(learnPoll);
  });
</script>

<h1>MIDI Learn</h1>
<p>Click <strong>Start Learning</strong>, then press a key or turn a knob on your MIDI controller.
The system will capture the message and let you assign it to a backtrack action.</p>

<div class="card">
  <h2>1. Capture MIDI Input</h2>
  <div class="row">
    {#if !learnActive}
      <button class="primary" on:click={startLearn}>🎹 Start Learning</button>
    {:else}
      <button on:click={stopLearn}>⏹ Stop &amp; Keep</button>
      <button class="danger" on:click={cancelLearn}>✕ Cancel</button>
    {/if}
  </div>
  {#if status}
    <p class="status-msg">{status}</p>
  {/if}
</div>

{#if capturedEvent}
<div class="card">
  <h2>2. Assign Action</h2>
  <div class="row">
    <label style="flex:none"><strong>Captured:</strong></label>
    <span style="background:#222;padding:4px 12px;border-radius:4px;font-family:monospace">
      {capturedEvent.type.toUpperCase()} {capturedEvent.value}
      {#if capturedEvent.type === 'note'} (vel: {capturedEvent.vel}){/if}
      chan: {capturedEvent.chan}
    </span>
  </div>
  <div class="row" style="margin-top:12px">
    <label style="flex:none"><strong>Action:</strong></label>
    <select bind:value={selectedAction} style="width:200px">
      {#each actions as a}
        <option value={a.value}>{a.label}</option>
      {/each}
    </select>
    <button class="primary" on:click={() => saveMapping(false)}>💾 Save</button>
  </div>

  {#if conflict}
    <div class="conflict-box">
      <p>⚠️ {conflict.message}</p>
      <p>Existing mapping: <strong>{conflict.existing?.type} {conflict.existing?.value} → {conflict.existing?.action}</strong></p>
      <div class="row">
        <button class="danger" on:click={() => saveMapping(true)}>
          Replace &amp; Save
        </button>
        <button on:click={() => { conflict = null; status = ''; }}>Keep Both</button>
      </div>
    </div>
  {/if}
</div>
{/if}

<div class="card">
  <h2>Current Mappings ({mappings.length})</h2>
  {#if mappings.length === 0}
    <p style="color:#888">No mappings yet. Use the Learn feature above to add one.</p>
  {:else}
    {#each mappings as m, i}
      <div class="row" style="border-bottom:1px solid #333; padding:6px 0">
        <span style="font-family:monospace; background:#222; padding:2px 8px; border-radius:3px; width:80px; text-align:center">
          {m.type} {m.value}
        </span>
        <span>→</span>
        <span style="font-weight:bold; width:120px">
          {actions.find(a => a.value === m.action)?.label ?? m.action}
        </span>
        <span style="color:#888; font-size:0.8rem">ch: {m.chan}</span>
        <button class="danger" style="margin-left:auto; padding:2px 8px"
          on:click={() => deleteMapping(i)}>✕</button>
      </div>
    {/each}
  {/if}
</div>

<style>
  .status-msg { margin-top:10px; padding:8px 12px; background:#1a3a1a; border-radius:4px; color:#8f8; }
  .conflict-box { margin-top:12px; padding:12px; background:#3a1a1a; border:1px solid #a44; border-radius:6px; }
  .conflict-box p { margin:0 0 8px 0; }
</style>
