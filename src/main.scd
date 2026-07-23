// =============================================================================
// main.scd — LANTH0N 5YNTH: Boot entry point
// =============================================================================
// Run this file to start the full rig:
//   sclang main.scd           (from terminal, headless)
//   Ctrl+Enter in SC IDE      (for development on macOS/Linux)
//
// Module loading order (each depends on the previous):
//   1. synths.scd        — SynthDefs + ~initEffectChain function
//   2. apc_leds.scd      — LED state machine helpers
//   3. apc_pads.scd      — FX pad + PC pad state machine
//   4. backtrack.scd     — backtrack engine + OSC responders
//   5. clock.scd         — TempoClock + click routine
//   6. midi_routing.scd  — MIDI handlers (calls all of the above)
//
// loops.scd is NOT loaded — it has been superseded by apc_pads.scd.
// =============================================================================

// Project root (parent of /src)
~projectDir = PathName(thisProcess.nowExecutingPath).parentPath.dirname;

// =============================================================================
// SERVER OPTIONS
// =============================================================================
// Tune for the Pi Zero 2W. On a desktop dev machine the defaults work fine.
// Uncomment and adjust the device line to select your audio interface.

s.options.numOutputBusChannels = 4;   // 2 = FOH, 2 = IEM
s.options.numInputBusChannels  = 2;
s.options.sampleRate           = 44100;
s.options.blockSize            = 256;  // ~5.8ms latency; lower if JACK allows
s.options.memSize              = 8192 * 4;   // 32 MB audio memory
s.options.maxNodes             = 512;

// Uncomment to pin to a specific device:
// s.options.device = "USB Audio Device";

// =============================================================================
// BOOT
// =============================================================================

"============================================".postln;
"  LANTH0N 5YNTH — Live Performance Rig".postln;
"  Raspberry Pi Zero 2W / SuperCollider".postln;
"============================================".postln;

s.waitForBoot({

	// Allocate private audio buses BEFORE loading any SynthDef file
	~mainOutBus   = 0;
	~iemOutBus    = 2;
	~synthSendBus = Bus.audio(s, 2);   // private bus: voices → masterFX
	("  synthSendBus index: " ++ ~synthSendBus.index).postln;

	s.sync;

	// ── 1. SynthDefs ────────────────────────────────────────────────────
	"[BOOT] Loading synths.scd...".postln;
	thisProcess.interpreter.executeFile(~projectDir +/+ "src/synths.scd");
	s.sync;
	"  SynthDefs loaded.".postln;

	// ── 2. APC LED helpers ───────────────────────────────────────────────
	"[BOOT] Loading apc_leds.scd...".postln;
	thisProcess.interpreter.executeFile(~projectDir +/+ "src/apc_leds.scd");
	"  LED subsystem loaded.".postln;

	// ── 3. APC pad state machine ─────────────────────────────────────────
	"[BOOT] Loading apc_pads.scd...".postln;
	thisProcess.interpreter.executeFile(~projectDir +/+ "src/apc_pads.scd");
	~pcSnapshotsPath = ~projectDir +/+ "config/pc_snapshots.json";
	~initAPCPads.();
	"  APC pad state machine ready.".postln;

	// ── 4. Backtrack engine ──────────────────────────────────────────────
	"[BOOT] Loading backtrack.scd...".postln;
	~mediaDir    = ~projectDir +/+ "media";
	~setlistsDir = ~projectDir +/+ "setlists";
	thisProcess.interpreter.executeFile(~projectDir +/+ "src/backtrack.scd");
	~initBacktrack.();
	"  Backtrack engine ready.".postln;

	// ── 5. Master effect chain ───────────────────────────────────────────
	"[BOOT] Initializing master effect chain...".postln;
	~initEffectChain.();
	"  masterFX Ndef running.".postln;

	// ── 6. Shared clock + click ──────────────────────────────────────────
	"[BOOT] Loading clock.scd...".postln;
	thisProcess.interpreter.executeFile(~projectDir +/+ "src/clock.scd");
	~startClock.(~clockBpm);
	"  Clock started at % BPM".format(~clockBpm).postln;

	// ── 7. MIDI routing ──────────────────────────────────────────────────
	"[BOOT] Loading midi_routing.scd...".postln;
	thisProcess.interpreter.executeFile(~projectDir +/+ "src/midi_routing.scd");
	~initMIDI.();
	"  MIDI routing active.".postln;

	// ── CPU monitor (logs every 30s) ─────────────────────────────────────
	~cpuMonitor = Routine {
		loop {
			"[CPU] avg=%%  peak=%%".format(
				s.avgCPU.round(0.1), "%",
				s.peakCPU.round(0.1), "%"
			).postln;
			30.0.wait;
		}
	}.play(SystemClock);

	// ── READY ────────────────────────────────────────────────────────────
	"".postln;
	"============================================".postln;
	"  RIG READY".postln;
	"============================================".postln;
	"  synthSendBus : %".format(~synthSendBus.index).postln;
	"  mainOutBus   : %  (FOH)".format(~mainOutBus).postln;
	"  iemOutBus    : %  (IEM/monitor)".format(~iemOutBus).postln;
	"  Clock        : % BPM".format(~clockBpm).postln;
	"  Web UI       : http://lanth0n.local:5000  (if running)".postln;
	"  OLED OSC     : %:%".format(~oledOscHost ? "127.0.0.1", ~oledOscPort ? 9000).postln;
	"".postln;
	"  Commands:".postln;
	"    ~setBpm.(140)          — change tempo".postln;
	"    ~tapTempo.()           — tap tempo (call 4×)".postln;
	"    ~loadSetlist.(\"name\")  — load a setlist".postln;
	"    ~btPlay.()             — start backtrack".postln;
	"    ~btStop.()             — stop backtrack".postln;
	"    ~panicStop.()          — emergency stop all".postln;
	"    ~testLEDs.()           — test APC LED wiring".postln;
	"    s.avgCPU.postln        — CPU check".postln;
	"".postln;
});

// =============================================================================
// CLEAN SHUTDOWN
// =============================================================================

~shutdown = {
	"[SHUTDOWN] Stopping LANTH0N 5YNTH...".postln;
	if (~cpuMonitor.notNil, { ~cpuMonitor.stop; });
	~panicStop.();
	~stopClock.();
	if (Ndef(\masterFX).notNil, { Ndef(\masterFX).stop; Ndef(\masterFX).clear; });
	if (~deviceWatcherRoutine.notNil, { ~deviceWatcherRoutine.stop; });
	try { MIDIClient.disposeClient; } {};
	s.quit;
	"[SHUTDOWN] Done.".postln;
};

CmdPeriod.doOnce({
	"[SHUTDOWN] Cmd+. — clean shutdown.".postln;
	~shutdown.();
});

// =============================================================================
// VERIFICATION CHECKLIST (for TEST_LOG.md)
// =============================================================================
// After boot:
//   1. No errors in post window
//   2. SynthDescLib.global.synthDescs.keys.postln  → includes \lanth0nVoice
//   3. ~synthSendBus.postln                        → Bus(audio, index, ...)
//   4. Ndef(\masterFX).postln                      → active Ndef
//   5. ~mainClock.postln                           → TempoClock
//   6. MIDIClient.sources.postln                  → connected devices
//   7. s.avgCPU.postln                             → < 50% idle
//   8. Press APC pad → LED changes
//   9. Play SMK25 note → audio from FOH bus
//  10. Trigger Worlde pad → sample plays
//  11. Backtrack: ~loadSetlist.("example"); ~btPlay.(); → streams audio

// =============================================================================
// SERVER BOOTSTRAP
// =============================================================================

"============================================".postln;
"  Lanthon Synth — Live Performance Rig".postln;
"  Raspberry Pi Zero 2W / SuperCollider".postln;
"============================================".postln;
"".postln;


