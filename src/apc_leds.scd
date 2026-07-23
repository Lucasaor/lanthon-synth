// =============================================================================
// apc_leds.scd — LANTH0N 5YNTH: APC Mini LED state machine
// =============================================================================
// Drives the APC Mini's 8×8 RGB LED grid to reflect the current pad state.
// LEDs are set by sending MIDI note-on messages back TO the APC Mini.
//
// Grid layout (0-indexed, row 0 = bottom, col 0 = left):
//   Columns 0–5 : FX Control pads (48 pads)
//   Columns 6–7 : Program Change pads (16 pads)
//
// LED color encoding (velocity values from the original APC Mini palette):
//   0  = off
//   1  = green
//   2  = green blink
//   3  = yellow / amber
//   5  = red
//   6  = red blink
//
// LANTH0N 5YNTH color scheme:
//   FX pad, unconfigured   → off       (vel 0)
//   FX pad, idle/ready     → yellow    (vel 3)
//   FX pad, active (on)    → green     (vel 1)
//   FX pad, editing params → blink grn (vel 2)   — MIDI blink flag
//   PC pad, empty          → off       (vel 0)
//   PC pad, saved/inactive → red+blink (vel 6)   ← closest to "purple" in palette
//   PC pad, currently live → green     (vel 1)   ← closest to "blue" in palette
//
// NOTE: The original APC Mini does NOT have a true purple or blue LED.
// We use red-blink for "saved PC" and green for "active PC" as the best
// available approximation. If you have an APC Mini Mk2 with full RGB, update
// the constants below to the correct velocity codes (see Mk2 MIDI docs).
// =============================================================================

// =============================================================================
// COLOR CONSTANTS
// =============================================================================

~ledOff         = 0;
~ledGreen       = 1;   // FX active
~ledGreenBlink  = 2;   // FX editing (parameter-edit mode)
~ledYellow      = 3;   // FX idle/ready
~ledRedBlink    = 6;   // PC pad saved (closest to purple in APC Mini palette)
~ledRed         = 5;   // not used in normal flow, kept for testing

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

// Convert pad (col, row) to MIDI note (0-indexed, row 0 = bottom).
~apcNoteForCell = { |col, row|
	(row * 8) + col
};

// Convert MIDI note back to [col, row], or nil if out of 8×8 range.
~apcCellForNote = { |note|
	if ((note >= 0) and: { note < 64 }, {
		[note % 8, note.div(8)]
	}, { nil })
};

// =============================================================================
// FX PAD LED UPDATE
// =============================================================================
// FX pad state is tracked in apc_pads.scd as ~fxPadState[row][col].
// Valid states:
//   \off      — pad not configured (no oscillator/effect assigned to this slot)
//   \idle     — configured, not currently active → yellow LED
//   \active   — currently on → green LED
//   \editing  — active + in parameter-edit mode → blinking green LED

~ledForFXState = { |state|
	switch(state,
		\off,     ~ledOff,
		\idle,    ~ledYellow,
		\active,  ~ledGreen,
		\editing, ~ledGreenBlink,
		/* default */ ~ledOff
	)
};

// Update a single FX pad LED from its current state.
~updateFXPadLED = { |col, row|
	var state = ~fxPadState[row][col];   // defined in apc_pads.scd
	var vel   = ~ledForFXState.(state);
	~apcSendLED.(col, row, vel);
};

// Refresh all 48 FX pad LEDs (cols 0-5, rows 0-7).
~refreshFXPadLEDs = {
	8.do { |row|
		6.do { |col|
			~updateFXPadLED.(col, row);
		}
	}
};

// =============================================================================
// PC PAD LED UPDATE
// =============================================================================
// PC pad state is tracked in apc_pads.scd as ~pcPadState[pcIndex].
// pcIndex 0-15 maps to (col 6 or 7, rows 0-7): col = 6 + (pcIndex % 2), row = pcIndex.div(2)
// Valid states:
//   \empty  — no snapshot saved → off
//   \saved  — snapshot saved, not active → red-blink (purple approximation)
//   \active — this snapshot is currently loaded → green (blue approximation)

~pcIndexToCell = { |pcIndex|
	// PC pads: column 6 = even pcIndex, column 7 = odd pcIndex
	// row 0 (bottom) = pcIndex 0,1; row 1 = pcIndex 2,3; etc.
	var col = 6 + (pcIndex % 2);
	var row = pcIndex.div(2);
	[col, row]
};

~ledForPCState = { |state|
	switch(state,
		\empty,  ~ledOff,
		\saved,  ~ledRedBlink,
		\active, ~ledGreen,
		/* default */ ~ledOff
	)
};

~updatePCPadLED = { |pcIndex|
	var state = ~pcPadState[pcIndex];    // defined in apc_pads.scd
	var vel   = ~ledForPCState.(state);
	var cell  = ~pcIndexToCell.(pcIndex);
	~apcSendLED.(cell[0], cell[1], vel);
};

// Refresh all 16 PC pad LEDs.
~refreshPCPadLEDs = {
	16.do { |i| ~updatePCPadLED.(i); }
};

// =============================================================================
// FULL GRID REFRESH
// =============================================================================
// Called after Notes Mode exit or after a full state reset.
~refreshAllLEDs = {
	~refreshFXPadLEDs.();
	~refreshPCPadLEDs.();
};

// Snapshot of all LED states before Notes Mode entry (for restoration on exit).
~ledSnapshotBeforeNotes = nil;

~snapshotLEDs = {
	var snap = Array.new(64);
	8.do { |row|
		8.do { |col|
			var state, vel;
			if (col < 6, {
				// FX pad
				state = if (~fxPadState.notNil, { ~fxPadState[row][col] }, { \off });
				vel   = ~ledForFXState.(state);
			}, {
				// PC pad
				var pcIdx = row * 2 + (col - 6);
				state = if (~pcPadState.notNil, { ~pcPadState[pcIdx] }, { \empty });
				vel   = ~ledForPCState.(state);
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
// Run ~testLEDs.() to verify the APC Mini is receiving LED updates correctly.
// All grid LEDs cycle: off → yellow → green → red-blink → off.
~testLEDs = {
	var seq = [~ledOff, ~ledYellow, ~ledGreen, ~ledRedBlink, ~ledOff];
	"LED test: cycling all 64 pads through colour states...".postln;
	Routine {
		seq.do { |vel, ci|
			("  Step % / 5 (vel=%)".format(ci + 1, vel)).postln;
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

"APC LED subsystem loaded.".postln;
"  Set ~apcMidiOut to the APC Mini MIDIOut instance.".postln;
"  Run ~testLEDs.() to verify LED wiring.".postln;
