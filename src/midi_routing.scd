// =============================================================================
// midi_routing.scd — LANTH0N 5YNTH: MIDI routing (offline-resilient)
// =============================================================================
// Wires all three MIDI controllers to the audio engine:
//   SMK25 (Bluetooth) → \lanth0nVoice melodic voice
//   APC Mini          → FX pads, PC pads, faders, Notes Mode
//   Worlde Easypad 12 → sample playback (\sampleVoice)
//   Any controller    → configurable backtrack MIDI mapping
//
// OFFLINE RESILIENCE (non-negotiable constraint):
//   - All MIDIdef handlers guard against nil srcID (pass-through if nil).
//   - A device-watcher Routine periodically rescans connected devices and
//     re-registers handlers when a device reconnects (including BT reconnect).
//   - The system boots fully and remains stable with zero controllers attached.
//   - Missing devices are logged as warnings, never thrown as errors.
//
// SMK25 Bluetooth: shows up as a BT MIDI device; srcID is populated the same
//   way as USB devices but may differ across OS reconnects. The device-watcher
//   handles reconnect transparently.

// =============================================================================
// DEVICE srcID REGISTRY
// =============================================================================
// Set these from calibration.scd output before the rig goes live.
// nil = "not yet known or not connected" → handlers silently skip messages.

~srcID_APC    = nil;   // AKAI APC Mini
~srcID_Easy   = nil;   // Worlde Easypad 12
~srcID_SMK    = nil;   // M-VAVE SMK 25 (Bluetooth MIDI)

// Expected device name fragments (used by auto-detect to set srcIDs)
~apcDevName   = "APC";
~easyDevName  = "Easypad";    // update to match your OS's reported name
~smkDevName   = "SMK";        // BT MIDI name as seen by the OS

// Backtrack MIDI action map — populated from config/midi_map.json at runtime.
// Format: IdentityDictionary[ srcID -> IdentityDictionary[ note/CC -> action ] ]
// actions: tPlay, tStop, tNext, tPrev
~midiActionMap = IdentityDictionary.new;

// =============================================================================
// SMK25 KNOB CC MAP (MIDI-learn driven)
// =============================================================================
// Maps knob CC number → handler symbol.
// Loaded from config/midi_map.json (\smkKnobs section) at startup.
// Default mapping hard-coded here; overridden by config file.
//
// Handler symbols:
//   \lpfCutoff, \hpfCutoff           → Ndef(\masterFX) param (normalised 0-1)
//   \attack, \decay, \sustain, \release  → ~voiceParams + running voices
//   \tempo                           → TempoClock BPM
//   \fxMix                           → ~voiceParams[\dryWet]
//   \delayTime, \delayFeedback        → Ndef(\masterFX) param
//   \revRoom, \revDamp               → Ndef(\masterFX) param
//   \distDrive                       → Ndef(\masterFX) param

// Default mapping (CC 70-78 = typical SMK-25 knob range).
// Change CCs to match your hardware after running calibration.scd.
~smkKnobMap = IdentityDictionary[
	70 -> \lpfCutoff,
	71 -> \hpfCutoff,
	72 -> \attack,
	73 -> \decay,
	74 -> \sustain,
	75 -> \release,
	76 -> \tempo,
	77 -> \fxMix,
	78 -> \delayTime,
	79 -> \delayFeedback,
	80 -> \revRoom,
	81 -> \revDamp,
	82 -> \distDrive
];

// =============================================================================
// VOICE POOL (for live parameter updates)
// =============================================================================
// All currently active \lanth0nVoice Synths are kept here so apc_pads.scd
// can update oscillator levels and ADSR parameters in real time.
// SMK25 and APC Notes Mode each have their own pool to avoid cross-device
// voice-stealing (mitigation plan issue #12).
~lanth0nVoices    = List.new;   // SMK25: [ [noteNum, synthNode], ... ]
~apcNotesVoices   = List.new;   // APC Notes Mode: [ [noteNum, synthNode], ... ]

// =============================================================================
// SAMPLE BUFFER POOL (for Worlde Easypad 12 AND SMK25 pads)
// =============================================================================
~easyPadBuffers = Array.fill(12, { nil });
~easyPadConfig  = Array.fill(12, {
	IdentityDictionary[\attack -> 0.005, \decay -> 0.1, \sustain -> 0.8, \release -> 0.3, \amp -> 0.8]
});
~easyPadVoices  = Array.fill(12, { List.new });

// SMK25 pads — same structure as Easypad
~smkPadBuffers  = Array.fill(16, { nil });   // SMK25 has up to 16 pads (check hardware)
~smkPadConfig   = Array.fill(16, {
	IdentityDictionary[\attack -> 0.005, \decay -> 0.1, \sustain -> 0.8, \release -> 0.3, \amp -> 0.8]
});
~smkPadVoices   = Array.fill(16, { List.new });
~smkPadNoteMap  = IdentityDictionary.new;   // note → padIndex (0-15)

// =============================================================================
// MIDI INITIALIZATION (offline-resilient)
// =============================================================================

~initMIDI = {
	// Safely initialize MIDI — catch any error so the rig doesn't crash
	// if no controllers are attached at boot.
	var safeInit = {
		try {
			MIDIClient.init(verbose: false);
		} { |err|
			"[MIDI] MIDIClient.init failed: % — continuing without MIDI".format(err).postln;
		};
	};
	safeInit.();

	"".postln;
	"=== MIDI DEVICES DETECTED ===".postln;
	MIDIClient.sources.do { |src, i|
		var dev = src.device ? "?";
		var port = src.name ? "?";
		"  [%] srcID=% | «%» / «%»".format(i, src.uid, dev, port).postln;
	};
	"".postln;

	// Auto-detect device srcIDs from known name fragments
	MIDIClient.sources.do { |src|
		var dev = (src.device ? "") ++ " " ++ (src.name ? "");
		if (dev.toUpper.contains(~apcDevName.toUpper),  { ~srcID_APC  = src.uid; });
		if (dev.toUpper.contains(~easyDevName.toUpper), { ~srcID_Easy = src.uid; });
		if (dev.toUpper.contains(~smkDevName.toUpper),  { ~srcID_SMK  = src.uid; });
	};

	// Report detection results
	if (~srcID_APC.isNil,  { "[MIDI] WARNING: APC Mini not found — APC handlers inactive".postln; },
		{ "[MIDI] APC Mini detected (srcID=%)".format(~srcID_APC).postln });
	if (~srcID_Easy.isNil, { "[MIDI] WARNING: Easypad not found — pad triggers inactive".postln; },
		{ "[MIDI] Easypad detected (srcID=%)".format(~srcID_Easy).postln });
	if (~srcID_SMK.isNil,  { "[MIDI] WARNING: SMK25 not found — melodic voice inactive".postln; },
		{ "[MIDI] SMK25 detected (srcID=%)".format(~srcID_SMK).postln });

	// Auto-detect APC Mini MIDI output for LED feedback
	~apcMidiOut = nil;
	MIDIClient.destinations.do { |dest, i|
		var name = ((dest.device ? "") ++ " " ++ (dest.name ? "")).toUpper;
		if (name.contains(~apcDevName.toUpper), {
			~apcMidiOut = MIDIOut(i);
			"[MIDI] APC Mini output found at index % → LED feedback enabled".format(i).postln;
		});
	};
	if (~apcMidiOut.isNil, {
		"[MIDI] WARNING: APC Mini output not found — LED feedback disabled".postln;
	});

	// Connect all MIDI sources (required for handlers to receive messages)
	MIDIIn.connectAll;

	// Register all handlers
	~registerHandlers.();

	// Load sample buffers for Worlde pads
	~loadEasypadBuffers.();

	// Load sample buffers for SMK25 pads
	~loadSMKPadBuffers.();

	// Load backtrack MIDI mapping from config
	~loadMIDIActionMap.();

	// Load SMK25 knob map overrides from config
	~loadSMKKnobMap.();

	// Start device-watcher (reconnect detection, including BT)
	~startDeviceWatcher.();

	"[MIDI] Initialization complete.".postln;
};

// =============================================================================
// DEVICE WATCHER — hot-plug + BT reconnect detection
// =============================================================================
// Scans every 5 seconds for new/changed devices. Re-registers handlers and
// re-detects srcIDs if the device list has changed.

~deviceWatcherRoutine = nil;

~startDeviceWatcher = {
	if (~deviceWatcherRoutine.notNil, { ~deviceWatcherRoutine.stop; });
	~deviceWatcherRoutine = Routine {
		// Track device identity via set of UIDs, not count alone.
		// This catches swaps (one device leaves, another arrives) where
		// the count stays the same but the device set changes.
		var lastIDs = MIDIClient.sources.collect(_.uid).asSet;
		loop {
			5.0.wait;
			var currentIDs = MIDIClient.sources.collect(_.uid).asSet;
			if (currentIDs != lastIDs, {
				"[MIDI] Device set changed — re-detecting".postln;
				try { MIDIClient.init(verbose: false); } { |e| };
				MIDIIn.connectAll;
				// Re-detect srcIDs
				MIDIClient.sources.do { |src|
					var dev = (src.device ? "") ++ " " ++ (src.name ? "");
					if (dev.toUpper.contains(~apcDevName.toUpper))  { ~srcID_APC  = src.uid; };
					if (dev.toUpper.contains(~easyDevName.toUpper)) { ~srcID_Easy = src.uid; };
					if (dev.toUpper.contains(~smkDevName.toUpper))  { ~srcID_SMK  = src.uid; };
				};
				// Re-detect APC output for LEDs
				MIDIClient.destinations.do { |dest, i|
					var name = ((dest.device ? "") ++ " " ++ (dest.name ? "")).toUpper;
					if (name.contains(~apcDevName.toUpper), {
						~apcMidiOut = MIDIOut(i);
						"[MIDI] APC Mini output re-detected".postln;
					});
				};
				// Refresh LED state after reconnect
				if (~refreshAllLEDs.notNil, { ~refreshAllLEDs.(); });
				// Reload buffers if Easypad reconnected
				if (~srcID_Easy.notNil, { ~loadEasypadBuffers.(); });
				lastIDs = currentIDs;
			});
		}
	}.play(AppClock);
};

// =============================================================================
// HANDLER REGISTRATION
// =============================================================================
// All MIDIdef handlers guard against nil srcID: if srcID is nil, the handler
// does NOT match (MIDIdef with nil srcID = catch-all, which we avoid).
// Instead we check inside the handler body so the def still exists.

~registerHandlers = {

// =============================================================================
// SMK25 (Bluetooth) → \lanth0nVoice — melodic voice
// =============================================================================
// Polyphonic pool: up to 8 simultaneous voices. Each note spawns a new
// \lanth0nVoice Synth with the current oscillator + ADSR parameters.
// Note-off releases the corresponding synth by setting gate=0.

MIDIdef.noteOn(\smk_noteon, { |vel, note, chan, src|
	if (~srcID_SMK.isNil or: { src != ~srcID_SMK }, { ^nil });

	var freq = note.midicps;
	var args = List[
		\out,     ~synthSendBus.index,
		\freq,    freq,
		\gate,    1,
		\vel,     vel.linlin(0, 127, 0.01, 1.0),
		\amp,     ~voiceParams[\amp]     ? 0.5,
		\cutoff,  ~voiceParams[\cutoff]  ? 4000,
		\dryWet,  ~voiceParams[\dryWet]  ? 1.0,
		\attack,  ~voiceParams[\attack]  ? 0.01,
		\sustain, ~voiceParams[\sustain] ? 0.7,
		\release, ~voiceParams[\release] ? 0.3
	];

	// Add current oscillator states from apc_pads.scd
	if (~colToOscLevel.notNil and: { ~fxPadState.notNil }, {
		6.do { |col|
			args.add(~colToOscLevel[col]);
			args.add(if(~fxPadState[0][col] == \active, 1.0, 0.0));
			args.add(~colToOctDn[col]);
			args.add(if(~fxPadState[1][col] == \active, 1.0, 0.0));
			args.add(~colToOctUp[col]);
			args.add(if(~fxPadState[2][col] == \active, 1.0, 0.0));
		}
	});

	// If no oscillator is active, default to saw (musical fallback)
	var anyOscActive = if (~fxPadState.notNil, {
		6.any { |col| ~fxPadState[0][col] == \active }
	}, { false });
	if (anyOscActive.not, { args.add(\sawLevel); args.add(1.0); });

	var synth = Synth(\lanth0nVoice, args.asArray);
	~lanth0nVoices.add([note, synth]);

	// Polyphony cap: free oldest voice if over limit
	if (~lanth0nVoices.size > 8, {
		var oldest = ~lanth0nVoices.removeAt(0);
		if (oldest[1].notNil, { oldest[1].set(\gate, 0); });
	});
}, srcID: nil);   // nil srcID = accept from any source; we filter in body

// NOTE: APC Mini Notes Mode routing also writes to ~lanth0nVoices.
// Notes from APC Mini in Notes Mode use the same handler logic.

MIDIdef.noteOff(\smk_noteoff, { |vel, note, chan, src|
	if (~srcID_SMK.isNil or: { src != ~srcID_SMK }, { ^nil });

	var entry = ~lanth0nVoices.detect { |e| e[0] == note };
	if (entry.notNil, {
		~lanth0nVoices.remove(entry);
		if (entry[1].notNil, { entry[1].set(\gate, 0); });
	});
}, srcID: nil);

// Pitch bend → update freq on all active voices
MIDIdef.bend(\smk_bend, { |val, chan, src|
	if (~srcID_SMK.isNil or: { src != ~srcID_SMK }, { ^nil });
	var semis = val.linlin(0, 16383, -2.0, 2.0);
	~lanth0nVoices.do { |entry|
		if (entry[1].notNil, {
			entry[1].set(\freq, entry[0].midicps * (2 ** (semis / 12.0)));
		})
	}
}, srcID: nil);

// SMK25 Mod Wheel (CC 1) → cutoff
MIDIdef.cc(\smk_mod, { |val, ccNum, chan, src|
	if (~srcID_SMK.isNil or: { src != ~srcID_SMK }, { ^nil });
	if (ccNum == 1, {
		var cutoff = val.linexp(0, 127, 80.0, 18000.0);
		~voiceParams[\cutoff] = cutoff;
		~lanth0nVoices.do { |e| if (e[1].notNil, { e[1].set(\cutoff, cutoff); }); };
	});
}, srcID: nil);

// SMK25 knobs → effect/voice parameters (CC map from ~smkKnobMap)
MIDIdef.cc(\smk_knobs, { |val, ccNum, chan, src|
	if (~srcID_SMK.isNil or: { src != ~srcID_SMK }, { ^nil });
	if (ccNum == 1, { ^nil });   // Mod Wheel handled above

	var paramSym = ~smkKnobMap[ccNum];
	if (paramSym.isNil, { ^nil });

	var norm = val / 127.0;
	switch(paramSym,
		\lpfCutoff, {
			if (Ndef(\masterFX).notNil, { Ndef(\masterFX).set(\lpfCutoff, norm); });
		},
		\hpfCutoff, {
			if (Ndef(\masterFX).notNil, { Ndef(\masterFX).set(\hpfCutoff, norm); });
		},
		\attack, {
			var v = norm.linexp(0.0, 1.0, 0.001, 4.0);
			~voiceParams[\attack] = v;
			~lanth0nVoices.do { |e| if (e[1].notNil, { e[1].set(\attack, v); }); };
		},
		\decay, {
			var v = norm.linexp(0.0, 1.0, 0.001, 4.0);
			~voiceParams[\decay] = v;
			~lanth0nVoices.do { |e| if (e[1].notNil, { e[1].set(\decay, v); }); };
		},
		\sustain, {
			~voiceParams[\sustain] = norm;
			~lanth0nVoices.do { |e| if (e[1].notNil, { e[1].set(\sustain, norm); }); };
		},
		\release, {
			var v = norm.linexp(0.0, 1.0, 0.01, 8.0);
			~voiceParams[\release] = v;
			~lanth0nVoices.do { |e| if (e[1].notNil, { e[1].set(\release, v); }); };
		},
		\tempo, {
			var bpm = norm.linlin(0.0, 1.0, 40.0, 240.0);
			if (~setBpm.notNil, { ~setBpm.(bpm); });
		},
		\fxMix, {
			~voiceParams[\dryWet] = norm;
			~lanth0nVoices.do { |e| if (e[1].notNil, { e[1].set(\dryWet, norm); }); };
		},
		// All other keys: pass directly to masterFX Ndef
		{
			if (Ndef(\masterFX).notNil, { Ndef(\masterFX).set(paramSym, norm); });
		}
	);
}, srcID: nil);

// SMK25 pads → sample playback (same mechanism as Worlde Easypad)
MIDIdef.noteOn(\smk_pad_on, { |vel, note, chan, src|
	if (~srcID_SMK.isNil or: { src != ~srcID_SMK }, { ^nil });

	// Only route notes that are mapped as pad notes (not in the melodic range).
	// ~smkPadNoteMap is populated from config/pads_smk.json.
	var padIdx = ~smkPadNoteMap[note];
	if (padIdx.isNil, { ^nil });   // not a pad note; handled by smk_noteon below

	var buf = ~smkPadBuffers[padIdx];
	if (buf.isNil, {
		"[SMK] Pad % has no buffer assigned".format(padIdx).postln;
		^nil
	});
	var cfg = ~smkPadConfig[padIdx];
	var synth = Synth(\sampleVoice, [
		\out,     ~mainOutBus,
		\buf,     buf.bufnum,
		\vel,     vel.linlin(0, 127, 0.01, 1.0),
		\attack,  cfg[\attack]  ? 0.005,
		\decay,   cfg[\decay]   ? 0.1,
		\sustain, cfg[\sustain] ? 0.8,
		\release, cfg[\release] ? 0.3,
		\amp,     cfg[\amp]     ? 0.8
	]);
	~smkPadVoices[padIdx].add(synth);
	if (~smkPadVoices[padIdx].size > 4, {
		var oldest = ~smkPadVoices[padIdx].removeAt(0);
		if (oldest.notNil, { oldest.free; });
	});
}, srcID: nil);

// =============================================================================
// WORLDE EASYPAD 12 → sample playback
// =============================================================================
// Pads are mapped by note number (captured from calibration).
// ~easyPadNoteMap[noteNum] = padIndex (0-11), set from config.

~easyPadNoteMap = IdentityDictionary.new;  // populated by ~loadEasypadBuffers

MIDIdef.noteOn(\easy_on, { |vel, note, chan, src|
	if (~srcID_Easy.isNil or: { src != ~srcID_Easy }, { ^nil });

	var padIdx = ~easyPadNoteMap[note];
	if (padIdx.isNil, {
		"[EASY] Unmapped note=% — run calibration and set ~easyPadNoteMap".format(note).postln;
		^nil
	});

	var buf = ~easyPadBuffers[padIdx];
	if (buf.isNil, {
		"[EASY] Pad % has no buffer — assign a sample in the web interface".format(padIdx).postln;
		^nil
	});

	var cfg = ~easyPadConfig[padIdx];
	var synth = Synth(\sampleVoice, [
		\out,     ~mainOutBus,
		\buf,     buf.bufnum,
		\vel,     vel.linlin(0, 127, 0.01, 1.0),
		\attack,  cfg[\attack]  ? 0.005,
		\decay,   cfg[\decay]   ? 0.1,
		\sustain, cfg[\sustain] ? 0.8,
		\release, cfg[\release] ? 0.3,
		\amp,     cfg[\amp]     ? 0.8
	]);

	// Track for per-pad polyphony cap (4 voices per pad)
	~easyPadVoices[padIdx].add(synth);
	if (~easyPadVoices[padIdx].size > 4, {
		var oldest = ~easyPadVoices[padIdx].removeAt(0);
		if (oldest.notNil, { oldest.free; });
	});
}, srcID: nil);

// =============================================================================
// APC MINI — grid (note-on/off) + faders (CC) + Notes Mode
// =============================================================================
// The grid is split into FX pads (cols 0-5) and PC pads (cols 6-7).
// APC Mini Notes Mode (detected via program change): grid sends MIDI notes
// instead of FX/PC commands. We route those notes through the melodic voice.

// APC Mini Notes Mode program change note (from calibration; default = 99).
// When the APC Mini sends PC#99, it has entered Notes Mode.
~apcNotesModePC = 99;    // update from calibration

MIDIdef.noteOn(\apc_grid_on, { |vel, note, chan, src|
	if (~srcID_APC.isNil or: { src != ~srcID_APC }, { ^nil });
	if (note >= 64, { ^nil });   // control-row notes handled separately

	if (~apcNotesMode ? false, {
		// ── Notes Mode: route note to melodic voice ──────────────────────
		var freq = note.midicps;
		var args = List[\out, ~synthSendBus.index, \freq, freq, \gate, 1,
			\vel, vel.linlin(0, 127, 0.01, 1.0)];
		var synth = Synth(\lanth0nVoice, args.asArray);
		~apcNotesVoices.add([note, synth]);

		// Polyphony cap: free oldest APC Notes voice if over 8
		if (~apcNotesVoices.size > 8, {
			var oldest = ~apcNotesVoices.removeAt(0);
			if (oldest[1].notNil, { oldest[1].set(\gate, 0); });
		});
	}, {
		// ── Normal mode: FX pad / PC pad / loop pad / metronome pad ──────
		var col = note % 8;
		var row = note.div(8);
		if (row == 7, {
			// Metronome / loop-length row
			if (~onMetronomePadPress.notNil, { ~onMetronomePadPress.(col, row); });
		}, {
			if (row == 6, {
				// Loop track row
				if (~onLoopPadPress.notNil, { ~onLoopPadPress.(col, row); });
			}, {
				if (col < 6, {
					~onFXPadPress.(col, row);
				}, {
					~onPCPadPress.(col, row);
				});
			});
		});
	});
}, srcID: nil);

MIDIdef.noteOff(\apc_grid_off, { |vel, note, chan, src|
	if (~srcID_APC.isNil or: { src != ~srcID_APC }, { ^nil });
	if (note >= 64, { ^nil });

	if (~apcNotesMode ? false, {
		// Release Notes Mode note — search APC pool only
		var entry = ~apcNotesVoices.detect { |e| e[0] == note };
		if (entry.notNil, {
			~apcNotesVoices.remove(entry);
			if (entry[1].notNil, { entry[1].set(\gate, 0); });
		});
	}, {
		var col = note % 8;
		var row = note.div(8);
		if (row == 7, {
			// Metronome row: no release action needed
		}, {
			if (row == 6, {
				if (~onLoopPadRelease.notNil, { ~onLoopPadRelease.(col, row); });
			}, {
				if (col < 6, {
					~onFXPadRelease.(col, row);
				}, {
					~onPCPadRelease.(col, row);
				});
			});
		});
	});
}, srcID: nil);

// Notes Mode toggle via Program Change
MIDIdef.program(\apc_prog, { |prog, chan, src|
	if (~srcID_APC.isNil or: { src != ~srcID_APC }, { ^nil });
	if (prog == ~apcNotesModePC, {
		if (~apcNotesMode ? false, {
			~exitNotesMode.();
		}, {
			~enterNotesMode.();
		});
	});
}, srcID: nil);

// APC Mini faders: CC 48-55 = column faders 1-8, CC 56 = master fader 9
// Calibrate actual CC numbers and update ~apcFaderCCs if needed.
~apcFaderCCs = [48, 49, 50, 51, 52, 53, 54, 55, 56];  // indices 0-8 → faders 1-9

MIDIdef.cc(\apc_faders, { |val, ccNum, chan, src|
	if (~srcID_APC.isNil or: { src != ~srcID_APC }, { ^nil });

	var faderIdx = ~apcFaderCCs.indexOf(ccNum);
	if (faderIdx.notNil, {
		~onFaderMove.(faderIdx, val);   // defined in apc_pads.scd
	});
}, srcID: nil);

// Control-row buttons (notes 64-71 on APC Mini, from calibration)
MIDIdef.noteOn(\apc_ctrl, { |vel, note, chan, src|
	if (~srcID_APC.isNil or: { src != ~srcID_APC }, { ^nil });
	if (note >= 64, {
		"[APC] Control row note=% vel=%".format(note, vel).postln;
		// Assign specific functions here post-calibration
	});
}, srcID: nil);

// =============================================================================
// CONFIGURABLE BACKTRACK MIDI MAPPING
// =============================================================================
// Catch-all that routes any configured note/CC to a backtrack action.
// Actions: \btPlay, \btStop, \btNext, \btPrev
// Mapping is loaded from config/midi_map.json at startup.

MIDIdef.noteOn(\bt_midi_map, { |vel, note, chan, src|
	if (~midiActionMap.isNil, { ^nil });
	var srcMap = ~midiActionMap[src];
	if (srcMap.isNil, { ^nil });
	var action = srcMap[("n" ++ note).asSymbol];
	if (action.notNil and: { vel > 0 }, {
		switch(action,
			\btPlay, { ~btPlay.(); },
			\btStop, { ~btStop.(); },
			\btNext, { ~btNext.(); },
			\btPrev, { ~btPrev.(); }
		)
	});
}, srcID: nil);

MIDIdef.cc(\bt_midi_map_cc, { |val, ccNum, chan, src|
	if (~midiActionMap.isNil, { ^nil });
	var srcMap = ~midiActionMap[src];
	if (srcMap.isNil, { ^nil });
	var action = srcMap[("cc" ++ ccNum).asSymbol];
	if (action.notNil and: { val > 63 }, {
		switch(action,
			\btPlay, { ~btPlay.(); },
			\btStop, { ~btStop.(); },
			\btNext, { ~btNext.(); },
			\btPrev, { ~btPrev.(); }
		)
	});
}, srcID: nil);

};   // end ~registerHandlers

// =============================================================================
// SMK25 PAD BUFFER LOADING
// =============================================================================
// Reads pad config from config/pads_smk.json and loads sample files.

~loadSMKPadBuffers = {
	var cfgPath = ~projectDir +/+ "config/pads_smk.json";
	if (File.exists(cfgPath).not, {
		"[SMK] No pad config at % — SMK25 pads silent until configured".format(cfgPath).postln;
		^nil
	});
	var cfg;
	try { cfg = Json.parse(cfgPath); } { |err|
		"[SMK] JSONlib not available — SMK25 pad config disabled".postln; ^nil
	};
	if (cfg.notNil, {
		var pads = cfg[\pads] ? [];
		pads.do { |pad|
			var padIdx = pad[\pad];
			if (padIdx.notNil and: { padIdx >= 0 } and: { padIdx < 16 }, {
				var filePath = pad[\file];
				var note     = pad[\note];
				if (filePath.notNil and: { filePath.size > 0 }, {
					var fullPath = ~projectDir +/+ "samples" +/+ filePath;
					if (File.exists(fullPath), {
						Buffer.read(s, fullPath, action: { |buf|
							~smkPadBuffers[padIdx] = buf;
							"[SMK] Pad % → % loaded".format(padIdx, filePath).postln;
						});
					}, {
						"[SMK] Sample not found: %".format(fullPath).postln;
					});
				});
				if (note.notNil, { ~smkPadNoteMap[note] = padIdx; });
				if (pad[\attack].notNil,  { ~smkPadConfig[padIdx][\attack]  = pad[\attack]; });
				if (pad[\decay].notNil,   { ~smkPadConfig[padIdx][\decay]   = pad[\decay]; });
				if (pad[\sustain].notNil, { ~smkPadConfig[padIdx][\sustain] = pad[\sustain]; });
				if (pad[\release].notNil, { ~smkPadConfig[padIdx][\release] = pad[\release]; });
				if (pad[\amp].notNil,     { ~smkPadConfig[padIdx][\amp]     = pad[\amp]; });
			})
		}
	});
};

// =============================================================================
// EASYPAD BUFFER LOADING
// =============================================================================
// Reads pad config from config/pads_worlde.json and loads sample files.
// Called at init and on Easypad reconnect.

~loadEasypadBuffers = {
	var cfgPath = ~projectDir +/+ "config/pads_worlde.json";
	if (File.exists(cfgPath).not, {
		"[EASY] No pad config file at % — pads will be silent until configured".format(cfgPath).postln;
		^nil
	});

	// Use JSONlib if available; fall back to regex
	var cfg;
	try { cfg = Json.parse(cfgPath); } { |err|
		"[EASY] JSONlib not available — trying regex fallback".format(err).postln;
		var content = File.use(cfgPath, "r", { |f| f.readAllString });
		cfg = IdentityDictionary[\pads -> ~parsePadConfigFallback.(content)];
	};

	if (cfg.notNil, {
		var pads = cfg[\pads] ? [];
		pads.do { |pad|
			var padIdx = pad[\pad];
			if (padIdx.notNil and: { padIdx >= 0 } and: { padIdx < 12 }, {
				var filePath = pad[\file];
				var note     = pad[\note];
				if (filePath.notNil and: { filePath.size > 0 }, {
					var fullPath = ~projectDir +/+ "samples" +/+ filePath;
					if (File.exists(fullPath), {
						Buffer.read(s, fullPath, action: { |buf|
							~easyPadBuffers[padIdx] = buf;
							"[EASY] Pad % → % loaded".format(padIdx, filePath).postln;
						});
					}, {
						"[EASY] Sample not found: %".format(fullPath).postln;
					});
				});
				if (note.notNil, {
					~easyPadNoteMap[note] = padIdx;
				});
				// Load per-pad ADSR
				if (pad[\attack].notNil,  { ~easyPadConfig[padIdx][\attack]  = pad[\attack]; });
				if (pad[\decay].notNil,   { ~easyPadConfig[padIdx][\decay]   = pad[\decay]; });
				if (pad[\sustain].notNil, { ~easyPadConfig[padIdx][\sustain] = pad[\sustain]; });
				if (pad[\release].notNil, { ~easyPadConfig[padIdx][\release] = pad[\release]; });
				if (pad[\amp].notNil,     { ~easyPadConfig[padIdx][\amp]     = pad[\amp]; });
			})
		};
	});
};

// Regex fallback for Easypad config parsing (used when JSONlib is not installed)
~parsePadConfigFallback = { |content|
	var pads = List.new;
	var padMatches = content.findRegexp("\"pad\"\\s*:\\s*(\\d+)");
	padMatches.do { |m|
		var padIdx = m[1].asInteger;
		if (padIdx >= 0 and: { padIdx < 12 }, {
			var fileMatch = content.findRegexp("\"file\"\\s*:\\s*\"([^\"]+)\"");
			var noteMatch = content.findRegexp("\"note\"\\s*:\\s*(\\d+)");
			var entry = IdentityDictionary[\pad -> padIdx];
			if (fileMatch.size > 1, { entry[\file] = fileMatch[1][1]; });
			if (noteMatch.size > 1, { entry[\note] = noteMatch[1][1].asInteger; });
			pads.add(entry);
		})
	};
	pads.asArray
};

// =============================================================================
// SMK25 KNOB MAP LOADER (from config/midi_map.json \smkKnobs section)
// =============================================================================

~loadSMKKnobMap = {
	var cfgPath = ~projectDir +/+ "config/midi_map.json";
	if (File.exists(cfgPath).not, { ^nil });
	try {
		var cfg = Json.parse(cfgPath);
		var knobs = cfg[\smkKnobs];
		if (knobs.notNil, {
			knobs.do { |entry|
				var cc  = entry[\cc];
				var sym = entry[\param];
				if (cc.notNil and: { sym.notNil }, {
					~smkKnobMap[cc.asInteger] = sym.asSymbol;
				});
			};
			"[MIDI] Loaded % SMK25 knob mappings".format(knobs.size).postln;
		});
	} { |err|
		"[MIDI] Could not load SMK25 knob map: %".format(err).postln;
	};
};

// =============================================================================
// BACKTRACK MIDI ACTION MAP LOADING
// =============================================================================
// Reads config/midi_map.json. Format (simplified):
// { "mappings": [ { "srcID": 123, "type": "note", "value": 36, "action": "btPlay" } ] }

~loadMIDIActionMap = {
	var cfgPath = ~projectDir +/+ "config/midi_map.json";
	~midiActionMap = IdentityDictionary.new;
	if (File.exists(cfgPath), {
		// Attempt JSONlib, fall back to empty map
		try {
			var cfg = Json.parse(cfgPath);
			var mappings = cfg[\mappings] ? [];
			mappings.do { |m|
				var srcID   = m[\srcID];
				var type    = m[\type];
				var value   = m[\value];
				var action  = m[\action];
				if (srcID.notNil and: { type.notNil } and: { action.notNil }, {
					var srcMap = ~midiActionMap[srcID];
					if (srcMap.isNil, { srcMap = IdentityDictionary.new; ~midiActionMap[srcID] = srcMap; });
					var key = (type ++ value).asSymbol;
					srcMap[key] = action.asSymbol;
				})
			};
			"[MIDI] Loaded % backtrack MIDI mappings from %".format(mappings.size, cfgPath).postln;
		} { |err|
			"[MIDI] JSONlib not available — backtrack MIDI control disabled: %".format(err).postln;
		};
	}, {
		"[MIDI] No MIDI map config found — backtrack MIDI control disabled".postln;
	});
};

// =============================================================================
// PANIC STOP
// =============================================================================

~panicStop = {
	"!!! PANIC STOP !!!".postln;
	~btStop.();                   // stop backtrack playback
	~stopClock.();                // halt shared clock
	if (~stopAllLoops.notNil, { ~stopAllLoops.(); });  // stop all loop tracks
	// Release all active melodic voices (SMK25 pool)
	~lanth0nVoices.do { |entry|
		if (entry[1].notNil, { entry[1].set(\gate, 0); });
	};
	~lanth0nVoices.clear;
	// Release all APC Notes Mode voices
	~apcNotesVoices.do { |entry|
		if (entry[1].notNil, { entry[1].set(\gate, 0); });
	};
	~apcNotesVoices.clear;
	// Free all active sample voices
	~easyPadVoices.do { |voiceList|
		voiceList.do { |synth| if (synth.notNil, { synth.free; }); };
		voiceList.clear;
	};
	~refreshAllLEDs.();
	"PANIC: all voices stopped, clock halted.".postln;
};

