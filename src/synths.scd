// =============================================================================
// Step 1 — Core SynthDefs (low-CPU, Pi Zero 2W friendly)
// =============================================================================
// All voices are designed for minimal CPU load:
//   - Simple oscillators (Saw, Pulse, SinOsc — no wavetable lookups)
//   - Single Moog-style LPF per voice (cheaper than multi-mode SVF)
//   - Envelope generators are reused where possible via Done.freeSelf
//   - No per-voice reverb, delay, chorus, or other heavy effects
//   - Heavier FX go on shared buses via Ndef later

// -----------------------------------------------------------------------
// Global audio buses
// -----------------------------------------------------------------------
// We hard-code bus indices so other files can reference them:
//   bus 0-1  : main stereo output (→ FOH / house PA)
//   bus 2-3  : monitor/click stereo output (→ drummer's ears only)
//   bus 4-5  : shared FX send bus (reverb, delay — created later in loops.scd)
//   bus 6-7  : spare / future use
//
// Default behavior: if only stereo output is available, the click is
// hard-panned left (monitor) and main mix panned right so they can be
// split at the mixer.  This is configurable in main.scd.

~mainOutBus    = 0;   // stereo pair starting at bus 0
~clickOutBus   = 2;   // stereo pair starting at bus 2
~fxBus         = 4;   // stereo pair starting at bus 4

// -----------------------------------------------------------------------
// MELODIC VOICES
// -----------------------------------------------------------------------

// --- leadBass: general-purpose lead/bass voice ---
// Cheap saw-based voice with a resonant LPF and velocity-sensitive amp.
// Use this for both SMK25-driven leads and looped bass lines.
SynthDef(\leadBass, {
	arg out=0,          // output bus offset (stereo pair)
	freq=220,           // Hz
	gate=1,             // 1 = note on, 0 = note off → release
	vel=0.8,            // velocity 0-1 (affects amp and filter)
	atk=0.02,           // attack time (s)
	dec=0.1,            // decay time (s)
	sus=0.7,            // sustain level (0-1, multiplied by vel)
	rel=0.3,            // release time (s)
	filterCutoff=1200,  // LPF cutoff base (Hz)
	filterRes=0.3,      // LPF resonance
	filterEnvAmt=0.6,   // how much the filter envelope opens (0-1)
	filterAtk=0.03,     // filter envelope attack
	filterDec=0.15,     // filter envelope decay
	filterSus=0.4,      // filter envelope sustain level
	filterRel=0.3,      // filter envelope release
	detune=0.002,       // slight detune between the two saws for thickness
	pan=0,              // stereo pan (-1 to 1)
	amp=0.3;            // master level multiplier

	var saw1, saw2, mix, filt, env, filtEnv, sig;

	// Two slightly detuned sawtooth oscillators for a fatter sound
	saw1 = Saw.ar(freq * (1 - detune));
	saw2 = Saw.ar(freq * (1 + detune));
	mix  = (saw1 + saw2) * 0.5;

	// Amplitude envelope (velocity-sensitive)
	env = EnvGen.kr(
		Env.adsr(atk, dec, sus, rel, curve: -4),
		gate: gate,
		levelScale: vel.clip(0.01, 1.0),  // velocity scales the entire envelope
		doneAction: Done.freeSelf          // free synth when envelope finishes
	);

	// Filter envelope
	filtEnv = EnvGen.kr(
		Env.adsr(filterAtk, filterDec, filterSus, filterRel, curve: -4),
		gate: gate,
		levelScale: filterEnvAmt * vel,
		levelBias:  filterCutoff
	);

	// Apply filter
	filt = MoogFF.ar(mix, filtEnv.clip(20, 18000), filterRes.clip(0, 3.5));

	// Apply amplitude envelope and pan
	sig = filt * env * amp;

	// Detect silence and free early (belt + braces with Done.freeSelf)
	DetectSilence.ar(sig, doneAction: Done.freeSelf);

	Out.ar(out, Pan2.ar(sig, pan));
}).add;


// --- leadBassSub: sub-bass variant with sine fundamental ---
// Same architecture as leadBass but with a clean sine fundamental mixed
// with a saw for harmonics.  Good for deep bass lines that need more
// fundamental presence without muddying the filter.
SynthDef(\leadBassSub, {
	arg out=0, freq=110, gate=1, vel=0.8,
	atk=0.01, dec=0.05, sus=0.8, rel=0.4,
	filterCutoff=600, filterRes=0.2,
	filterEnvAmt=0.4, filterAtk=0.02, filterDec=0.1, filterSus=0.3, filterRel=0.4,
	sineMix=0.6,       // balance between sine (0=all saw, 1=all sine)
	detune=0.001,
	pan=0, amp=0.3;

	var saw, sine, mix, filt, env, filtEnv, sig;

	saw  = Saw.ar(freq * (1 + detune));
	sine = SinOsc.ar(freq);
	mix  = (saw * (1 - sineMix)) + (sine * sineMix);

	env = EnvGen.kr(
		Env.adsr(atk, dec, sus, rel, curve: -4),
		gate: gate,
		levelScale: vel.clip(0.01, 1.0),
		doneAction: Done.freeSelf
	);

	filtEnv = EnvGen.kr(
		Env.adsr(filterAtk, filterDec, filterSus, filterRel, curve: -4),
		gate: gate,
		levelScale: filterEnvAmt * vel,
		levelBias:  filterCutoff
	);

	filt = MoogFF.ar(mix, filtEnv.clip(20, 18000), filterRes.clip(0, 3.5));
	sig  = filt * env * amp;
	DetectSilence.ar(sig, doneAction: Done.freeSelf);
	Out.ar(out, Pan2.ar(sig, pan));
}).add;


// --- leadPad: simple pad voice (slower attack, no filter envelope) ---
// Even cheaper — just a pulse wave with a gentle LPF.  Good for sustained
// chords / background textures when polyphony budget allows.
SynthDef(\leadPad, {
	arg out=0, freq=440, gate=1, vel=0.6,
	atk=0.5, dec=0.2, sus=0.6, rel=0.8,
	filterCutoff=800, filterRes=0.2,
	pulseWidth=0.5,
	pan=0, amp=0.2;

	var osc, filt, env, sig;

	osc = Pulse.ar(freq, pulseWidth);
	filt = MoogFF.ar(osc, filterCutoff.clip(20, 18000), filterRes.clip(0, 3.5));

	env = EnvGen.kr(
		Env.adsr(atk, dec, sus, rel, curve: -2),
		gate: gate,
		levelScale: vel.clip(0.01, 1.0),
		doneAction: Done.freeSelf
	);

	sig = filt * env * amp;
	DetectSilence.ar(sig, doneAction: Done.freeSelf);
	Out.ar(out, Pan2.ar(sig, pan));
}).add;


// -----------------------------------------------------------------------
// PERCUSSION / ONE-SHOT VOICES
// -----------------------------------------------------------------------

// --- kick: electronic kick drum ---
// Sine wave with descending pitch envelope + click transient.
SynthDef(\kick, {
	arg out=0, freq=55, vel=0.8,
	clickLevel=0.15,    // amount of click/attack transient
	bodyDecay=0.4,      // body decay (s)
	pitchDrop=0.7,      // how far the pitch drops (0-1)
	pan=0, amp=0.6;

	var click, body, pitchEnv, env, sig;

	// Short noise click for attack
	click = WhiteNoise.ar(clickLevel) * EnvGen.kr(
		Env.perc(0.001, 0.008), doneAction: Done.none
	);

	// Sine body with pitch drop
	pitchEnv = EnvGen.kr(
		Env([freq * (1 + pitchDrop), freq, freq * 0.5], [0.01, bodyDecay], \exp),
		doneAction: Done.none
	);
	body = SinOsc.ar(pitchEnv);

	// Amplitude envelope
	env = EnvGen.kr(
		Env.perc(0.001, bodyDecay, curve: -6),
		levelScale: vel.clip(0.01, 1.0),
		doneAction: Done.freeSelf
	);

	sig = (click + body) * env * amp;
	Out.ar(out, Pan2.ar(sig, pan));
}).add;


// --- snare: electronic snare / clap ---
// Mix of tuned sine body + filtered noise.
SynthDef(\snare, {
	arg out=0, freq=180, vel=0.8,
	noiseLevel=0.7,
	bodyDecay=0.15,
	noiseDecay=0.2,
	filterCutoff=3000,
	pan=0, amp=0.5;

	var body, noise, bodyEnv, noiseEnv, filtNoise, sig;

	// Sine body (resonant element)
	bodyEnv = EnvGen.kr(
		Env.perc(0.002, bodyDecay, curve: -4),
		doneAction: Done.none
	);
	body = SinOsc.ar(freq) * bodyEnv;

	// Filtered noise (snare rattle)
	noiseEnv = EnvGen.kr(
		Env.perc(0.002, noiseDecay, curve: -3),
		doneAction: Done.none
	);
	noise = WhiteNoise.ar(noiseLevel);
	filtNoise = MoogFF.ar(noise, filterCutoff.clip(200, 18000), 0.4) * noiseEnv;

	// Master envelope
	sig = (body + filtNoise) * EnvGen.kr(
		Env.perc(0.001, max(bodyDecay, noiseDecay) + 0.05, curve: -4),
		levelScale: vel.clip(0.01, 1.0),
		doneAction: Done.freeSelf
	) * amp;

	Out.ar(out, Pan2.ar(sig, pan));
}).add;


// --- hihat: closed hi-hat ---
// High-pass filtered noise with very short decay.
SynthDef(\hihat, {
	arg out=0, vel=0.8,
	decay=0.06,          // very short for closed hat
	filterCutoff=7000,   // HPF cutoff
	pan=0, amp=0.35;

	var noise, env, filt, sig;

	noise = WhiteNoise.ar(1.0);
	filt  = HPF.ar(noise, filterCutoff.clip(1000, 15000));

	env = EnvGen.kr(
		Env.perc(0.001, decay, curve: -2),
		levelScale: vel.clip(0.01, 1.0),
		doneAction: Done.freeSelf
	);

	sig = filt * env * amp;
	Out.ar(out, Pan2.ar(sig, pan));
}).add;


// --- openHat: open hi-hat ---
// Same as hihat but with longer decay.
SynthDef(\openHat, {
	arg out=0, vel=0.8,
	decay=0.4,
	filterCutoff=6000,
	pan=0, amp=0.35;

	var noise, env, filt, sig;

	noise = WhiteNoise.ar(1.0);
	filt  = HPF.ar(noise, filterCutoff.clip(1000, 15000));

	env = EnvGen.kr(
		Env.perc(0.002, decay, curve: -2),
		levelScale: vel.clip(0.01, 1.0),
		doneAction: Done.freeSelf
	);

	sig = filt * env * amp;
	Out.ar(out, Pan2.ar(sig, pan));
}).add;


// --- clap: synthetic hand-clap ---
// Layered noise bursts for an 808-style clap.
SynthDef(\clap, {
	arg out=0, vel=0.8,
	decay=0.2,
	filterCutoff=2000,
	pan=0, amp=0.5;

	var noise, env, filt, sig;

	noise = WhiteNoise.ar(1.0);
	filt  = BPF.ar(noise, filterCutoff.clip(500, 8000), 0.5);

	// Two overlapping perc envelopes simulate the multi-layered clap
	env = Mix([
		EnvGen.kr(Env.perc(0.001, decay, curve: -3)),
		EnvGen.kr(Env.perc(0.015, decay * 0.7, curve: -3)),
		EnvGen.kr(Env.perc(0.03,  decay * 0.4, curve: -3))
	]);

	sig = filt * env * vel.clip(0.01, 1.0) * amp;
	DetectSilence.ar(sig, doneAction: Done.freeSelf);
	Out.ar(out, Pan2.ar(sig, pan));
}).add;


// --- rim: rimshot / sidestick ---
// Short, high-pitched pulse with noise.
SynthDef(\rim, {
	arg out=0, vel=0.8,
	freq=1200,
	decay=0.04,
	pan=0, amp=0.4;

	var pulse, noise, env, sig;

	pulse = Pulse.ar(freq, 0.1);
	noise = WhiteNoise.ar(0.3);
	env   = EnvGen.kr(
		Env.perc(0.0005, decay, curve: -4),
		levelScale: vel.clip(0.01, 1.0),
		doneAction: Done.freeSelf
	);

	sig = (pulse * 0.7 + noise * 0.3) * env * amp;
	Out.ar(out, Pan2.ar(sig, pan));
}).add;


// --- perc: generic tuned percussion (bongos, toms, etc.) ---
// Sine with pitch sweep — good for tom fills & melodic percussion.
SynthDef(\perc, {
	arg out=0, freq=200, vel=0.8,
	decay=0.3,
	pitchSweep=0.5,     // 0 = flat, 1 = strong downward sweep
	pan=0, amp=0.4;

	var sig, pitchEnv, env;

	pitchEnv = EnvGen.kr(
		Env([freq * (1 + pitchSweep), freq], [decay * 0.1], \exp),
		doneAction: Done.none
	);
	sig = SinOsc.ar(pitchEnv);

	env = EnvGen.kr(
		Env.perc(0.002, decay, curve: -4),
		levelScale: vel.clip(0.01, 1.0),
		doneAction: Done.freeSelf
	);

	sig = sig * env * amp;
	Out.ar(out, Pan2.ar(sig, pan));
}).add;


// -----------------------------------------------------------------------
// CLICK / CLICK VOICE (for metronome)
// -----------------------------------------------------------------------

// --- click: short metronome pulse ---
// Two variants: a high-pitched beep for downbeats and a lower tick for
// subdivisions.  Parameter `beepFreq` controls the pitch so the caller
// can distinguish beat 1 from other beats.
// This voice is **always** routed to ~clickOutBus, never to mainOutBus.
SynthDef(\click, {
	arg out=2,            // default = monitor bus (bus 2-3)
	freq=1200,            // Hz — use 1800 for downbeat, 800 for subdivisions
	duration=0.03,        // length of the click (s)
	amp=0.5;

	var sig, env;

	// Short sine burst with quick exponential decay
	env = EnvGen.kr(
		Env.perc(0.001, duration, curve: -4),
		doneAction: Done.freeSelf
	);

	// Mix of sine (for pitch) + a tiny noise click for attack definition
	sig = (SinOsc.ar(freq) * 0.8 + WhiteNoise.ar(0.15)) * env * amp;

	Out.ar(out, Pan2.ar(sig, 0));  // centre-panned in the monitor bus
}).add;


// =============================================================================
// Verification helper (Step 1 checkpoint)
// =============================================================================
// After booting the server and loading this file, run the following to
// confirm clean audio and check CPU headroom:
//
//   // Trigger each voice manually
//   Synth(\leadBass,  [freq: 220, vel: 0.8]);
//   Synth(\leadBassSub, [freq: 110, vel: 0.8]);
//   Synth(\leadPad,   [freq: 330, vel: 0.6]);
//   Synth(\kick,      [vel: 0.9]);
//   Synth(\snare,     [vel: 0.8]);
//   Synth(\hihat,     [vel: 0.7]);
//   Synth(\openHat,   [vel: 0.6]);
//   Synth(\clap,      [vel: 0.8]);
//   Synth(\rim,       [vel: 0.7]);
//   Synth(\perc,      [freq: 300, vel: 0.7]);
//   Synth(\click,     [freq: 1800]);  // should come through monitor bus
//
//   // Stress test: 8 simultaneous voices
//   8.do { Synth(\leadBass, [freq: (40 + (10 * _)).midicps, vel: 0.5]); };
//
//   // Check CPU
//   s.avgCPU.postln;
//   s.peakCPU.postln;
//
// Expected on a modern dev machine: < 2% avgCPU with 8 voices.
// Expected on Pi Zero 2W: < 40% avgCPU with 8 voices (leave headroom for
// Ndef routing and FX overhead added in later steps).
