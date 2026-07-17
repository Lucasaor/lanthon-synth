// =============================================================================
// Steps 2-7 — MIDI Input Routing (complete wiring)
// =============================================================================
// This file defines ALL MIDIdef handlers for the three controllers, filtered
// by device srcID.  It wires MIDI events to:
//   - Synth voice triggering (Steps 3 & 4)
//   - Loop track control via loops.scd (Step 5)
//   - APC fader → Ndef volume/FX (Step 6)
//   - LED feedback via apc_leds.scd (Step 7 — called by loops.scd)
//
// The srcID values MUST be set from calibration data before this works.
// See CONTROLS.md and the output of calibration.scd.

// =============================================================================
// CONFIGURATION — populate these from Step 0 calibration output
// =============================================================================

~srcID_APC    = nil;   // AKAI APC Mini srcID
~srcID_Easy   = nil;   // Worlde Easypad 12 srcID
~srcID_SMK    = nil;   // M-VAVE SMK 25 srcID

// =============================================================================
// MIDI INITIALIZATION
// =============================================================================

~initMIDI = {
	MIDIClient.init;
	"".postln;
	"=== MIDI Sources Detected ===".postln;
	MIDIClient.sources.do { |src, i|
		var dev = src.device ? "unknown";
		var port = src.name ? "unknown";
		"[%]  srcID=%  |  dev=«%»  |  port=«%»".format(i, src.uid, dev, port).postln;
	};
	"".postln;
	"=== MIDI Destinations Detected ===".postln;
	MIDIClient.destinations.do { |dest, i|
		var dev = dest.device ? "unknown";
		var port = dest.name ? "unknown";
		"[%]  uid=%  |  dev=«%»  |  port=«%»".format(i, dest.uid, dev, port).postln;
	};
	"".postln;

	// ---- Set up MIDI output to APC Mini for LED feedback ----
	~apcMidiOut = nil;
	MIDIClient.destinations.do { |dest, i|
		var dev = dest.device ? "";
		var port = dest.name ? "";
		if (dev.toLower.contains("apc") or: { port.toLower.contains("apc") }, {
			~apcMidiOut = MIDIOut(i);
			("APC Mini MIDI output found at index % — LED feedback enabled".format(i)).postln;
		});
	};
	if (~apcMidiOut.isNil, {
		"WARNING: APC Mini MIDI output not found — LED feedback disabled.".postln;
		"  (Connect the APC Mini's MIDI OUT port or enable USB MIDI out.)".postln;
	});

	"".postln;
	"After identifying your devices from the calibration output,".postln;
	"set the globals, e.g.:".postln;
	"  ~srcID_APC  = 123456;".postln;
	"  ~srcID_Easy = 234567;".postln;
	"  ~srcID_SMK  = 345678;".postln;
	"".postln;
};

// =============================================================================
// SMK25 → MELODIC VOICE (Step 3)
// =============================================================================
// Monophonic lead/bass voice with note-stealing.
// Active notes are tracked so note-off releases the correct voice.
// Sustain pedal (CC 64) holds notes past key release.

~smkActiveNotes = List.new;       // list of [note, vel, synthNode]
~smkSustainPedal = false;         // sustain pedal state
~smkCurrentVoice = \leadBass;     // which SynthDef to use
~smkOctaveOffset = 0;             // octave shift (0 = concert)

MIDIdef.noteOn(\smk_noteon, { |vel, note, chan, src|
	if (src != ~srcID_SMK, { ^nil });   // wrong device — silently ignore

	var freq = (note + (12 * ~smkOctaveOffset)).midicps;
	var synth;

	// Monophonic: steal the previous note if one is sounding
	if (~smkActiveNotes.size > 0, {
		var old = ~smkActiveNotes.pop;
		if (old[2].notNil, { old[2].set(\gate, 0); });
	});

	synth = Synth(~smkCurrentVoice, [
		\out,  ~mainOutBus,
		\freq, freq,
		\vel,  vel.linlin(0, 127, 0.01, 1.0),
		\gate, 1,
		\pan,  0.0
	]);

	~smkActiveNotes.add([note, vel, synth]);

	("[SMK] NOTE ON  | note=%, vel=%, freq=%".format(
		note, vel, freq.round(0.1)
	)).postln;
}, nil, nil, ~srcID_SMK);


MIDIdef.noteOff(\smk_noteoff, { |vel, note, chan, src|
	if (src != ~srcID_SMK, { ^nil });

	var entry = ~smkActiveNotes.detect({ |e| e[0] == note });
	if (entry.notNil, {
		~smkActiveNotes.remove(entry);
		if (~smkSustainPedal.not, {
			if (entry[2].notNil, { entry[2].set(\gate, 0); });
		}, {
			~smkHeldNotes = ~smkHeldNotes ? List.new;
			~smkHeldNotes.add(entry);
		});
	});

	("[SMK] NOTE OFF | note=%, vel=%".format(note, vel)).postln;
}, nil, nil, ~srcID_SMK);


// Sustain pedal (CC 64)
MIDIdef.cc(\smk_sustain, { |val, ccNum, chan, src|
	if (src != ~srcID_SMK, { ^nil });
	if (ccNum != 64, { ^nil });

	~smkSustainPedal = val > 63;

	if (~smkSustainPedal.not, {
		~smkHeldNotes = ~smkHeldNotes ? List.new;
		~smkHeldNotes.do { |entry|
			if (entry[2].notNil, { entry[2].set(\gate, 0); });
		};
		~smkHeldNotes.clear;
	});

	("[SMK] SUSTAIN | %".format(if (~smkSustainPedal, "ON", "OFF"))).postln;
}, nil, nil, ~srcID_SMK);


// Pitch bend
MIDIdef.bend(\smk_bend, { |val, chan, src|
	if (src != ~srcID_SMK, { ^nil });
	var bendRatio = val.linlin(0, 16383, -2, 2);  // ±2 semitones
	~smkActiveNotes.do { |entry|
		if (entry[2].notNil, {
			var baseFreq = (entry[0] + (12 * ~smkOctaveOffset)).midicps;
			entry[2].set(\freq, baseFreq * (2 ** (bendRatio / 12)));
		});
	};
}, nil, nil, ~srcID_SMK);


// Mod wheel (CC 1) → filter cutoff
MIDIdef.cc(\smk_modwheel, { |val, ccNum, chan, src|
	if (src != ~srcID_SMK, { ^nil });
	if (ccNum != 1, { ^nil });
	var cutoff = val.linlin(0, 127, 200, 8000);
	~smkActiveNotes.do { |entry|
		if (entry[2].notNil, { entry[2].set(\filterCutoff, cutoff); });
	};
}, nil, nil, ~srcID_SMK);


// =============================================================================
// EASYPAD 12 → PERCUSSION / SAMPLES (Step 4)
// =============================================================================

~easyPadMap = IdentityDictionary.new;
// Populate from CONTROLS.md calibration data — example:
// ~easyPadMap[36] = \kick;
// ~easyPadMap[37] = \snare;
// ...etc for all 12 pads

~setEasyPadMap = { |mappingArray|
	~easyPadMap.clear;
	mappingArray.do { |pair| ~easyPadMap[pair[0]] = pair[1]; };
	"Easypad mapping set: % pads configured.".format(mappingArray.size).postln;
};

MIDIdef.noteOn(\easy_pad_on, { |vel, note, chan, src|
	if (src != ~srcID_Easy, { ^nil });

	var voice = ~easyPadMap[note];
	if (voice.isNil, {
		("[EASY] Unmapped pad note=% — ignoring".format(note)).postln;
	});

	var amp = vel.linlin(0, 127, 0.01, 1.0);
	Synth(voice, [
		\out, ~mainOutBus,
		\vel, amp,
		\pan, 0.0
	]);

	("[EASY] PAD % → % | note=%, vel=%".format(note, voice, note, vel)).postln;
}, nil, nil, ~srcID_Easy);


// =============================================================================
// APC MINI — GRID BUTTONS → LOOP CONTROL (Step 5)
// =============================================================================

MIDIdef.noteOn(\apc_grid_noteon, { |vel, note, chan, src|
	if (src != ~srcID_APC, { ^nil });
	if (vel > 0, {
		~apcGridPress.(note, vel);  // defined in loops.scd
	});
}, nil, nil, ~srcID_APC);

MIDIdef.noteOff(\apc_grid_noteoff, { |vel, note, chan, src|
	if (src != ~srcID_APC, { ^nil });
	// No-op: we use note-on for latching behavior
}, nil, nil, ~srcID_APC);


// =============================================================================
// APC MINI — FADERS → VOLUME / FX (Step 6)
// =============================================================================
// Documented in CONTROLS.md after calibration.

~apcFaderMap = IdentityDictionary.new;
// Populate from calibration — example:
// ~apcFaderMap[48] = 0;  ~apcFaderMap[49] = 1; ... ~apcFaderMap[55] = 7;
~apcFaderMasterCC = 56;

MIDIdef.cc(\apc_faders, { |val, ccNum, chan, src|
	if (src != ~srcID_APC, { ^nil });

	var normVal = val.linlin(0, 127, 0.0, 1.0);

	if (ccNum == ~apcFaderMasterCC, {
		if (~globalFxNdef.notNil, {
			~globalFxNdef.set(\amp, normVal);
		});
		("[APC] MASTER FADER | val=%".format(normVal.round(0.001))).postln;
	}, {
		var loopIdx = ~apcFaderMap[ccNum];
		if (loopIdx.notNil, {
			var ndef = ~loopNdefs[loopIdx];
			if (ndef.notNil, { ndef.set(\amp, normVal); });
			("[APC] FADER CC=% → loop % vol=%".format(ccNum, loopIdx, normVal.round(0.001))).postln;
		}, {
			("[APC] Unmapped fader CC=% val=%".format(ccNum, val)).postln;
		});
	});
}, nil, nil, ~srcID_APC);


// =============================================================================
// APC MINI — TOP/SIDE CONTROL ROW BUTTONS
// =============================================================================

MIDIdef.cc(\apc_controls, { |val, ccNum, chan, src|
	if (src != ~srcID_APC, { ^nil });
	("[APC] CONTROL CC=% val=%".format(ccNum, val)).postln;
}, nil, nil, ~srcID_APC);

MIDIdef.noteOn(\apc_control_notes, { |vel, note, chan, src|
	if (src != ~srcID_APC, { ^nil });
	if (note >= 64, {
		("[APC] CONTROL BUTTON note=% vel=%".format(note, vel)).postln;
		// Map specific control-row buttons here (TBD from calibration)
	});
}, nil, nil, ~srcID_APC);


// =============================================================================
// UTILITY: PANIC / ALL-STOP
// =============================================================================

~panicStop = {
	"!!! PANIC STOP !!!".postln;
	~numLoops.do { |i|
		var ndef = ~loopNdefs[i];
		if (ndef.notNil, { ndef.stop; });
	};
	~stopClock.();
	~smkActiveNotes.do { |entry|
		if (entry[2].notNil, { entry[2].set(\gate, 0); });
	};
	~smkActiveNotes.clear;
	if (~refreshAllLEDs.notNil, { ~refreshAllLEDs.(); });
	"All loops stopped, clock halted, notes released.".postln;
};

// =============================================================================
// VERIFICATION (Steps 3-7 checkpoints)
// =============================================================================
// After setting ~srcID_* globals from calibration data and loading all
// modules, verify each step as described in TEST_LOG.md.
// Self-test (no hardware):
//   ~srcID_APC = -1; ~srcID_Easy = -2; ~srcID_SMK = -3;
//   ~apcGridPress.(~apcNoteForCell.(0, 1), 127);
//   ~loopStates.postln;  // → should show [ recording, empty, ... ]
