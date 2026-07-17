// =============================================================================
// Step 8 — Shared Clock + Click / Metronome
// =============================================================================
// A single TempoClock drives BOTH:
//   1. The click/metronome Synth (routed to ~clickOutBus, never main mix)
//   2. All loop quantization (so loop boundaries never drift from the click)
//
// Using ONE shared clock is non-negotiable per the prompt.  If separate
// clocks were used, they would inevitably drift apart over minutes of
// performance, causing audible flamming between the click and loop edges.
//
// The click is a short beep on beat 1 (higher pitch) and a quieter tick on
// beats 2, 3, 4.  This gives the drummer a clear downbeat reference.
//
// The click is routed exclusively to ~clickOutBus (bus 2-3 by default),
// which should be connected to the drummer's monitor mix, NEVER to the
// main/FOH output.  See synths.scd for bus assignments.

// =============================================================================
// CONFIGURATION
// =============================================================================

~clockBpm     = 120;        // default tempo — can be changed live
~clockBeats   = 4;          // time signature: 4/4
~clickDownbeatFreq = 1800;  // Hz — high beep for beat 1
~clickSubFreq      = 1000;  // Hz — lower tick for beats 2,3,4
~clickDuration     = 0.04;  // seconds — short and tight
~clickAmp          = 0.6;   // volume (monitor bus only)

// =============================================================================
// CLOCK SETUP
// =============================================================================

~mainClock = nil;         // the shared TempoClock instance
~clickRoutine = nil;      // the Routine that fires click Synths
~clickRunning = false;    // flag

// ----- Start the shared clock and click -----
~startClock = { |bpm|
	bpm = bpm ? ~clockBpm;
	if (~mainClock.notNil, {
		"Clock already running — stopping old clock first.".postln;
		~stopClock.();
	});

	~mainClock = TempoClock.new(bpm / 60, 0);  // bps = bpm/60
	~clockBpm = bpm;

	"Shared clock started at % BPM (%).".format(bpm, ~mainClock).postln;

	// Start the click routine.
	// We use a Routine scheduled on the clock so that each beat fires
	// precisely on the clock's grid — this guarantees the click and loop
	// quantization use the exact same timebase.
	~clickRoutine = Routine {
		var beat = 0;
		loop {
			var freq;
			// Beat 0 (downbeat) = higher pitch
			freq = if (beat == 0, { ~clickDownbeatFreq }, { ~clickSubFreq });

			// Fire the click Synth on the MONITOR bus, NOT the main bus
			Synth(\click, [
				\out,  ~clickOutBus,
				\freq, freq,
				\duration, ~clickDuration,
				\amp,  ~clickAmp
			]);

			// Advance beat counter (wraps at time signature)
			beat = (beat + 1) % ~clockBeats;

			// Wait one beat on the SHARED clock
			1.0.wait;
		}
	};

	~clickRoutine.play(~mainClock);
	~clickRunning = true;
	"Click routine started on shared clock.".postln;
};

// ----- Stop the clock and click -----
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
~setBpm = { |newBpm|
	if (~mainClock.notNil, {
		~mainClock.tempo = newBpm / 60;
	});
	~clockBpm = newBpm;
	"Tempo set to % BPM.".format(newBpm).postln;
};

// ----- Tap tempo helper -----
// Call ~tapTempo.() on each beat; after 4 taps the tempo is calculated.
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
		var newBpm = (60.0 / avgInterval).round(1);
		"Tap tempo: % BPM".format(newBpm).postln;
		~setBpm.(newBpm);
	});
};

// =============================================================================
// LOOP QUANTIZATION HOOK
// =============================================================================
// All loop record/play start/stop actions that need to be quantized to the
// beat should use ~mainClock rather than spawning independent routines.
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
