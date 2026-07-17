// =============================================================================
// main.scd — Lanthon Synth: Headless Live Performance Rig
// =============================================================================
// Entry point that boots the server, loads all modules in dependency order,
// and starts the shared clock.  This file is loaded by the systemd service
// (or run manually via `sclang main.scd` for development).
//
// Loading order matters — each file depends on definitions from earlier files:
//   1. synths.scd       — SynthDefs (no dependencies)
//   2. apc_leds.scd     — LED helpers (depends on loops.scd for ~apcNoteForCell)
//   3. loops.scd        — Ndef loop tracks (depends on synths.scd, apc_leds.scd)
//   4. clock.scd        — TempoClock + click (depends on synths.scd)
//   5. midi_routing.scd — MIDI handlers (depends on all of the above)
//
// NOTE: apc_leds.scd must load before loops.scd because loops.scd calls
// ~updateAPCled which is defined in apc_leds.scd.  However, apc_leds.scd
// references ~apcNoteForCell from loops.scd.  This circular-ish dependency
// is resolved because both files only define functions/globals — the
// functions aren't called until MIDI events arrive at runtime.

// =============================================================================
// SERVER BOOTSTRAP
// =============================================================================

"============================================".postln;
"  Lanthon Synth — Live Performance Rig".postln;
"  Raspberry Pi Zero 2W / SuperCollider".postln;
"============================================".postln;
"".postln;

// Audio backend configuration.
// On the Pi Zero 2W, we typically use:
//   - JACK for lowest latency (jackd -d alsa -d hw:USB -r 44100 -p 128 -n 2)
//   - Or portaudio directly if JACK isn't available
// The systemd service starts jackd first, then sclang connects to it.
//
// For dev on macOS/Linux desktop, the default CoreAudio/ALSA backend works.
// Uncomment and adjust as needed:

// o = Server.default.options;
// o.device = "USB Audio Device";  // set to your interface name
// o.numOutputBusChannels = 4;     // we need 4 outs: 2 main + 2 monitor
// o.numInputBusChannels  = 2;     // stereo input for loops
// o.sampleRate = 44100;
// o.blockSize = 128;              // ~2.9ms latency at 44.1k
// o.memSize = 8192 * 4;           // 32MB — small for the Pi's 512MB RAM

s.waitForBoot({
	"".postln;
	"=== Server booted ===".postln;
	("  Sample rate : " ++ s.sampleRate).postln;
	("  Block size  : " ++ s.options.blockSize).postln;
	("  Outputs     : " ++ s.options.numOutputBusChannels).postln;
	("  Inputs      : " ++ s.options.numInputBusChannels).postln;
	"".postln;

	// -------------------------------------------------------------------
	// STEP 1: Load SynthDefs
	// -------------------------------------------------------------------
	("Loading synths.scd...").postln;
	thisProcess.interpreter.executeFile(
		PathName(thisProcess.nowExecutingPath).parentPath +/+ "synths.scd"
	);
	// Give the server a moment to receive the SynthDefs
	s.sync;
	"  SynthDefs loaded.".postln;

	// -------------------------------------------------------------------
	// STEP 7 prep: Load APC LED functions
	// -------------------------------------------------------------------
	("Loading apc_leds.scd...").postln;
	thisProcess.interpreter.executeFile(
		PathName(thisProcess.nowExecutingPath).parentPath +/+ "apc_leds.scd"
	);
	"  APC LED subsystem loaded.".postln;

	// -------------------------------------------------------------------
	// STEP 5: Initialize loop tracks
	// -------------------------------------------------------------------
	("Loading loops.scd...").postln;
	thisProcess.interpreter.executeFile(
		PathName(thisProcess.nowExecutingPath).parentPath +/+ "loops.scd"
	);
	~initLoops.();
	s.sync;
	"  Loop tracks initialized.".postln;

	// -------------------------------------------------------------------
	// STEP 8: Start shared clock + click
	// -------------------------------------------------------------------
	("Loading clock.scd...").postln;
	thisProcess.interpreter.executeFile(
		PathName(thisProcess.nowExecutingPath).parentPath +/+ "clock.scd"
	);
	~startClock.(~clockBpm);
	"  Shared clock + click started.".postln;

	// -------------------------------------------------------------------
	// STEPS 2-7: Initialize MIDI and load handlers
	// -------------------------------------------------------------------
	("Loading midi_routing.scd...").postln;
	thisProcess.interpreter.executeFile(
		PathName(thisProcess.nowExecutingPath).parentPath +/+ "midi_routing.scd"
	);
	~initMIDI.();
	"  MIDI routing loaded.".postln;

	// -------------------------------------------------------------------
	// SETUP COMPLETE
	// -------------------------------------------------------------------
	"".postln;
	"============================================".postln;
	"  RIG READY".postln;
	"============================================".postln;
	"".postln;
	("  Tempo : " ++ ~clockBpm ++ " BPM").postln;
	("  Loops : " ++ ~numLoops ++ " tracks").postln;
	("  Voices: leadBass, leadBassSub, leadPad").postln;
	("          kick, snare, hihat, openHat, clap, rim, perc").postln;
	"".postln;
	"  Set controller srcIDs if not already done:".postln;
	"    ~srcID_APC  = <uid>;".postln;
	"    ~srcID_Easy = <uid>;".postln;
	"    ~srcID_SMK  = <uid>;".postln;
	"".postln;
	"  Commands:".postln;
	"    ~setBpm.(140)        — change tempo".postln;
	"    ~tapTempo.()         — tap tempo (4 taps)".postln;
	"    ~panicStop.()        — emergency stop all".postln;
	"    s.avgCPU.postln      — check CPU load".postln;
	"    s.peakCPU.postln     — check peak CPU".postln;
	"    ~testLEDs.()         — test APC LED wiring".postln;
	"".postln;

	// -------------------------------------------------------------------
	// OPTIONAL: Set up a simple global reverb on the shared FX bus
	// -------------------------------------------------------------------
	// Uncomment to add a shared reverb (routed via ~fxBus = 4):
	//
	// ~globalFxNdef = Ndef(\globalFx, {
	//     var sig = In.ar(~fxBus, 2);
	//     FreeVerb.ar(sig, mix: 0.3, room: 0.6, damp: 0.4);
	// });
	// ~globalFxNdef.play(out: ~mainOutBus);
	//
	// Then route loops to the FX bus by setting their \out to ~fxBus
	// instead of ~mainOutBus.  The faders can control the send level.

	// -------------------------------------------------------------------
	// PERIODIC CPU MONITORING (log every 30s while running)
	// -------------------------------------------------------------------
	~cpuMonitor = Routine {
		loop {
			("CPU: avg=" ++ s.avgCPU.round(0.01) ++ "%, peak=" ++ s.peakCPU.round(0.01) ++ "%").postln;
			30.0.wait;
		}
	};
	~cpuMonitor.play(SystemClock);
	"CPU monitor started (logs every 30s).".postln;
	"".postln;
	"READY FOR PERFORMANCE.".postln;
});

// =============================================================================
// SHUTDOWN HANDLER (called on Cmd+. or systemd stop)
// =============================================================================

~shutdown = {
	"Shutting down Lanthon Synth...".postln;
	if (~cpuMonitor.notNil, { ~cpuMonitor.stop; });
	~stopClock.();
	~freeLoops.();
	if (~globalFxNdef.notNil, { ~globalFxNdef.stop; ~globalFxNdef.clear; });
	MIDIClient.disposeClient;
	s.quit;
	"Shutdown complete.".postln;
};

// Trap Cmd+. to do a clean shutdown
CmdPeriod.doOnce({
	"Cmd+. received — clean shutdown...".postln;
	~shutdown.();
});

// =============================================================================
// VERIFICATION (all steps integrated)
// =============================================================================
// After running main.scd:
//   1. Check post window for any errors during loading.
//   2. Verify all SynthDefs loaded: SynthDescLib.global.synthDescs.keys.postln;
//   3. Verify loop buffers: ~loopBufs.postln;
//   4. Verify clock running: ~mainClock.postln;
//   5. Verify MIDI: MIDIClient.sources.postln;
//   6. Check CPU: s.avgCPU.postln; s.peakCPU.postln;
//   7. Press hardware controls and confirm audio + LED response.
//   8. Run for 20+ minutes, check CPU log for regressions.
