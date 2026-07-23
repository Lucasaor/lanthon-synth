<script>
  export let data;

  // Grid: 8 rows × 8 cols (cols 0-5 = FX, cols 6-7 = PC)
  // cfg[row][col] = { type: 'osc'|'fx'|'pc', label: string }
  let cfg = data.cfg ?? buildDefault();

  const OSC_TYPES = ['sq', 'saw', 'supersaw', 'sine', 'tb303', 'wnoise'];
  const ROW_LABELS = ['Oscillator', 'Oct Down', 'Oct Up', 'Distortion',
                      'Tremolo', 'Reverb', 'LPF', 'HPF'];

  function buildDefault() {
    const g = [];
    for (let r = 0; r < 8; r++) {
      const row = [];
      for (let c = 0; c < 8; c++) {
        if (c < 6) {
          row.push({ type: r === 0 ? 'osc' : 'fx',
                     label: r === 0 ? OSC_TYPES[c] : ROW_LABELS[r] });
        } else {
          row.push({ type: 'pc', label: `PC ${(r * 2) + (c - 6) + 1}` });
        }
      }
      g.push(row);
    }
    return g;
  }

  async function save() {
    await fetch('/api/config/apc_config.json', {
      method: 'PUT',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(cfg),
    });
    alert('APC config saved.');
  }

  const colColors = ['#332', '#233', '#323', '#333', '#234', '#243'];
  const pcColor = '#313';
</script>

<h1>APC Mini Pad Configuration</h1>
<p>Row 1 (bottom) = Oscillators (cols 1–6). Rows 2–8 = Effects. Cols 7–8 = Program Change.</p>

<div class="card" style="overflow-x:auto">
  <table style="border-collapse:separate; border-spacing:3px">
    <thead>
      <tr>
        <th style="color:#aaa; width:80px">Row</th>
        {#each Array(6).fill(0) as _, c}
          <th style="color:#ffcc00">Col {c+1}</th>
        {/each}
        <th style="color:#f66">PC 7</th>
        <th style="color:#f66">PC 8</th>
      </tr>
    </thead>
    <tbody>
      {#each [...Array(8).keys()].reverse() as r}
        <tr>
          <td style="color:#aaa; font-size:0.8rem">{ROW_LABELS[r]}</td>
          {#each Array(8).fill(0) as _, c}
            <td style="background:{c < 6 ? colColors[c] : pcColor}; padding:4px; border-radius:4px; text-align:center">
              {#if r === 0 && c < 6}
                <select bind:value={cfg[r][c].label} style="font-size:0.75rem; padding:2px; background:transparent; color:#eee; border:none">
                  {#each OSC_TYPES as t}<option value={t}>{t}</option>{/each}
                </select>
              {:else}
                <span style="font-size:0.75rem; color:#aaa">{cfg[r][c].label}</span>
              {/if}
            </td>
          {/each}
        </tr>
      {/each}
    </tbody>
  </table>
</div>

<button class="primary" on:click={save}>Save APC Config</button>
