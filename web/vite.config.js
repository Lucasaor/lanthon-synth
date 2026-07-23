import { sveltekit } from '@sveltejs/vite-plugin-svelte';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [sveltekit()],
  server: {
    port: 5000,
    host: true,   // bind to 0.0.0.0 so the Pi is reachable on the LAN
  },
});
