// =============================================================================
// Step 7 — APC Mini LED Feedback
// =============================================================================
// Drives the APC Mini's RGB grid LEDs to reflect real loop state so the
// performer can see what's happening at a glance without looking at a screen.
//
// LED colours are set by sending MIDI note-on messages back TO the APC Mini
// with specific velocity values that map to its built-in colour palette.
//
// APC Mini LED colour palette (velocity → colour):
//   vel 0  = off (LED dark)
//   vel 1  = green
//   vel 2  = green (blinking) — not used here to keep things simple
//   vel 3  = yellow / amber
//   vel 4  = yellow (blinking)
//   vel 5  = red
//   vel 6  = red (blinking)
//
// We map loop states to colours as follows:
//   \empty       → off (vel 0)
//   \recording   → red (vel 5)
//   \overdubbing → red (vel 5) — same as recording, performer knows context
//   \playing     → green (vel 1)
//   \stopped     → amber (vel 3) — has content but not playing
//   \muted       → amber (vel 3) — has content but silenced
//
// For the REC row (row 1), we always show red when a loop has content
// (so the performer knows which columns are "armed-able"), dimmed when empty.

// =============================================================================
// MIDI OUTPUT TO APC MINI
// =============================================================================
// We need a MIDIOut connected to the APC Mini to send LED updates.
// The MIDIOut port is set up in midi_routing.scd / main.scd.

~apcMidiOut = nil;   // MIDIOut instance — set during init

// Colour constants (velocity values)
~ledOff    = 0;
~ledGreen  = 1;
~ledAmber  = 3;
~ledRed    = 5;

// State → LED colour mapping
~ledColorForState = { |state|
	switch (state,
		\empty,        ~ledOff,
		\recording,    ~ledRed,
		\overdubbing,  ~ledRed,
		\playing,      ~ledGreen,
		\stopped,      ~ledAmber,
		\muted,        ~ledAmber,
		~ledOff  // fallback
	);
};

// =============================================================================
// LED UPDATE FUNCTIONS
// =============================================================================

// Send a single LED update to a specific (col, row) on the APC Mini grid.
// The APC Mini listens for note-on messages on its own MIDI channel.
// Channel is typically channel 1 (MIDI channel 0 in SC's 0-based indexing).
~apcSendLED = { |col, row, velocity, chan=0|
	var note = ~apcNoteForCell.(col, row);
	if (~apcMidiOut.notNil, {
		~apcMidiOut.noteOn(chan, note, velocity);
	});
};

// Update ALL LEDs for a given loop column based on its current state.
// This is called after every state transition in loops.scd.
~updateAPCled = { |loopIndex|
	var col = loopIndex;
	var state = ~loopStates[loopIndex];
	var color = ~ledColorForState.(state);

	// Row 0 (STOP)  → same as PLAY indicator
	// Row 1 (REC)   → red if has content, off if empty
	// Row 2 (PLAY)  → green if playing/overdubbing, amber if stopped, off if empty
	// Row 3 (MUTE)  → amber if muted, off otherwise
	// Row 7 (CLEAR) → always dim green (available)
	// Other rows    → off

	// REC row: always lit red if the loop has content (to indicate it can be
	// re-recorded or overdubbed), off if empty.
	if (state == \empty, {
		~apcSendLED.(col, 1, ~ledOff);
	}, {
		~apcSendLED.(col, 1, ~ledRed);
	});

	// PLAY / STOP rows
	switch (state,
		\playing,      {
			~apcSendLED.(col, 0, ~ledGreen);
			~apcSendLED.(col, 2, ~ledGreen);
		},
		\overdubbing,  {
			~apcSendLED.(col, 0, ~ledGreen);
			~apcSendLED.(col, 2, ~ledGreen);
		},
		\recording,    {
			~apcSendLED.(col, 0, ~ledRed);
			~apcSendLED.(col, 2, ~ledRed);
		},
		\stopped,      {
			~apcSendLED.(col, 0, ~ledAmber);
			~apcSendLED.(col, 2, ~ledAmber);
		},
		\muted,        {
			~apcSendLED.(col, 0, ~ledOff);
			~apcSendLED.(col, 2, ~ledAmber);
		},
		\empty,        {
			~apcSendLED.(col, 0, ~ledOff);
			~apcSendLED.(col, 2, ~ledOff);
		}
	);

	// MUTE row
	if (state == \muted, {
		~apcSendLED.(col, 3, ~ledAmber);
	}, {
		~apcSendLED.(col, 3, ~ledOff);
	});

	// CLEAR row — always lit green (available action)
	~apcSendLED.(col, 7, ~ledGreen);

	// Rows 4-6: off (unused)
	[4, 5, 6].do { |r| ~apcSendLED.(col, r, ~ledOff); };
};

// Update ALL LEDs for ALL 8 columns — called on init and after clear-all.
~refreshAllLEDs = {
	~numLoops.do { |i| ~updateAPCled.(i); };
};

// =============================================================================
// LED TEST (confirms MIDI output wiring)
// =============================================================================
// Run this to verify the APC Mini is receiving LED updates correctly.
// All grid LEDs should cycle through off → green → amber → red → off.

~testLEDs = {
	var colors = [~ledOff, ~ledGreen, ~ledAmber, ~ledRed, ~ledOff];
	"LED test: cycling all grid buttons through colours...".postln;
	Routine {
		colors.do { |color, ci|
			("  Colour % / 5".format(ci + 1)).postln;
			64.do { |n|
				var col = n % 8;
				var row = (n / 8).asInteger;
				~apcSendLED.(col, row, color);
			};
			0.5.wait;
		};
		"LED test complete — restoring loop state LEDs.".postln;
		~refreshAllLEDs.();
	}.play;
};

"APC LED subsystem loaded.".postln;
"  ~apcMidiOut must be set to the APC Mini MIDIOut instance.".postln;
"  Run ~testLEDs.() to verify LED wiring.".postln;
