<script>
  import { onMount } from 'svelte';

  export let data;

  let routing = data.routing;
  let devices = data.devices ?? {};
  let busy = false;
  let status = '';
  let changed = false;

  const AUDIO_TRACKS = [
    { key: 'playback_l', label: 'Playback L' },
    { key: 'playback_r', label: 'Playback R' },
    { key: 'click',      label: 'Click' },
    { key: 'cue',        label: 'Cue' },
    { key: 'timecode',   label: 'Timecode' },
  ];

  const audioOptions = () => [
    { name: 'auto', label: 'auto — default output' },
    ...(devices.audio ?? []).map((d) => ({ name: d.name, label: d.name })),
  ];

  const midiOptions = () => [
    { name: 'auto', label: 'auto — first MIDI output' },
    ...(devices.midi_out ?? []).map((d) => ({ name: d.name, label: d.name })),
  ];

  const maxChannels = (key) => {
    const dev = (devices.audio ?? []).find((d) => d.name === routing.tracks?.[key]?.device);
    return dev?.max_out_channels ?? 8;
  };

  const deviceMissing = (key) => {
    const dev = routing.tracks?.[key]?.device;
    return dev && dev !== 'auto' && !(devices.audio ?? []).some((d) => d.name === dev);
  };

  onMount(() => {
    // Live re-enumeration: poll the engine's device snapshot every 3 s.
    const poll = async () => {
      try {
        const r = await fetch('/api/devices');
        if (r.ok) devices = await r.json();
      } catch {}
    };
    poll();
    const interval = setInterval(poll, 3000);
    return () => clearInterval(interval);
  });

  async function save() {
    busy = true;
    status = 'Saving…';
    try {
      await fetch('/api/config/audio_routing.json', {
        method: 'PUT',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(routing),
      });
      await fetch('/api/osc', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ address: '/config/routing_reload' }),
      });
      status = '✓ Routing saved and applied to the engine.';
      changed = false;
    } catch (e) {
      status = '✗ Save failed.';
    } finally {
      busy = false;
    }
  }
</script>

<h1>Output Routing</h1>
<p>Assign each logical track to a USB audio/MIDI device and a channel on it.
The device list is re-enumerated live (refresh every 3 s) — hot-plug a different
interface and re-map here without a restart.</p>

<div class="card">
  <h2>Connected Devices (live)</h2>
  {#if (devices.audio ?? []).length}
    <div class="row" style="flex-wrap:wrap">
      <span style="color:#aaa; flex:none">Audio out:</span>
      {#each devices.audio as d}
        <span class="chip green" title="audio output">{d.name} ({d.max_out_channels} ch)</span>
      {/each}
    </div>
  {:else}
    <p style="color:#888">No audio output devices detected yet…</p>
  {/if}
  {#if (devices.midi_out ?? []).length}
    <div class="row" style="flex-wrap:wrap">
      <span style="color:#aaa; flex:none">MIDI out:</span>
      {#each devices.midi_out as d}
        <span class="chip yellow" title="MIDI automation output">{d.name}</span>
      {/each}
    </div>
  {/if}
  {#if (devices.midi_in ?? []).length}
    <div class="row" style="flex-wrap:wrap">
      <span style="color:#aaa; flex:none">MIDI in:</span>
      {#each devices.midi_in as d}
        <span class="chip" title="MIDI controller input">{d.name}</span>
      {/each}
    </div>
  {/if}
</div>

<div class="card">
  <h2>Track Assignments</h2>
  <div class="row" style="border-bottom:1px solid #333; color:#aaa">
    <span style="flex:none; width:110px">Track</span>
    <span style="flex:2">Audio device</span>
    <span style="flex:none; width:80px">Channel</span>
  </div>
  {#each AUDIO_TRACKS as t}
    <div class="row" style="margin-top:6px">
      <label style="flex:none; width:110px; font-weight:bold"
        class:yellow={deviceMissing(t.key)}>{t.label}</label>
      <select bind:value={routing.tracks[t.key].device} style="flex:2"
        on:change={() => changed = true}>
        {#each audioOptions() as opt}
          <option value={opt.name}>{opt.label}</option>
        {/each}
      </select>
      <input type="number" min="1" max={maxChannels(t.key)}
        bind:value={routing.tracks[t.key].channel}
        style="flex:none; width:80px"
        on:change={() => changed = true} />
      {#if t.key === 'timecode'}
        <label style="flex:none; font-size:0.8rem; color:#aaa">
          <input type="checkbox" bind:checked={routing.tracks.timecode.enabled}
            on:change={() => changed = true} />
          enabled (only when the WAV has a 5th timecode channel)
        </label>
      {/if}
    </div>
    {#if deviceMissing(t.key)}
      <p class="red" style="font-size:0.75rem; margin:0 0 6px 110px">
        ⚠ device not connected — routing falls back to the default output
      </p>
    {/if}
  {/each}

  <div class="row" style="margin-top:10px">
    <label style="flex:none; width:110px; font-weight:bold">MIDI automation</label>
    <select bind:value={routing.tracks.midi_automation.device} style="flex:2"
      on:change={() => changed = true}>
      {#each midiOptions() as opt}
        <option value={opt.name}>{opt.label}</option>
      {/each}
    </select>
  </div>

  <div class="row" style="margin-top:10px">
    <label style="flex:none; width:110px; font-weight:bold">Clock device</label>
    <select bind:value={routing.clock_device} style="flex:2"
      on:change={() => changed = true}>
      <option value="auto">auto — device carrying Playback L/R</option>
      {#each (devices.audio ?? []) as d}
        <option value={d.name}>{d.name}</option>
      {/each}
    </select>
  </div>
</div>

<div class="row">
  <button class="primary" on:click={save} disabled={busy}>
    {busy ? 'Saving…' : (changed ? '💾 Save Routing' : 'Save Routing')}
  </button>
  {#if status}<span style="color:#8f8">{status}</span>{/if}
</div>

<div class="card">
  <h2>WAV Channel Convention</h2>
  <ul>
    <li><strong>Ch 1 Playback L</strong> — main house left</li>
    <li><strong>Ch 2 Playback R</strong> — main house right</li>
    <li><strong>Ch 3 Click</strong> — metronome for the drummer's IEM</li>
    <li><strong>Ch 4 Cue</strong> — cue/dica for IEM</li>
    <li><strong>Ch 5 Timecode</strong> — optional, only if present in the render</li>
  </ul>
  <p style="color:#888; font-size:0.85rem">
    Map any of these to any channel of any connected interface above.
  </p>
</div>

<style>
  .chip {
    font-size: 0.8rem;
    padding: 2px 8px;
    border-radius: 3px;
    background: #222;
    border: 1px solid #444;
  }
  .chip.green { border-color: #4a4; }
  .chip.yellow { border-color: #884; }
</style>

