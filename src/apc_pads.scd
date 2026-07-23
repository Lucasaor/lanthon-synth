// =============================================================================
// apc_pads.scd — LANTH0N 5YNTH: APC Mini FX pad + Program Change state machine
// =============================================================================
//
// Grid layout (0-indexed, row 0 = bottom, col 0 = leftmost):
//
//   Columns 0–5 : FX Control pads (48 pads)
//   Columns 6–7 : Program Change pads (16 pads)
//
//   Row | Function
//   ----+---------
//    0  | Oscillator selection (col 0=Sq, 1=Saw, 2=Sup, 3=Sine, 4=TB303, 5=Noise)
//    1  | Octave Down (one layer per column's oscillator)
//    2  | Octave Up
//    3  | Distortion
//    4  | Tremolo / Envelope LFO
//    5  | Reverb
//    6  | LPF
//    7  | HPF
//
// FX pad states:
//   \off     — not configured (no action assigned)
//   \idle    — configured but not active → yellow LED
//   \active  — active (toggle on) → green LED
//   \editing — active + parameter edit mode → blinking green LED
//
// PC pad states:
//   \empty  — no snapshot saved
//   \saved  — snapshot saved, not current → red-blink LED
//   \active — current active snapshot → green LED
//
// HOLD-TO-SAVE (PC pads) and HOLD-TO-EDIT (FX pads):
//   Both use a 2-second hold timer.  Timers are non-blocking (AppClock Routine).
//   No global blocking; audio never pauses.
// =============================================================================

// =============================================================================
// PAD STATE ARRAYS
// =============================================================================

// ~fxPadState[row][col]  — 8 rows × 6 columns
~fxPadState = Array.fill(8, { Array.fill(6, { \off }) });

// Which row-0 oscillator columns are configured (set from config file or web UI)
// By default, all 6 oscillator slots are idle (configured but not active).
~initFXPadState = {
	// Row 0: all 6 oscillator slots are idle (ready to activate)
	6.do { |col| ~fxPadState[0][col] = \idle };
	// Rows 1-7: all idle (effects are present but not active)
	7.do { |row|
		if (row > 0, {
			6.do { |col| ~fxPadState[row][col] = \idle };
		})
	};
};

// ~pcPadState[pcIndex]   — 16 PC pads (0-15)
// pcIndex layout: col 6 = even indices, col 7 = odd
// row 0 = indices 0,1; row 1 = indices 2,3; ... row 7 = indices 14,15
~pcPadState = Array.fill(16, { \empty });

// Currently active PC pad index, or nil if none.
~activePCIndex = nil;

// =============================================================================
// HOLD TIMER STATE
// =============================================================================

// FX hold state: tracks if a pad is being held for parameter-edit mode.
// ~fxHoldRoutine — current hold-timer Routine
// ~fxEditingPad  — [col, row] of currently-editing pad, or nil
~fxHoldRoutine = nil;
~fxEditingPad  = nil;

// PC hold state: tracks if a PC pad is being held to save a snapshot.
~pcHoldRoutine = nil;
~pcHoldIndex   = nil;

// =============================================================================
// VOICE PARAMETER STATE (mirrors what SMK25 voices currently have)
// =============================================================================
// ~voiceParams: Dictionary of current global synth parameters.
// These are applied to every new \lanth0nVoice Synth and updated on running
// voices when faders move.
~voiceParams = IdentityDictionary[
	\amp     -> 0.5,
	\cutoff  -> 4000,
	\dryWet  -> 1.0,
	\attack  -> 0.01,
	\sustain -> 0.7,
	\release -> 0.3
];

// Fader→param mapping in normal mode (fader index 0-5 → param key)
~faderParamMap = [
	\amp, \cutoff, \dryWet, \attack, \sustain, \release
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

// Effect rows 3-7 → Ndef(\masterFX) active key + FX param table key
// Row 0 = osc, 1 = octDn, 2 = octUp, 3-7 = effects
~rowToFXKey = [nil, nil, nil, \dist, \env, \rev, \lpf, \hpf];
~rowToActiveKey = [nil, nil, nil, \distActive, \envActive, \revActive, \lpfActive, \hpfActive];

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
// Called by midi_routing.scd when an APC Mini grid button is pressed
// (note-on with velocity > 0) in normal (non-Notes-Mode) mode.

~onFXPadPress = { |col, row|
	// Safety: only handle cols 0-5, rows 0-7
	if ((col < 6) and: { row < 8 }, {

		// --- Cancel any ongoing hold timer for this pad ---
		if (~fxHoldRoutine.notNil, {
			~fxHoldRoutine.stop; ~fxHoldRoutine = nil;
		});

		var state = ~fxPadState[row][col];

		if (state == \editing, {
			// ── Exit parameter-edit mode ────────────────────────────────
			~fxPadState[row][col] = \active;
			~fxEditingPad = nil;
			~faderMode = \normal;
			~updateFXPadLED.(col, row);
			"[APC] Param edit exited for (%, %)".format(col, row).postln;

		}, {
			// ── Toggle idle ↔ active ────────────────────────────────────
			if (state == \active, {
				~fxPadState[row][col] = \idle;
			}, {
				if (state == \idle, { ~fxPadState[row][col] = \active; });
			});

			~updateFXPadLED.(col, row);

			// Apply the new state to audio engine
			if (row == 0, {
				// Oscillator row
				~applyOscState.();
			}, {
				if (row <= 2, {
					// Octave rows
					~applyOscState.();
				}, {
					// Effect rows 3-7
					~applyEffectState.(row);
				})
			});

			// ── Start hold timer for parameter-edit mode ─────────────
			if (~fxPadState[row][col] == \active, {
				var holdCol = col;
				var holdRow = row;
				~fxHoldRoutine = Routine {
					2.0.wait;  // 2-second hold threshold
					// Only enter edit mode if pad is still active and being held
					if (~fxPadState[holdRow][holdCol] == \active, {
						~fxPadState[holdRow][holdCol] = \editing;
						~fxEditingPad = [holdCol, holdRow];
						~faderMode = \editing;
						~updateFXPadLED.(holdCol, holdRow);
						"[APC] Param edit mode for (%, %)".format(holdCol, holdRow).postln;
					});
					~fxHoldRoutine = nil;
				}.play(AppClock);
			});
		});
	});
};

// =============================================================================
// FX PAD RELEASE HANDLER
// =============================================================================
// Called on note-off for FX pads — cancels the hold timer if not yet expired.

~onFXPadRelease = { |col, row|
	if (~fxHoldRoutine.notNil, {
		~fxHoldRoutine.stop;
		~fxHoldRoutine = nil;
	});
};

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
	if ((pcIdx >= 0) and: { pcIdx < 16 }, {

		// Cancel any ongoing hold timer
		if (~pcHoldRoutine.notNil, {
			~pcHoldRoutine.stop; ~pcHoldRoutine = nil;
		});

		var state = ~pcPadState[pcIdx];

		if (state == \saved or: { state == \active }, {
			// ── Load this snapshot ───────────────────────────────────
			~loadPCSnapshot.(pcIdx);
		});

		// ── Start hold timer for save ─────────────────────────────────
		var holdIdx = pcIdx;
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
	8.do { |row|
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
		8.do { |row|
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
		0.to(7).do { |row| if (row > 2, { ~applyEffectState.(row); }); };

		"[APC] PC pad % loaded".format(pcIdx).postln;
	}, {
		"[APC] PC pad % has no snapshot — press and hold to save one.".format(pcIdx).postln;
	});
};

// ~pcSnapshots array — loaded from disk or empty
~pcSnapshots = Array.fill(16, { nil });

// =============================================================================
// FADER MODE
// =============================================================================
// \normal   — faders 0-5 control voice params, faders 6-8 control backtracks
// \editing  — faders 0-5 control the editing pad's effect params
~faderMode = \normal;

// When fader moves in normal mode, update voice parameter.
// faderIdx: 0-5 = voice params, 6 = VS vol, 7 = click vol, 8 = cue vol
~onFaderMove = { |faderIdx, val|
	// val is 0-127 (raw CC), normalized to 0.0-1.0
	var norm = val / 127.0;

	if (faderIdx <= 5, {
		if (~faderMode == \editing and: { ~fxEditingPad.notNil }, {
			// ── Parameter edit mode ─────────────────────────────────────
			var col = ~fxEditingPad[0];
			var row = ~fxEditingPad[1];
			var fxKey = ~rowToFXKey[row];
			if (fxKey.notNil, {
				var paramTable = ~fxParamTable[fxKey];   // defined in synths.scd
				if (paramTable.notNil and: { faderIdx < paramTable.size }, {
					var paramEntry = paramTable[faderIdx];
					var paramKey = paramEntry[0];
					Ndef(\masterFX).set(paramKey, norm);
					// "[APC] FX param %=%.2f".format(paramKey, norm).postln;
				})
			})
		}, {
			// ── Normal mode ─────────────────────────────────────────────
			var paramKey = ~faderParamMap[faderIdx];
			if (paramKey.notNil, {
				var scaledVal = switch(paramKey,
					\amp,     norm,
					\cutoff,  norm.linexp(0.0, 1.0, 80.0, 18000.0),
					\dryWet,  norm,
					\attack,  norm.linexp(0.0, 1.0, 0.001, 4.0),
					\sustain, norm,
					\release, norm.linexp(0.0, 1.0, 0.01, 8.0),
					norm
				);
				~voiceParams[paramKey] = scaledVal;
				// Apply to both voice pools (SMK25 + APC Notes Mode)
				if (~lanth0nVoices.notNil, {
					~lanth0nVoices.do { |synth|
						if (synth.notNil, { synth.set(paramKey, scaledVal); })
					}
				});
				if (~apcNotesVoices.notNil, {
					~apcNotesVoices.do { |entry|
						if (entry[1].notNil, { entry[1].set(paramKey, scaledVal); })
					}
				});
			})
		})
	}, {
		// ── Backtrack / click / cue volume faders (6-8) ─────────────────
		// Always active regardless of fader mode.
		switch(faderIdx,
			6, { if (~setVSVolume.notNil, { ~setVSVolume.(norm); }); },
			7, { if (~setClickVolume.notNil, { ~setClickVolume.(norm); }); },
			8, { if (~setCueVolume.notNil, { ~setCueVolume.(norm); }); }
		)
	})
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
	// Convert ~pcSnapshots to a JSON-compatible structure and write to disk.
	// SC doesn't have a built-in JSON writer, so we write a minimal valid JSON.
	var path = ~pcSnapshotsPath ? (thisProcess.nowExecutingPath.dirname.dirname +/+ "config/pc_snapshots.json");
	var lines = List.new;
	lines.add("{");
	lines.add("  \"snapshots\": [");
	~pcSnapshots.do { |snap, i|
		if (snap.isNil, {
			lines.add(if(i < 15, "    null,", "    null"));
		}, {
			var rows = List.new;
			rows.add("    {");
			8.do { |row|
				6.do { |col|
					var key = (row * 6 + col).asSymbol;
					var state = snap[key] ? \off;
					rows.add("      \"r%c%\": \"%\"".format(row, col,
						state.asString) ++ if(row < 7 or: { col < 5 }, ",", ""));
				}
			};
			rows.add(if(i < 15, "    },", "    }"));
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
		try {
			data = Json.parse(path);
			var snapshots = data[\snapshots] ? [];
			snapshots.do { |snap, i|
				if (snap.notNil and: { i < 16 }, {
					// Rebuild the snapshot in IdentityDictionary format
					var snapDict = IdentityDictionary.new;
					8.do { |row|
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
		} { |err|
			"[APC] JSONlib not available — cannot load PC snapshots: %".format(err).postln;
		};
	}, {
		"[APC] No snapshot file at % — starting with empty PC pads".format(path).postln;
	});
};

// =============================================================================
// INIT
// =============================================================================

~initAPCPads = {
	~initFXPadState.();
	~pcSnapshots = Array.fill(16, { nil });
	~pcPadState  = Array.fill(16, { \empty });
	~activePCIndex = nil;
	~fxEditingPad = nil;
	~faderMode = \normal;
	~apcNotesMode = false;
	~loadPCSnapshotsFromDisk.();
	~refreshAllLEDs.();
	"APC pad state machine initialized.".postln;
};
