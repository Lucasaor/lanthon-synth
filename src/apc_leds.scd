// =============================================================================
// apc_leds.scd — LANTH0N 5YNTH: APC Mini v2 LED state machine
// =============================================================================
// Drives the APC Mini v2’s 8×8 RGB LED grid.
// LEDs are set by sending MIDI note-on messages back TO the APC Mini.
//
// Grid zones (0-indexed, row 0 = bottom, col 0 = left):
//   Row 7 (top)           : Metronome / loop-length selector
//   Row 6                 : Loop track controls (8 tracks)
//   Rows 0–5, Cols 0–5   : FX Control pads (36 pads)
//   Rows 0–5, Cols 6–7   : Program Change pads (12 pads)
//
// APC Mini v2 LED color encoding (velocity values from Ableton 70-color palette):
// Verify exact values against your hardware firmware. MIDI note-on on channel 0
// sets solid colour; channel 1 sets blinking.
//
// Approximate palette positions used here:
//   0  = off
//   3  = green           (FX active, loop playing)
//   9  = dim yellow      (metronome background)
//   13 = yellow          (FX idle, loop paused)
//   17 = amber/orange    (loop waiting for downbeat)
//   5  = red             (loop recording)
//   41 = purple/violet   (PC pad saved/inactive)
//   45 = blue            (PC pad active)
//   49 = light blue/cyan (metronome rolling beat)
//   53 = bright cyan     (metronome downbeat/bar-start)
// =============================================================================

// =============================================================================
// COLOR CONSTANTS
// =============================================================================
// Solid colours (channel 0 note-on)
~ledOff            = 0;    // all zones: pad off / unconfigured
~ledGreen          = 3;    // FX pad active; loop playing
~ledYellow         = 13;   // FX pad idle; loop paused
~ledAmber          = 17;   // loop waiting for downbeat
~ledRed            = 5;    // loop recording
~ledPurple         = 41;   // PC pad saved (inactive)
~ledBlue           = 45;   // PC pad active
~ledLightBlue      = 49;   // metronome rolling beat
~ledCyan           = 53;   // metronome downbeat (bar-set start)
~ledDimYellow      = 9;    // metronome background

// =============================================================================
// MIDI OUTPUT
// =============================================================================

~apcMidiOut = nil;   // MIDIOut to the APC Mini — set by midi_routing.scd

// Send a single LED update to one pad.
// col/row are 0-indexed. Note number = row * 8 + col.
~apcSendLED = { |col, row, velocity, chan=0|
	var note = (row * 8) + col;
	if (~apcMidiOut.notNil, {
		~apcMidiOut.noteOn(chan, note, velocity);
	});
};

// =============================================================================
// PAD GRID REFERENCES
// =============================================================================

~apcNoteForCell = { |col, row| (row * 8) + col };

~apcCellForNote = { |note|
	if ((note >= 0) and: { note < 64 }, {
		[note % 8, note.div(8)]
	}, { nil })
};

// =============================================================================
// FX PAD LED UPDATE (rows 0–5, cols 0–5)
// =============================================================================

~ledForFXState = { |state|
	switch(state,
		\off,    ~ledOff,
		\idle,   ~ledYellow,
		\active, ~ledGreen,
		/* default */ ~ledOff
	)
};

~updateFXPadLED = { |col, row|
	var state = ~fxPadState[row][col];
	var vel   = ~ledForFXState.(state);
	~apcSendLED.(col, row, vel);
};

// Refresh all 36 FX pad LEDs (rows 0–5, cols 0–5).
~refreshFXPadLEDs = {
	6.do { |row|
		6.do { |col|
			~updateFXPadLED.(col, row);
		}
	}
};

// =============================================================================
// PC PAD LED UPDATE (rows 0–5, cols 6–7 — 12 pads)
// =============================================================================
// pcIndex 0–11: col = 6 + (pcIndex % 2), row = pcIndex.div(2)

~pcIndexToCell = { |pcIndex|
	var col = 6 + (pcIndex % 2);
	var row = pcIndex.div(2);
	[col, row]
};

~ledForPCState = { |state|
	switch(state,
		\empty,  ~ledOff,
		\saved,  ~ledPurple,
		\active, ~ledBlue,
		/* default */ ~ledOff
	)
};

~updatePCPadLED = { |pcIndex|
	var state = ~pcPadState[pcIndex];
	var vel   = ~ledForPCState.(state);
	var cell  = ~pcIndexToCell.(pcIndex);
	~apcSendLED.(cell[0], cell[1], vel);
};

// Refresh all 12 PC pad LEDs.
~refreshPCPadLEDs = {
	12.do { |i| ~updatePCPadLED.(i); }
};

// =============================================================================
// LOOP TRACK ROW LED UPDATE (row 6 — 8 pads, tracks 0–7)
// =============================================================================

~ledForLoopState = { |state|
	switch(state,
		\empty,     ~ledOff,
		\waiting,   ~ledAmber,
		\recording, ~ledRed,
		\playing,   ~ledGreen,
		\paused,    ~ledYellow,
		/* default */ ~ledOff
	)
};

~updateLoopTrackLED = { |track|
	var state = if (~loopState.notNil, { ~loopState[track] }, { \empty });
	var vel   = ~ledForLoopState.(state);
	~apcSendLED.(track, 6, vel);   // row 6
};

~refreshLoopTrackLEDs = {
	8.do { |i| ~updateLoopTrackLED.(i); }
};

// =============================================================================
// METRONOME ROW LED UPDATE (row 7 — 8 pads)
// =============================================================================
// rollingCol: 0–7 — which pad shows the rolling indicator
// isDownbeat: true — show brighter cyan on downbeat

~updateMetronomeRow = { |rollingCol, isDownbeat|
	8.do { |col|
		var vel;
		if (col == rollingCol, {
			vel = if (isDownbeat, { ~ledCyan }, { ~ledLightBlue });
		}, {
			vel = ~ledDimYellow;
		});
		~apcSendLED.(col, 7, vel);   // row 7
	}
};

// Initialize metronome row to all dim yellow (called at startup before metronome runs).
~initMetronomeRow = {
	8.do { |col| ~apcSendLED.(col, 7, ~ledDimYellow); }
};

// =============================================================================
// FULL GRID REFRESH
// =============================================================================
// Called after Notes Mode exit or after a full state reset.

~refreshAllLEDs = {
	~refreshFXPadLEDs.();
	~refreshPCPadLEDs.();
	~refreshLoopTrackLEDs.();
	~initMetronomeRow.();
};

// Snapshot of all 64 LED velocities before Notes Mode entry.
~ledSnapshotBeforeNotes = nil;

~snapshotLEDs = {
	var snap = Array.new(64);
	8.do { |row|
		8.do { |col|
			var vel;
			if (row == 7, {
				// Metronome row — read current value from last sent state
				vel = ~ledDimYellow;   // approximate; metronome routine will refresh
			}, {
				if (row == 6, {
					// Loop track row
					var state = if (~loopState.notNil, { ~loopState[col] }, { \empty });
					vel = ~ledForLoopState.(state);
				}, {
					if (col < 6, {
						// FX pad
						var state = if (~fxPadState.notNil, { ~fxPadState[row][col] }, { \off });
						vel = ~ledForFXState.(state);
					}, {
						// PC pad
						var pcIdx = row * 2 + (col - 6);
						var state = if (~pcPadState.notNil, { ~pcPadState[pcIdx] }, { \empty });
						vel = ~ledForPCState.(state);
					})
				})
			});
			snap.add(vel);
		}
	};
	snap
};

~restoreLEDSnapshot = { |snap|
	if (snap.notNil, {
		64.do { |n|
			var col = n % 8;
			var row = n.div(8);
			~apcSendLED.(col, row, snap[n]);
		}
	});
};

// =============================================================================
// LED TEST
// =============================================================================
~testLEDs = {
	var seq = [~ledOff, ~ledYellow, ~ledGreen, ~ledPurple, ~ledBlue, ~ledOff];
	"LED test: cycling all 64 pads through colour states...".postln;
	Routine {
		seq.do { |vel, ci|
			("  Step % / % (vel=%)".format(ci + 1, seq.size, vel)).postln;
			64.do { |n|
				var col = n % 8;
				var row = n.div(8);
				~apcSendLED.(col, row, vel);
			};
			0.4.wait;
		};
		"LED test done — restoring pad state.".postln;
		~refreshAllLEDs.();
	}.play;
};

"APC LED subsystem loaded (APC Mini v2 colour palette).".postln;
"  Set ~apcMidiOut to the APC Mini MIDIOut instance.".postln;
"  Run ~testLEDs.() to verify LED wiring.".postln;
