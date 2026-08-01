// =============================================================================
// loops.scd — LANTH0N 5YNTH: Metronome row + 8-track loop recording engine
// =============================================================================
// Drives Row 8 (index 7, top) and Row 7 (index 6) of the APC Mini v2.
//
// Row 7 (APC index 7) — Metronome / loop-length selector
//   Dim yellow background. A single light-blue "rolling pad" advances left-to-right,
//   one step per beat. Pressing pad N sets loop length to N bars (1–8).
//
// Row 6 (APC index 6) — Loop track controls (tracks 0–7 = faders 1–8)
//   Pad states: \empty (off) → \waiting (amber) → \recording (red) → \playing (green)
//              \playing (green) → \paused (yellow) → \playing (green)
//   Hold 2 s on a recorded pad → overdub (re-record on next downbeat).
//
// All loop boundaries are quantized to bar-set downbeats via TempoClock.
// Faders 0–7 (set in apc_pads.scd / midi_routing.scd) call ~setLoopVolume.
// =============================================================================

// =============================================================================
// CONSTANTS
// =============================================================================

~loopBeatsPerBar = 4;     // 4/4 time
~loopLength      = 2;     // initial loop length in bars (1–8)
~loopNumTracks   = 8;

// =============================================================================
// STATE ARRAYS
// =============================================================================

~loopState     = Array.fill(~loopNumTracks, { \empty });
~loopBufs      = Array.fill(~loopNumTracks, { nil });
~loopRecSynth  = Array.fill(~loopNumTracks, { nil });
~loopPlaySynth = Array.fill(~loopNumTracks, { nil });
~loopAmps      = Array.fill(~loopNumTracks, { 0.8 });

// Hold-timer state for overdub detection
~loopHoldRoutine = nil;
~loopHoldTrack   = nil;

// =============================================================================
// SYNTHDEFS
// =============================================================================
// \loopRec  : captures ~synthSendBus into a pre-allocated Buffer (stereo).
// \loopPlay : loops a stereo Buffer indefinitely with volume control.

SynthDef(\loopRec, {
	arg buf=0, inputBus=4, amp=1.0;
	var sig = In.ar(inputBus, 2);
	// loop:0 stops when the buffer is full; we free this synth externally.
	RecordBuf.ar(sig * amp, buf, loop: 0, trigger: 1, doneAction: Done.none);
}).add;

SynthDef(\loopPlay, {
	arg out=0, buf=0, amp=1.0, rate=1.0;
	var sig = PlayBuf.ar(2, buf, rate * BufRateScale.kr(buf), loop: 1, doneAction: Done.none);
	Out.ar(out, sig * amp.lag(0.05));
}).add;

// =============================================================================
// BUFFER ALLOCATION
// =============================================================================

~allocLoopBuf = { |track|
	// Size the buffer to hold exactly one bar set at the current tempo.
	var clock = TempoClock.default;
	var durationSecs = ~loopLength * ~loopBeatsPerBar / clock.tempo;
	var numFrames = (durationSecs * s.sampleRate).ceil.asInteger.max(1);
	if (~loopBufs[track].notNil, {
		~loopBufs[track].free;
		~loopBufs[track] = nil;
	});
	// Allocate synchronously using AppClock; audio thread is not blocked.
	~loopBufs[track] = Buffer.alloc(s, numFrames, 2, action: { |b|
		"[LOOP] Track % buffer: % frames (%.1f s)".format(
			track, b.numFrames, b.numFrames / s.sampleRate).postln;
	});
};

// =============================================================================
// METRONOME ROW (row 7)
// =============================================================================

~metroRoutine = nil;
~metroBeat    = 0;   // current beat index within the bar set (0-based)

~startMetronome = {
	if (~metroRoutine.notNil, { ~metroRoutine.stop; ~metroRoutine = nil; });

	~metroRoutine = Routine {
		var beat = 0;
		loop {
			var totalBeats = ~loopLength * ~loopBeatsPerBar;
			var beatInSet  = beat % totalBeats;
			// Map beat position to column 0-7 over the current loop length.
			// The "last active" column is (~loopLength - 1) to stay within
			// the 8 available pads regardless of loop length.
			var maxCol   = (~loopLength - 1).clip(0, 7);
			var rollCol  = beatInSet.linlin(0, totalBeats - 1, 0, maxCol).round.asInteger;
			~metroBeat = beatInSet;
			~updateMetronomeRow.(rollCol, beatInSet == 0);

			beat = beat + 1;
			1.0.wait;   // 1 beat; TempoClock scales by tempo
		}
	}.play(TempoClock.default);
};

~stopMetronome = {
	if (~metroRoutine.notNil, { ~metroRoutine.stop; ~metroRoutine = nil; });
};

// Update the metronome row LEDs (row 7, APC index 7).
~updateMetronomeRow = { |rollingCol, isDownbeat|
	if (~apcSendLED.notNil, {
		8.do { |col|
			var vel;
			if (col == rollingCol, {
				vel = if (isDownbeat, { ~ledCyan ? 53 }, { ~ledLightBlue ? 49 });
			}, {
				vel = ~ledDimYellow ? 9;
			});
			~apcSendLED.(col, 7, vel);
		}
	});
};

// Called when user presses a metronome-row pad (from midi_routing.scd).
~onMetronomePadPress = { |col, row|
	// Pad index (0-7) → loop length (1-8 bars)
	var newLen = col + 1;
	var oldLen = ~loopLength;
	~loopLength = newLen;
	"[LOOP] Loop length set to % bar(s)".format(newLen).postln;

	// Restart metronome to reflect new length
	~startMetronome.();
	// Note: running loop buffers keep their existing content.
	// Length increase: extra bars at end will play silence until re-recorded.
	// Length decrease: playback wraps at the shorter buffer boundary.
};

// =============================================================================
// LOOP TRACK ROW (row 6)
// =============================================================================

// Dispatch a loop track pad press (called by midi_routing.scd).
~onLoopPadPress = { |col, row|
	var track = col;   // col 0-7 → tracks 0-7
	var state = ~loopState[track];
	"[LOOP] Pad press track=% state=%".format(track, state).postln;

	switch(state,
		\empty, {
			// Schedule recording at next bar-set downbeat
			~scheduleLoopRecord.(track);
		},
		\playing, {
			// Pause playback, keep recording
			~stopLoopPlayback.(track);
			~loopState[track] = \paused;
			~updateLoopTrackLED.(track);
		},
		\paused, {
			// Resume playback
			~startLoopPlayback.(track);
			~loopState[track] = \playing;
			~updateLoopTrackLED.(track);
		}
		// \waiting and \recording presses are ignored (let the cycle finish)
	);

	// Start hold timer for overdub (only if track has content)
	if (~loopHoldRoutine.notNil, { ~loopHoldRoutine.stop; ~loopHoldRoutine = nil; });
	if ((state == \playing) or: { state == \paused }, {
		var holdTrack = track;
		~loopHoldTrack = holdTrack;
		~loopHoldRoutine = Routine {
			2.0.wait;
			"[LOOP] Overdub requested for track=%".format(holdTrack).postln;
			~scheduleLoopOverdub.(holdTrack);
			~loopHoldRoutine = nil;
		}.play(AppClock);
	});
};

// Cancel hold timer on note-off.
~onLoopPadRelease = { |col, row|
	if (~loopHoldRoutine.notNil, {
		~loopHoldRoutine.stop;
		~loopHoldRoutine = nil;
	});
	~loopHoldTrack = nil;
};

// Update a single loop track LED (row 6, col = track index).
~updateLoopTrackLED = { |track|
	if (~apcSendLED.notNil and: { ~loopState.notNil }, {
		var state = ~loopState[track];
		var vel = switch(state,
			\empty,     ~ledOff      ? 0,
			\waiting,   ~ledAmber    ? 17,
			\recording, ~ledRed      ? 5,
			\playing,   ~ledGreen    ? 3,
			\paused,    ~ledYellow   ? 13,
			/* default */ 0
		);
		~apcSendLED.(track, 6, vel);
	});
};

~refreshLoopTrackLEDs = {
	~loopNumTracks.do { |i| ~updateLoopTrackLED.(i); };
};

// =============================================================================
// RECORD / PLAYBACK ENGINE
// =============================================================================

// Schedule a new recording to start at the next bar-set downbeat.
~scheduleLoopRecord = { |track|
	var clock      = TempoClock.default;
	var totalBeats = ~loopLength * ~loopBeatsPerBar;
	var curBeat    = clock.beats;
	var beatInSet  = curBeat % totalBeats;
	// Beats until the next bar-set downbeat (never 0 to avoid edge case)
	var toNext     = if (beatInSet < 0.001, { totalBeats }, { totalBeats - beatInSet });
	var startBeat  = curBeat + toNext;
	var endBeat    = startBeat + totalBeats;

	~loopState[track] = \waiting;
	~updateLoopTrackLED.(track);
	~stopLoopPlayback.(track);   // stop any existing playback
	~allocLoopBuf.(track);       // allocate fresh buffer

	"[LOOP] Track % waiting for downbeat in %.2f beats".format(track, toNext).postln;

	// Start recording at downbeat
	clock.schedAbs(startBeat, {
		if (~loopState[track] == \waiting, {
			~loopState[track] = \recording;
			~updateLoopTrackLED.(track);
			~startLoopRecording.(track);
		});
		nil
	});

	// End recording one bar set later → start playback
	clock.schedAbs(endBeat, {
		if (~loopState[track] == \recording, {
			~stopLoopRecording.(track);
			~loopState[track] = \playing;
			~updateLoopTrackLED.(track);
			Routine {
				// Tiny wait for RecordBuf to flush
				0.05.wait;
				~startLoopPlayback.(track);
			}.play(AppClock);
			"[LOOP] Track % recording complete → playing".format(track).postln;
		});
		nil
	});
};

// Schedule an overdub: same as record but doesn't stop existing playback first.
~scheduleLoopOverdub = { |track|
	~stopLoopPlayback.(track);
	~loopState[track] = \empty;   // reset so scheduleLoopRecord re-allocates
	~scheduleLoopRecord.(track);
};

~startLoopRecording = { |track|
	var buf = ~loopBufs[track];
	if (buf.notNil, {
		if (~loopRecSynth[track].notNil, { ~loopRecSynth[track].free; ~loopRecSynth[track] = nil; });
		~loopRecSynth[track] = Synth.after(s, \loopRec, [
			\buf,      buf.bufnum,
			\inputBus, ~synthSendBus.index
		]);
		"[LOOP] Track % recording started".format(track).postln;
	}, {
		"[LOOP] ERROR: no buffer for track=%".format(track).postln;
	});
};

~stopLoopRecording = { |track|
	if (~loopRecSynth[track].notNil, {
		~loopRecSynth[track].free;
		~loopRecSynth[track] = nil;
	});
};

~startLoopPlayback = { |track|
	var buf = ~loopBufs[track];
	if (buf.notNil, {
		if (~loopPlaySynth[track].notNil, { ~loopPlaySynth[track].free; ~loopPlaySynth[track] = nil; });
		~loopPlaySynth[track] = Synth(\loopPlay, [
			\out, ~mainOutBus,
			\buf, buf.bufnum,
			\amp, ~loopAmps[track]
		]);
	});
};

~stopLoopPlayback = { |track|
	if (~loopPlaySynth[track].notNil, {
		~loopPlaySynth[track].free;
		~loopPlaySynth[track] = nil;
	});
};

// Called by fader moves (fader 0-7 → track 0-7 volume).
~setLoopVolume = { |track, amp|
	~loopAmps[track] = amp;
	if (~loopPlaySynth[track].notNil, {
		~loopPlaySynth[track].set(\amp, amp);
	});
};

// =============================================================================
// STOP ALL LOOPS (for panic stop)
// =============================================================================

~stopAllLoops = {
	~loopNumTracks.do { |track|
		~stopLoopRecording.(track);
		~stopLoopPlayback.(track);
		~loopState[track] = \empty;
		if (~loopBufs[track].notNil, {
			~loopBufs[track].free;
			~loopBufs[track] = nil;
		});
	};
	~refreshLoopTrackLEDs.();
};

// =============================================================================
// INIT
// =============================================================================

~initLoops = {
	~loopState     = Array.fill(~loopNumTracks, { \empty });
	~loopBufs      = Array.fill(~loopNumTracks, { nil });
	~loopRecSynth  = Array.fill(~loopNumTracks, { nil });
	~loopPlaySynth = Array.fill(~loopNumTracks, { nil });
	~loopAmps      = Array.fill(~loopNumTracks, { 0.8 });
	~loopHoldRoutine = nil;
	~loopHoldTrack   = nil;

	~refreshLoopTrackLEDs.();
	~startMetronome.();
	"[LOOP] Loop engine initialized. Length=% bar(s), tempo=% bps".format(
		~loopLength, TempoClock.default.tempo.round(0.01)).postln;
};

// =============================================================================
