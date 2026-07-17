// =============================================================================
// Step 5 — Loop Tracks (Ndef-based) + APC Mini Grid Control
// =============================================================================
// Each of the 8 APC Mini columns maps to one independent loop track backed
// by an Ndef.  The grid buttons control record/play/stop/mute/clear per
// track.  This file exposes functions that midi_routing.scd calls.
//
// APC Mini 8×8 Grid Layout (columns = tracks 0-7, rows bottom→top):
//
//   Row 7 (top)    [ CLEAR ]  — clear/erase loop
//   Row 6          [ unused ]
//   Row 5          [ unused ]
//   Row 4          [ unused ]
//   Row 3          [ MUTE  ]  — toggle mute
//   Row 2          [ PLAY  ]  — toggle play/stop
//   Row 1          [ REC   ]  — toggle record/overdub
//   Row 0 (bottom) [ STOP  ]  — stop (same as PLAY row, secondary trigger)
//
//   Col:  0   1   2   3   4   5   6   7
//         ↓   ↓   ↓   ↓   ↓   ↓   ↓   ↓
//       Loop1 Loop2 Loop3 Loop4 Loop5 Loop6 Loop7 Loop8
//
// NOTE: The APC Mini note numbers for the grid are determined by calibration.
// The mapping from (col, row) → MIDI note is stored in ~apcGridMap (set by
// the calibration data).  Default assumption: note = row * 8 + col (bottom-left
// is note 0), but this MUST be verified against the real controller.
//
// LED colour codes for the APC Mini (sent as note-on velocity):
//   velocity 0  = LED off
//   velocity 1  = green
//   velocity 3  = yellow / amber
//   velocity 5  = red
//   (See apc_leds.scd for the full palette and the send function.)

// =============================================================================
// GLOBALS
// =============================================================================

~numLoops     = 8;                        // one per APC Mini column
~loopBufs     = Array.fill(~numLoops, { nil });  // Buffer per loop
~loopNdefs    = Array.fill(~numLoops, { nil });  // Ndef per loop
~loopStates   = Array.fill(~numLoops, { \empty }); // state atom per loop
~loopRecSynths = Array.fill(~numLoops, { nil });   // recorder Synth per loop
~loopDuration = 16;                       // max loop length in seconds
~loopInputBus = 0;                        // bus to record from (main input)

// -----------------------------------------------------------------------
// APC Mini grid → (col, row) mapping
// -----------------------------------------------------------------------
// Populate from CONTROLS.md calibration data.  The default below assumes
// note numbers start at 0 with col-major layout (row*8 + col).
// Override after running the calibration tool.

~apcGridNoteBase = 0;  // MIDI note number of bottom-left grid button

// Convert (col, row) → expected MIDI note (col-major, bottom-left origin)
~apcNoteForCell = { |col, row|
	// Default: row 0 = bottom row of grid, col 0 = leftmost column
	~apcGridNoteBase + (row * 8) + col;
};

// Reverse: given a MIDI note, return [col, row] or nil if out of range
~apcCellForNote = { |note|
	var n = note - ~apcGridNoteBase;
	if (n >= 0 and: { n < 64 }, {
		[n % 8, (n / 8).asInteger];  // [col, row]
	}, { nil });
};

// =============================================================================
// LOOPER SYNTHDEF
// =============================================================================
// A single SynthDef handles all looper states via control parameters.
// It uses PlayBuf for playback and RecordBuf for recording, both operating
// on the same mono Buffer.  State transitions are managed externally by
// setting `playGate` and `recGate`.

SynthDef(\looper, {
	arg out = 0,
	buf = 0,            // buffer number
	inputBus = 0,       // audio bus to capture
	playGate = 0,       // 1 = playing, 0 = stopped
	recGate  = 0,       // 1 = recording, 0 = not recording
	preLevel = 1.0,     // pre-fader level (for the recorded signal)
	amp      = 1.0,     // output level (controlled by fader)
	pan      = 0.0;

	var input, playback, recSig, sig, hasContent;

	// Capture the input bus (mono)
	input = In.ar(inputBus, 1);

	// PlayBuf is always running — when playGate is 0 we silence its output.
	// loop:1 means it wraps around automatically.
	playback = PlayBuf.ar(1, buf, loop: 1);

	// RecordBuf writes to the buffer.  recGate acts as the record-enable.
	// preLevel controls the input level hitting the buffer.
	// loop:1 means it wraps and overwrites.
	RecordBuf.ar(input * preLevel, buf, recLevel: recGate, loop: 1);

	// Output routing:
	//   recGate=0, playGate=0 → silence
	//   recGate=0, playGate=1 → playback only
	//   recGate=1, playGate=0 → input monitoring (recording, not playing)
	//   recGate=1, playGate=1 → input + playback (overdub)
	sig = Select.ar(recGate, [
		playback * playGate,                // not recording
		(input * preLevel) + (playback * playGate)  // recording (or overdub)
	]);

	// Detect if buffer has content (for LED feedback)
	// We use a simple amplitude check on the playback
	hasContent = Amplitude.kr(playback, 0.1, 0.1) > 0.0001;
	SendReply.kr(Impulse.kr(4), '/loopHasContent', hasContent);

	sig = sig * amp;
	Out.ar(out, Pan2.ar(sig, pan));
}).add;

// =============================================================================
// LOOP STATE MACHINE
// =============================================================================
// States: \empty, \recording, \playing, \overdubbing, \stopped, \muted
//
// Transitions (triggered by APC grid button presses):
//
//   Row 1 (REC):
//     empty      → recording     (start recording)
//     playing    → overdubbing   (start overdub)
//     recording  → playing       (stop recording, start playback)
//     overdubbing→ playing       (stop overdub, continue playback)
//     stopped    → recording     (overwrite)
//
//   Row 2 (PLAY):
//     playing    → stopped       (stop playback)
//     stopped    → playing       (resume playback)
//     empty      → (no-op)
//     recording  → (no-op, use REC to stop recording)
//
//   Row 3 (MUTE):
//     playing    → muted
//     muted      → playing
//     recording  → muted (continue recording silently)
//     muted (was recording) → recording
//
//   Row 7 (CLEAR):
//     any state  → empty         (clear buffer, free Ndef)
//
//   Row 0 (STOP): same as PLAY row

// ----- State query helpers -----
~loopIsEmpty   = { |i| ~loopStates[i] == \empty };
~loopIsPlaying = { |i| ~loopStates[i] == \playing };
~loopIsRecording = { |i| ~loopStates[i] == \recording };
~loopIsOverdubbing = { |i| ~loopStates[i] == \overdubbing };
~loopIsStopped = { |i| ~loopStates[i] == \stopped };
~loopIsMuted   = { |i| ~loopStates[i] == \muted };
~loopHasContent = { |i|
	// A loop has content if its state is not \empty
	~loopStates[i] != \empty;
};

// ----- Core transition actions -----

~loopStartRecording = { |i|
	var buf = ~loopBufs[i];
	var ndef;
	if (buf.isNil, {
		"Loop %: no buffer allocated — cannot record".format(i).warn;
	});
	// Create or reuse Ndef
	ndef = ~loopNdefs[i];
	if (ndef.isNil, {
		ndef = Ndef(("loop" ++ i).asSymbol);
		~loopNdefs[i] = ndef;
	});
	// Configure Ndef to use the looper SynthDef
	ndef.source = \looper;
	ndef.set(\buf, buf.bufnum);
	ndef.set(\inputBus, ~loopInputBus);
	ndef.set(\recGate, 1);   // recording ON
	ndef.set(\playGate, 0);  // playback OFF (monitoring only)
	ndef.set(\preLevel, 1.0);
	ndef.set(\amp, 1.0);
	ndef.play;

	~loopStates[i] = \recording;
	"Loop % → RECORDING".format(i).postln;
	~updateAPCled(i);    // defined in apc_leds.scd
};

~loopStopRecording = { |i|
	var ndef = ~loopNdefs[i];
	if (ndef.notNil, {
		ndef.set(\recGate, 0);   // recording OFF
		ndef.set(\playGate, 1);  // playback ON
		~loopStates[i] = \playing;
		"Loop % → PLAYING".format(i).postln;
		~updateAPCled(i);
	});
};

~loopStartOverdub = { |i|
	var ndef = ~loopNdefs[i];
	if (ndef.notNil, {
		ndef.set(\recGate, 1);   // recording ON
		ndef.set(\playGate, 1);  // playback ON
		~loopStates[i] = \overdubbing;
		"Loop % → OVERDUBBING".format(i).postln;
		~updateAPCled(i);
	});
};

~loopStopOverdub = { |i|
	var ndef = ~loopNdefs[i];
	if (ndef.notNil, {
		ndef.set(\recGate, 0);   // recording OFF
		ndef.set(\playGate, 1);  // playback ON
		~loopStates[i] = \playing;
		"Loop % → PLAYING (overdub done)".format(i).postln;
		~updateAPCled(i);
	});
};

~loopTogglePlay = { |i|
	var ndef = ~loopNdefs[i];
	if (~loopIsEmpty.(i), {
		"Loop %: empty — nothing to play".format(i).postln;
	});
	if (~loopIsPlaying.(i) or: { ~loopIsOverdubbing.(i) }, {
		// Stop playback
		if (ndef.notNil, {
			ndef.set(\playGate, 0);
			ndef.set(\recGate, 0);
		});
		~loopStates[i] = \stopped;
		"Loop % → STOPPED".format(i).postln;
		~updateAPCled(i);
	}, {
		// Start playback
		if (~loopIsStopped.(i) or: { ~loopIsMuted.(i) }, {
			if (ndef.notNil, {
				ndef.set(\playGate, 1);
			});
			~loopStates[i] = \playing;
			"Loop % → PLAYING".format(i).postln;
			~updateAPCled(i);
		});
	});
};

~loopToggleMute = { |i|
	var ndef = ~loopNdefs[i];
	var prevState;
	if (~loopIsEmpty.(i), {
		"Loop %: empty — nothing to mute".format(i).postln;
	});
	if (~loopIsMuted.(i), {
		// Unmute: restore previous state
		prevState = ~loopMutePrev[i] ? \playing;
		if (ndef.notNil, { ndef.set(\amp, 1.0); });
		~loopStates[i] = prevState;
		"Loop % → UNMUTED (was %)".format(i, prevState).postln;
	}, {
		// Mute: store current state and silence
		~loopMutePrev = ~loopMutePrev ? Array.fill(~numLoops, { \playing });
		~loopMutePrev[i] = ~loopStates[i];
		if (ndef.notNil, { ndef.set(\amp, 0.0); });
		~loopStates[i] = \muted;
		"Loop % → MUTED".format(i).postln;
	});
	~updateAPCled(i);
};

~loopClear = { |i|
	var ndef = ~loopNdefs[i];
	var buf = ~loopBufs[i];
	// Stop and free the Ndef
	if (ndef.notNil, {
		ndef.stop;
		ndef.clear;
		~loopNdefs[i] = nil;
	});
	// Zero out the buffer (write silence)
	if (buf.notNil, {
		buf.zero;
	});
	~loopStates[i] = \empty;
	"Loop % → EMPTY (cleared)".format(i).postln;
	~updateAPCled(i);
};

// =============================================================================
// APC GRID BUTTON HANDLER (called from midi_routing.scd)
// =============================================================================
// This is the main dispatch function.  midi_routing.scd calls this when a
// grid note-on is received from the APC Mini.

~apcGridPress = { |note, vel|
	var cell = ~apcCellForNote.(note);
	var col, row;
	if (cell.isNil, {
		"APC grid: note % out of range — ignoring".format(note).postln;
	});
	col = cell[0];
	row = cell[1];

	// Only respond to note-on with velocity > 0 (ignore note-off)
	if (vel == 0, {
		// Note-off: ignore for latching behavior
	});

	("APC grid press: col=" ++ col ++ ", row=" ++ row ++ ", vel=" ++ vel).postln;

	switch (row,
		0, { ~loopTogglePlay.(col); },    // STOP row (same as PLAY)
		1, {                               // REC row
			switch (~loopStates[col],
				\empty,        { ~loopStartRecording.(col); },
				\playing,      { ~loopStartOverdub.(col); },
				\recording,    { ~loopStopRecording.(col); },
				\overdubbing,  { ~loopStopOverdub.(col); },
				\stopped,      { ~loopStartRecording.(col); },
				\muted,        { "Loop %: unmute before recording".format(col).postln; }
			);
		},
		2, { ~loopTogglePlay.(col); },     // PLAY row
		3, { ~loopToggleMute.(col); },     // MUTE row
		7, { ~loopClear.(col); },          // CLEAR row (top)
		{ "APC grid row %: no action assigned".format(row).postln; }
	);
};

// =============================================================================
// INITIALIZATION
// =============================================================================
// Called from main.scd after server boot and MIDI init.

~initLoops = {
	var server = s;

	"Allocating loop buffers (% × %s mono)...".format(~numLoops, ~loopDuration).postln;

	~numLoops.do { |i|
		var buf;
		// Allocate mono buffer: duration * sampleRate frames
		buf = Buffer.alloc(server, ~loopDuration * server.sampleRate, 1, {
			("Loop % buffer ready (% frames)".format(
				i, ~loopDuration * server.sampleRate
			)).postln;
		});
		~loopBufs[i] = buf;
	};

	// Initialize mute-previous-state array
	~loopMutePrev = Array.fill(~numLoops, { \playing });

	"Loop subsystem initialized.".postln;
};

// =============================================================================
// CLEANUP (for graceful shutdown)
// =============================================================================

~freeLoops = {
	~numLoops.do { |i|
		var ndef = ~loopNdefs[i];
		if (ndef.notNil, { ndef.stop; ndef.clear; });
		var buf = ~loopBufs[i];
		if (buf.notNil, { buf.free; });
	};
	~loopNdefs = Array.fill(~numLoops, { nil });
	~loopBufs  = Array.fill(~numLoops, { nil });
	~loopStates = Array.fill(~numLoops, { \empty });
	"Loop subsystem freed.".postln;
};

// =============================================================================
// VERIFICATION (Step 5 checkpoint)
// =============================================================================
// After loading loops.scd, synths.scd, apc_leds.scd, and midi_routing.scd,
// exercise the following sequence manually or via simulated MIDI:
//
//   1. Simulate pressing REC on column 0:
//        ~apcGridPress.(~apcNoteForCell.(0, 1), 127);
//      → Expect: "Loop 0 → RECORDING"
//
//   2. Simulate pressing REC again:
//        ~apcGridPress.(~apcNoteForCell.(0, 1), 127);
//      → Expect: "Loop 0 → PLAYING"
//
//   3. Simulate pressing MUTE:
//        ~apcGridPress.(~apcNoteForCell.(0, 3), 127);
//      → Expect: "Loop 0 → MUTED"
//
//   4. Simulate pressing MUTE again:
//        ~apcGridPress.(~apcNoteForCell.(0, 3), 127);
//      → Expect: "Loop 0 → UNMUTED (was playing)"
//
//   5. Simulate pressing CLEAR:
//        ~apcGridPress.(~apcNoteForCell.(0, 7), 127);
//      → Expect: "Loop 0 → EMPTY (cleared)"
//
//   6. Repeat on column 1 and confirm no cross-talk.
//
// Check state after each:
//   ~loopStates.postln;
