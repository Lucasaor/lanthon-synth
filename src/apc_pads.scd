// =============================================================================
// apc_pads.scd — LANTH0N 5YNTH: APC Mini FX pad + Program Change state machine
// =============================================================================
//
// Grid zones (0-indexed, row 0 = bottom, col 0 = leftmost):
//
//   Row 7 (top)              : Metronome / loop-length selector ← loops.scd
//   Row 6                    : Loop track controls (8 tracks)   ← loops.scd
//   Rows 0–5, Cols 0–5  : FX Control pads (36 pads)           ← this file
//   Rows 0–5, Cols 6–7  : Program Change pads (12 pads)       ← this file
//
//   Row | Function (FX pads)
//   ----+---------
//    0  | Oscillator selection (Sq/Saw/Sup/Sine/TB303/Noise per col 0–5)
//    1  | Octave Down
//    2  | Octave Up
//    3  | Distortion
//    4  | Delay
//    5  | Reverb
//
// FX pad states:  \off (unconfigured), \idle (yellow), \active (green)
// PC pad states:  \empty (off), \saved (purple), \active (blue)
// =============================================================================

// =============================================================================
// PAD STATE ARRAYS
// =============================================================================

// ~fxPadState[row][col]  — 6 rows × 6 columns (rows 6-7 managed by loops.scd)
~fxPadState = Array.fill(6, { Array.fill(6, { \off }) });

// All 36 FX pads start idle (configured, not active)
~initFXPadState = {
	6.do { |row|
		6.do { |col|
			~fxPadState[row][col] = \idle;
		}
	};
};

// ~pcPadState[pcIndex]   — 12 PC pads (0–11)
// pcIndex layout: col 6 = even indices, col 7 = odd
// row 0 = indices 0,1; row 1 = indices 2,3; … row 5 = indices 10,11
~pcPadState = Array.fill(12, { \empty });

// Currently active PC pad index, or nil if none.
~activePCIndex = nil;

// =============================================================================
// HOLD TIMER STATE (PC pads only — FX pad hold-to-edit mode removed)
// =============================================================================
~pcHoldRoutine = nil;
~pcHoldIndex   = nil;

// =============================================================================
// VOICE PARAMETER STATE (updated by SMK25 knobs / Mod Wheel)
// =============================================================================
// Applied to every new \lanth0nVoice Synth and updated on running voices.
~voiceParams = IdentityDictionary[
	\amp     -> 0.5,
	\cutoff  -> 4000,
	\dryWet  -> 1.0,
	\attack  -> 0.01,
	\decay   -> 0.1,
	\sustain -> 0.7,
	\release -> 0.3
];

// =============================================================================
// OSCILLATOR COLUMN MAPPING
// =============================================================================
// Maps FX grid column (0-5) → SynthDef oscillator level argument name.
// When col N's oscillator pad (row 0) is active, we set the corresponding
// level arg to 1.0 on all running \lanth0nVoice synths.

~colToOscLevel = [
	\sqLevel, \sawLevel, \supLevel, \sineLevel, \tb303Level, \noiseLevel
];
~colToOctDn = [
	\sqOctDn, \sawOctDn, \supOctDn, \sineOctDn, \tb303OctDn, \noiseOctDn
];
~colToOctUp = [
	\sqOctUp, \sawOctUp, \supOctUp, \sineOctUp, \tb303OctUp, \noiseOctUp
];

// Effect rows 3-5 → Ndef(\masterFX) active key
// Rows 0-2 = oscillators/octave doublers; rows 3-5 = effects
~rowToFXKey    = [nil, nil, nil, \dist, \delay, \rev];
~rowToActiveKey = [nil, nil, nil, \distActive, \delayActive, \revActive];

// =============================================================================
// APPLY OSCILLATOR STATE TO RUNNING SYNTHS
// =============================================================================
// Called whenever a pad in rows 0-2 changes state.
// Updates all active ~lanth0nVoices (defined in midi_routing.scd).

~applyOscState = {
	// Build argument list from current pad states
	var args = List.new;

	6.do { |col|
		var oscActive = (~fxPadState[0][col] == \active);
		var octDnActive = (~fxPadState[1][col] == \active);
		var octUpActive = (~fxPadState[2][col] == \active);

		args.add(~colToOscLevel[col]);   args.add(oscActive.asInteger.asFloat);
		args.add(~colToOctDn[col]);      args.add(octDnActive.asInteger.asFloat);
		args.add(~colToOctUp[col]);      args.add(octUpActive.asInteger.asFloat);
	};

	// Apply to both SMK25 and APC Notes Mode voice pools
	if (~lanth0nVoices.notNil, {
		~lanth0nVoices.do { |synth|
			if (synth.notNil, {
				synth.set(*args.asArray);
			})
		}
	});
	if (~apcNotesVoices.notNil, {
		~apcNotesVoices.do { |entry|
			if (entry[1].notNil, {
				entry[1].set(*args.asArray);
			})
		}
	});
};

// =============================================================================
// APPLY EFFECT STATE TO masterFX Ndef
// =============================================================================
// Called whenever an effect pad (rows 3-7) changes state.

~applyEffectState = { |row|
	var activeKey = ~rowToActiveKey[row];
	if (activeKey.notNil, {
		// Check if ANY pad in this row is active
		var anyActive = 6.detect({ |col| ~fxPadState[row][col] == \active });
		Ndef(\masterFX).set(activeKey, if(anyActive.notNil, 1, 0));
	});
};

// =============================================================================
// FX PAD PRESS HANDLER
// =============================================================================

~onFXPadPress = { |col, row|
	// Safety: only rows 0-5, cols 0-5 (rows 6-7 go to loops.scd)
	if ((col < 6) and: { row < 6 }, {
		var state = ~fxPadState[row][col];
		if (state == \active, {
			~fxPadState[row][col] = \idle;
		}, {
			if (state == \idle, { ~fxPadState[row][col] = \active; });
		});
		~updateFXPadLED.(col, row);
		if (row <= 2, { ~applyOscState.(); }, { ~applyEffectState.(row); });
	});
};

// No-op: parameter-edit via hold removed. Effect params on SMK25 knobs instead.
~onFXPadRelease = { |col, row| };

// =============================================================================
// PC PAD PRESS HANDLER
// =============================================================================
// Called by midi_routing.scd when a PC pad (cols 6-7) is pressed.
// pcIndex = row * 2 + (col - 6)

~pcCellToIndex = { |col, row|
	row * 2 + (col - 6)
};

~onPCPadPress = { |col, row|
	var pcIdx = ~pcCellToIndex.(col, row);
	if ((pcIdx >= 0) and: { pcIdx < 12 }, {
		var state = ~pcPadState[pcIdx];
		var holdIdx = pcIdx;

		// Cancel any ongoing hold timer
		if (~pcHoldRoutine.notNil, {
			~pcHoldRoutine.stop; ~pcHoldRoutine = nil;
		});

		if (state == \saved or: { state == \active }, {
			// ── Load this snapshot ───────────────────────────────────
			~loadPCSnapshot.(pcIdx);
		});

		// ── Start hold timer for save ─────────────────────────────────
		~pcHoldRoutine = Routine {
			2.0.wait;
			// Save gesture: blink blue (green) for 1 second, then save
			~pcPadState[holdIdx] = \active;   // temporarily mark active for blink
			~updatePCPadLED.(holdIdx);
			0.5.wait;
			~pcPadState[holdIdx] = \empty;    // reset for blink off
			~updatePCPadLED.(holdIdx);
			0.25.wait;
			~pcPadState[holdIdx] = \active;
			~updatePCPadLED.(holdIdx);
			0.25.wait;

			// Perform the actual save
			~savePCSnapshot.(holdIdx);
			"[APC] PC pad % saved".format(holdIdx).postln;
			~pcHoldRoutine = nil;
		}.play(AppClock);
	});
};

// =============================================================================
// PC PAD RELEASE HANDLER
// =============================================================================

~onPCPadRelease = { |col, row|
	if (~pcHoldRoutine.notNil, {
		~pcHoldRoutine.stop;
		~pcHoldRoutine = nil;
	});
};

// =============================================================================
// SNAPSHOT SAVE / LOAD
// =============================================================================

// Build a snapshot Dictionary from the current ~fxPadState.
~buildSnapshot = {
	var snap = IdentityDictionary.new;
	6.do { |row|
		6.do { |col|
			snap[(row * 6 + col).asSymbol] = ~fxPadState[row][col];
		}
	};
	snap
};

// Save the current FX state as a snapshot for the given PC index.
~savePCSnapshot = { |pcIdx|
	var snap = ~buildSnapshot.();
	~pcSnapshots[pcIdx] = snap;

	// Deactivate previous active pad
	if (~activePCIndex.notNil and: { ~activePCIndex != pcIdx }, {
		~pcPadState[~activePCIndex] = \saved;
		~updatePCPadLED.(~activePCIndex);
	});

	~pcPadState[pcIdx] = \active;
	~activePCIndex = pcIdx;
	~updatePCPadLED.(pcIdx);

	// Persist to disk
	~persistPCSnapshots.();
};

// Load a snapshot and apply it to the FX pad state.
~loadPCSnapshot = { |pcIdx|
	var snap = ~pcSnapshots[pcIdx];
	if (snap.notNil, {
		6.do { |row|
			6.do { |col|
				var key = (row * 6 + col).asSymbol;
				var state = snap[key];
				if (state.notNil, { ~fxPadState[row][col] = state; });
			}
		};

		// Deactivate previous active pad
		if (~activePCIndex.notNil and: { ~activePCIndex != pcIdx }, {
			~pcPadState[~activePCIndex] = \saved;
			~updatePCPadLED.(~activePCIndex);
		});

		~pcPadState[pcIdx] = \active;
		~activePCIndex = pcIdx;

		// Refresh all LEDs and audio engine state
		~refreshFXPadLEDs.();
		~refreshPCPadLEDs.();
		~applyOscState.();
		0.to(5).do { |row| if (row > 2, { ~applyEffectState.(row); }); };

		"[APC] PC pad % loaded".format(pcIdx).postln;
	}, {
		"[APC] PC pad % has no snapshot — press and hold to save one.".format(pcIdx).postln;
	});
};

// ~pcSnapshots array — loaded from disk or empty (12 slots)
~pcSnapshots = Array.fill(12, { nil });

// =============================================================================
// FADER HANDLER
// =============================================================================
// Faders 0-7 control loop track volumes 0-7. Fader 8 (master) = backtrack VS.

~onFaderMove = { |faderIdx, val|
	var norm = val / 127.0;
	if (faderIdx < 8, {
		if (~setLoopVolume.notNil, { ~setLoopVolume.(faderIdx, norm); });
	}, {
		if (~setVSVolume.notNil, { ~setVSVolume.(norm); });
	});
};

// =============================================================================
// NOTES MODE DETECTION
// =============================================================================
// ~apcNotesMode = true when the APC Mini is in Notes Mode.
// In Notes Mode, grid pad messages are routed to the melodic voice engine
// (same handling as SMK25), not to this FX pad state machine.
//
// Notes Mode detection: The APC Mini sends a specific Program Change message
// when switching modes. Until calibrated, we also support a runtime toggle.
// See midi_routing.scd for how this flag is set.

~apcNotesMode = false;

~enterNotesMode = {
	if (~apcNotesMode.not, {
		// Save LED snapshot before entering
		~ledSnapshotBeforeNotes = ~snapshotLEDs.();
		~apcNotesMode = true;
		// Blank all FX/PC pads while in notes mode
		64.do { |n|
			var col = n % 8; var row = n.div(8);
			~apcSendLED.(col, row, ~ledOff);
		};
		"[APC] Notes Mode entered".postln;
	})
};

~exitNotesMode = {
	if (~apcNotesMode, {
		~apcNotesMode = false;
		// Restore exact LED state from before notes mode
		~restoreLEDSnapshot.(~ledSnapshotBeforeNotes);
		~ledSnapshotBeforeNotes = nil;
		"[APC] Notes Mode exited — LED state restored".postln;
	})
};

// =============================================================================
// PERSISTENCE — save/load snapshots to JSON config file
// =============================================================================
// ~pcSnapshotsPath is set in main.scd (e.g. <project>/config/pc_snapshots.json)

~persistPCSnapshots = {
	var path = ~pcSnapshotsPath ? (thisProcess.nowExecutingPath.dirname.dirname +/+ "config/pc_snapshots.json");
	var lines = List.new;
	lines.add("{");
	lines.add("  \"snapshots\": [");
	~pcSnapshots.do { |snap, i|
		if (snap.isNil, {
			lines.add(if(i < 11, "    null,", "    null"));
		}, {
			var rows = List.new;
			rows.add("    {");
			6.do { |row|
				6.do { |col|
					var key = (row * 6 + col).asSymbol;
					var state = snap[key] ? \off;
					var isLast = (row == 5) and: { col == 5 };
					rows.add("      \"r%c%\": \"%\"".format(row, col,
						state.asString) ++ if(isLast, "", ","));
				}
			};
			rows.add(if(i < 11, "    },", "    }"));
			rows.do { |l| lines.add(l); };
		})
	};
	lines.add("  ]");
	lines.add("}");
	File.use(path, "w", { |f|
		lines.do { |l| f.write(l ++ "\n"); };
	});
	"[APC] PC snapshots saved to %".format(path).postln;
};

~loadPCSnapshotsFromDisk = {
	var path = ~pcSnapshotsPath ? (thisProcess.nowExecutingPath.dirname.dirname +/+ "config/pc_snapshots.json");
	if (File.exists(path), {
		// Use JSONlib if available; JSONlib returns a parsed structure matching
		// the JSON schema: { "snapshots": [ {...}, null, ... ] }
		var data;
		var snapshots;
		var jsonClass = \Json.asClass;   // nil when JSONlib is not installed
		if (jsonClass.notNil, {
			try { data = jsonClass.parse(path); } { |err| data = nil; };
		});
		if (data.notNil, {
			snapshots = data[\snapshots] ? [];
			snapshots.do { |snap, i|
			if (snap.notNil and: { i < 12 }, {
				// Rebuild the snapshot in IdentityDictionary format
				var snapDict = IdentityDictionary.new;
				6.do { |row|
					6.do { |col|
							var key = (row * 6 + col).asSymbol;
							var stateKey = ("r" ++ row ++ "c" ++ col).asSymbol;
							var state = snap[stateKey];
							if (state.notNil, { snapDict[key] = state.asSymbol; });
						}
					};
					~pcSnapshots[i] = snapDict;
					if (snapDict.size > 0, { ~pcPadState[i] = \saved; });
				});
			};
			"[APC] PC snapshots loaded from %".format(path).postln;
		}, {
			"[APC] JSONlib not available — cannot load PC snapshots.".postln;
		});
	}, {
		"[APC] No snapshot file at % — starting with empty PC pads".format(path).postln;
	});
};

// =============================================================================
// INIT
// =============================================================================

~initAPCPads = {
	~initFXPadState.();
	~pcSnapshots   = Array.fill(12, { nil });
	~pcPadState    = Array.fill(12, { \empty });
	~activePCIndex = nil;
	~apcNotesMode  = false;
	~loadPCSnapshotsFromDisk.();
	~refreshAllLEDs.();
	~initMetronomeRow.();   // dim-yellow until loops.scd starts the metronome
	"APC pad state machine initialized.".postln;
};
