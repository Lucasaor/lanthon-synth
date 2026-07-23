<script>
  import { page } from '$app/stores';
  import { onMount } from 'svelte';

  let scOnline = false;
  let healthChecked = false;

  onMount(() => {
    const check = async () => {
      try {
        const r = await fetch('/api/health');
        if (r.ok && (await r.json()).ok) {
          scOnline = true;
        } else {
          scOnline = false;
        }
      } catch {
        scOnline = false;
      }
      healthChecked = true;
    };
    check();
    const interval = setInterval(check, 10000);
    return () => clearInterval(interval);
  });

  const nav = [
    { href: '/',          label: 'Dashboard' },
    { href: '/files',     label: 'Files' },
    { href: '/setlists',  label: 'Setlists' },
    { href: '/midi',      label: 'MIDI Map' },
    { href: '/routing',   label: 'Routing' },
    { href: '/pads',      label: 'APC Pads' },
    { href: '/worlde',    label: 'Worlde Pads' },
    { href: '/programs',  label: 'Programs' },
  ];
</script>

<nav>
  <span class="brand">LANTH0N 5YNTH</span>
  {#each nav as item}
    <a href={item.href} class:active={$page.url.pathname === item.href}>{item.label}</a>
  {/each}
  {#if healthChecked}
    <span class="health" class:green={scOnline} class:red={!scOnline}>
      {scOnline ? '🔊 SC ONLINE' : '🔇 SC OFFLINE'}
    </span>
  {:else}
    <span class="health" style="color:#666">⟳ checking...</span>
  {/if}
</nav>

<main>
  <slot />
</main>

<style>
  :global(body) {
    margin: 0;
    font-family: monospace;
    background: #111;
    color: #eee;
  }
  nav {
    display: flex;
    gap: 12px;
    align-items: center;
    padding: 8px 16px;
    background: #1a1a2e;
    border-bottom: 1px solid #333;
    flex-wrap: wrap;
  }
  .brand {
    font-weight: bold;
    font-size: 1.1rem;
    color: #ffcc00;
    margin-right: 8px;
  }
  nav a {
    color: #aaa;
    text-decoration: none;
    padding: 4px 8px;
    border-radius: 4px;
  }
  nav a:hover, nav a.active {
    background: #333;
    color: #fff;
  }
  main {
    padding: 20px;
    max-width: 960px;
    margin: 0 auto;
  }
  :global(h1) { color: #ffcc00; margin-top: 0; }
  :global(h2) { color: #aaa; }
  :global(button) {
    background: #333; color: #eee; border: 1px solid #555;
    padding: 6px 14px; border-radius: 4px; cursor: pointer; font-family: monospace;
  }
  :global(button:hover) { background: #555; }
  :global(button.primary) { background: #226622; border-color: #4a4; }
  :global(button.danger)  { background: #662222; border-color: #a44; }
  :global(input, select) {
    background: #222; color: #eee; border: 1px solid #444;
    padding: 5px 8px; border-radius: 4px; font-family: monospace;
    width: 100%; box-sizing: border-box;
  }
  :global(.card) {
    background: #1a1a1a; border: 1px solid #333; border-radius: 6px;
    padding: 16px; margin-bottom: 16px;
  }
  :global(.row) { display: flex; gap: 10px; align-items: center; margin-bottom: 8px; }
  :global(.green) { color: #4f4; }
  :global(.red)   { color: #f44; }
  :global(.yellow){ color: #ff4; }
  .health { font-size: 0.75rem; margin-left: auto; }
  .green { color: #4f4; }
  .red   { color: #f44; }
</style>
