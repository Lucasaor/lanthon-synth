// =============================================================================
// Step 8 — Shared Clock + Click / Metronome
// =============================================================================
// A single TempoClock drives ALL timing:
//   1. The click/metronome \click Synth (routed to ~iemOutBus, NEVER FOH)
//   2. Any synth quantization that needs beat alignment
//
// Tempo is set from the active song's metadata (tempo field in the setlist JSON).
// It is NEVER inferred from audio content — the setlist is the authority.
// The OLED daemon is notified on every tempo change via ~oledUpdate (defined
// in backtrack.scd — called here if it exists).

// =============================================================================
// CONFIGURATION
// =============================================================================

~clockBpm             = 120;        // default tempo before a setlist is loaded
~clockBeats           = 4;          // time signature numerator (4/4)
~clickDownbeatFreq    = 1800;       // Hz — high beep for beat 1
~clickSubFreq         = 1000;       // Hz — lower tick for beats 2,3,4
~clickDuration        = 0.04;       // seconds — short and tight
~clickAmp             = 0.6;        // click volume (monitor bus only)

// =============================================================================
// CLOCK SETUP
// =============================================================================

~mainClock    = nil;
~clickRoutine = nil;
~clickRunning = false;

~startClock = { |bpm|
	bpm = bpm ? ~clockBpm;
	if (~mainClock.notNil, {
		"Clock already running — stopping old instance first.".postln;
		~stopClock.();
	});

	~mainClock = TempoClock.new(bpm / 60, 0);
	~clockBpm  = bpm;
	"Shared clock started at % BPM".format(bpm).postln;

	~clickRoutine = Routine {
		var beat = 0;
		loop {
			var freq = if (beat == 0, { ~clickDownbeatFreq }, { ~clickSubFreq });
			// Click goes to IEM bus ONLY — confirmed by hardcoding ~iemOutBus here.
			// If ~iemOutBus is nil (rare edge case), skip the click rather than crash.
			if (~iemOutBus.notNil, {
				Synth(\click, [
					\out,      ~iemOutBus,
					\freq,     freq,
					\duration, ~clickDuration,
					\amp,      ~clickAmp
				]);
			});
			beat = (beat + 1) % ~clockBeats;
			1.0.wait;
		}
	};
	~clickRoutine.play(~mainClock);
	~clickRunning = true;
	"Click routine started on shared clock.".postln;
};

~stopClock = {
	if (~clickRoutine.notNil, {
		~clickRoutine.stop;
		~clickRoutine = nil;
		~clickRunning = false;
		"Click routine stopped.".postln;
	});
	if (~mainClock.notNil, {
		~mainClock.stop;
		~mainClock = nil;
		"Shared clock stopped.".postln;
	});
};

// ----- Change tempo while running -----
// This is the ONLY function that should change ~mainClock.tempo.
// It is called by backtrack.scd when a new song is selected.
~setBpm = { |newBpm|
	newBpm = newBpm.clip(20.0, 300.0);
	if (~mainClock.notNil, {
		~mainClock.tempo = newBpm / 60.0;
	});
	~clockBpm = newBpm;
	"Tempo set to % BPM".format(newBpm).postln;
	// Notify OLED daemon if the update function exists (defined in backtrack.scd)
	if (~oledUpdate.notNil, { ~oledUpdate.(); });
};

// ----- Tap tempo helper -----
// Call ~tapTempo.() four times on the beat; BPM is calculated from the last 4 taps.
~tapCount = 0;
~tapTimes = Array.newClear(4);
~tapTempo = {
	var now = Main.elapsedTime;
	~tapTimes[~tapCount % 4] = now;
	~tapCount = ~tapCount + 1;
	if (~tapCount >= 4, {
		var intervals = Array.fill(3, { |i|
			~tapTimes[(~tapCount - 3 + i) % 4] - ~tapTimes[(~tapCount - 4 + i) % 4];
		});
		var avgInterval = intervals.sum / 3;
		var newBpm = (60.0 / avgInterval).round(0.5);
		"Tap tempo: % BPM".format(newBpm).postln;
		~setBpm.(newBpm);
	});
};

// =============================================================================
// QUANTIZATION HOOK
// =============================================================================
// Use ~mainClock for any beat-synchronized scheduling.
// Example:
//   ~mainClock.schedAbs(~mainClock.nextBar, { /* action on next bar */ });
// =============================================================================
//
// When a loop action requires quantization, the loops.scd functions call
// ~scheduleQuantized, which schedules the action on the next beat boundary
// (or nearest subdivision) of ~mainClock.

~scheduleQuantized = { |action, quant=1.0|
	// Schedule `action` on the shared clock, quantized to `quant` beats.
	// quant=1.0 means "on the next beat"
	// quant=0.25 means "on the next 16th note"
	if (~mainClock.notNil, {
		~mainClock.sched(0, { action.(); nil; });  // sched(0, ...) quantizes
		// Note: sched(0, func) schedules relative to the clock's next quant
		// boundary.  For precise quantization, we use:
		~mainClock.play({ action.(); }, quant);
	}, {
		// No clock running — execute immediately
		"Warning: no clock — executing action immediately (unquantized).".postln;
		action.();
	});
};

// =============================================================================
// VERIFICATION (Step 8 checkpoint)
// =============================================================================
// 1. Start the clock:
//      ~startClock.(120);
//    → Should hear click through monitor bus, NOT main bus.
//
// 2. Change tempo:
//      ~setBpm.(90);
//    → Click should immediately change tempo.
//
// 3. Verify loop quantization:
//      ~startClock.(120);
//      // Start a loop recording on column 0
//      ~apcGridPress.(~apcNoteForCell.(0, 1), 127);
//      // Wait a few beats, then stop recording
//      ~apcGridPress.(~apcNoteForCell.(0, 1), 127);
//    → Loop edges should align perfectly with click beats.
//    → Listen for several minutes — no drift should be audible.
//
// 4. Stop the clock:
//      ~stopClock.();
//    → Click should stop, clock should be freed.
//
// 5. CPU check during click:
//      s.avgCPU.postln;
//    → Click alone should add negligible CPU (< 0.5% on dev machine).
