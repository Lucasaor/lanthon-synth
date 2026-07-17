// =============================================================================
// Step 0 — MIDI Discovery & Calibration Tool
// =============================================================================
// Run this standalone script on the target hardware (or dev machine with
// controllers connected) to capture the exact note/CC/srcID mapping for all
// three controllers.  The output is the source of truth for CONTROLS.md and
// every subsequent MIDIdef in the project.
//
// Usage:
//   1. Connect all three MIDI controllers.
//   2. Open this file in the SC IDE (or run via `sclang calibration.scd`).
//   3. Evaluate the entire file (Cmd/Ctrl+Enter).
//   4. Press pads, keys, faders, and grid buttons on each controller.
//   5. The post window will log every message with its source device.
//   6. Copy the logged data into CONTROLS.md.
//
// Press Ctrl+C in the post window (or evaluate `~cleanup.()`) to stop.
// =============================================================================

s.waitForBoot({
	// -----------------------------------------------------------------------
	// 1. Enumerate all connected MIDI sources
	// -----------------------------------------------------------------------
	"".postln;
	"=".dup(72).join.postln;
	"MIDI CALIBRATION TOOL — Device Enumeration".postln;
	"=".dup(72).join.postln;
	"".postln;

	MIDIClient.init;        // initialise the MIDI subsystem
	MIDIClient.list;        // print raw device list (also printed by .init)

	// Build a lookup table: srcID → (deviceName, portName)
	~srcLookup = IdentityDictionary.new;
	MIDIClient.sources.do { |src, i|
		var dev = src.device;
		var port = src.name;
		~srcLookup.put(src.uid, (device: dev, port: port, index: i));
		"------------------------------------------------------------".postln;
		"  srcID  (uid)   : %".format(src.uid).postln;
		"  Device name    : %".format(dev).postln;
		"  Port name      : %".format(port).postln;
		"  Source index   : %".format(i).postln;
	};
	"------------------------------------------------------------".postln;
	"".postln;

	"EXPECTED DEVICES (check that all three appear above):".postln;
	"  1. AKAI APC Mini       (grid controller)".postln;
	"  2. Worlde Easypad 12   (drum pads)".postln;
	"  3. M-VAVE SMK 25       (keyboard)".postln;
	"".postln;
	"If any are missing, check USB connections and run this again.".postln;
	"".postln;

	"------------------------------------------------------------".postln;
	" NOW LOGGING ALL INCOMING MIDI MESSAGES".postln;
	" Press pads, keys, faders, grid buttons on each controller.".postln;
	" Evaluate `~cleanup.()` or press Cmd+. to stop logging.".postln;
	"------------------------------------------------------------".postln;
	"".postln);

	// -----------------------------------------------------------------------
	// 2. Register catch-all handlers that log with srcID attribution
	// -----------------------------------------------------------------------
	// We use MIDIFunc (not MIDIdef) because we want to log everything
	// including messages that will later be claimed by MIDIdef responders.

	~noteOnFunc = MIDIFunc.noteOn({ |vel, note, chan, src|
		var info = ~srcLookup[src] ?? (device: "???", port: "???");
		"[NOTE ON ]  srcID=%, dev=%, port=%, chan=%, note=%, vel=%".format(
			src,
			info.device.trunc(20).padRight(20),
			info.port.trunc(15).padRight(15),
			chan,
			note,
			vel
		).postln;
	});
	// srcID: nil → catch-all (all devices)

	~noteOffFunc = MIDIFunc.noteOff({ |vel, note, chan, src|
		var info = ~srcLookup[src] ?? (device: "???", port: "???");
		"[NOTE OFF]  srcID=%, dev=%, port=%, chan=%, note=%, vel=%".format(
			src,
			info.device.trunc(20).padRight(20),
			info.port.trunc(15).padRight(15),
			chan,
			note,
			vel
		).postln;
	});

	~ccFunc = MIDIFunc.cc({ |val, ccNum, chan, src|
		var info = ~srcLookup[src] ?? (device: "???", port: "???");
		"[CC      ]  srcID=%, dev=%, port=%, chan=%, cc=%, val=%".format(
			src,
			info.device.trunc(20).padRight(20),
			info.port.trunc(15).padRight(15),
			chan,
			ccNum,
			val
		).postln;
	});

	~bendFunc = MIDIFunc.bend({ |val, chan, src|
		var info = ~srcLookup[src] ?? (device: "???", port: "???");
		"[PITCHBEND] srcID=%, dev=%, port=%, chan=%, val=%".format(
			src,
			info.device.trunc(20).padRight(20),
			info.port.trunc(15).padRight(15),
			chan,
			val
		).postln;
	});

	~pgmFunc = MIDIFunc.program({ |val, chan, src|
		var info = ~srcLookup[src] ?? (device: "???", port: "???");
		"[PGMCHANGE] srcID=%, dev=%, port=%, chan=%, prog=%".format(
			src,
			info.device.trunc(20).padRight(20),
			info.port.trunc(15).padRight(15),
			chan,
			val
		).postln;
	});

	// -----------------------------------------------------------------------
	// 3. Cleanup function
	// -----------------------------------------------------------------------
	~cleanup = {
		~noteOnFunc.free;
		~noteOffFunc.free;
		~ccFunc.free;
		~bendFunc.free;
		~pgmFunc.free;
		"".postln;
		"=== MIDI logging stopped ===".postln;
	};

	"Ready — start pressing buttons/pads/keys now.".postln;
	"Evaluate ~cleanup.() or press Cmd+. to stop.".postln;
});

// If the server is already booted, run the init block directly:
if (s.serverRunning, {
	"Server already running — starting calibration immediately.".postln;
	// Re-run the init block manually (same as above, sans waitForBoot)
	MIDIClient.init;
	// ... (the block above will have already run via waitForBoot callback)
});
