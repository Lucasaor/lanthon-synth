// =============================================================================
// synths.scd — LANTH0N 5YNTH: SynthDef library
// =============================================================================
// Defines ALL audio SynthDefs for the rig:
//   \lanth0nVoice  — main melodic voice (all oscillators + doublers in one Def)
//   \masterFX      — shared effect chain (dist, reverb, LPF, HPF) as Ndef
//   \sampleVoice   — Worlde pad one-shot disk-streaming sample player
//   \backtrackVS   — VS (main backtrack) disk-streaming player → FOH
//   \backtrackIEM  — Click/Dica disk-streaming player → IEM
//   \click         — metronome click → IEM only
//
// CPU strategy:
//   - All oscillator mixing happens inside a single SynthDef per voice.
//     This keeps the total Synth count low (~8 voices max).
//   - Effects run on a shared Ndef that reads from ~synthSendBus.
//     No per-voice reverb, LPF, or HPF.
//   - Lag(.., 0.02) smooths parameter changes from fader/pad events.
//   - DiskIn/VDiskIn is used for all media files — nothing is preloaded to RAM.
//
// Bus layout (fixed indices):
//   bus 0–1  : FOH main output (→ speaker/PA)
//   bus 2–3  : IEM monitor output (→ click + cue only)
//   bus 4–5  : synth send bus  (voice SynthDefs → masterFX Ndef)

~mainOutBus    = 0;
~iemOutBus     = 2;
~synthSendBus  = nil;   // allocated as a private Bus in main.scd after boot

// =============================================================================
// MELODIC VOICE — \lanth0nVoice
// =============================================================================
// Single SynthDef that mixes all six oscillator types.  Per-voice CPU cost is
// predictable and fixed regardless of which oscillators are active, because all
// branches always run; inactive oscillators are multiplied by 0 (Lag-smoothed).
//
// Oscillator columns (matching APC Mini columns 1-6, 0-indexed 0-5):
//   col 0 → Square (Pulse)
//   col 1 → Saw
//   col 2 → SuperSaw (4 detuned saws, scaled to mono-width)
//   col 3 → Sine
//   col 4 → TB-303 (Saw + self-resonant filter w/ envelope)
//   col 5 → White Noise
//
// Octave doublers: each column has an independent octave-down and octave-up
//   additive layer. sqOctDn=1 mixes in a square one octave below column 0's
//   base freq. Values are Lag-smoothed so live toggling doesn't click.
//
// Faders in normal mode map to: amp, cutoff, dryWet, attack, sustain, release.
// These map directly to the SynthDef args so running voices can be updated live
// via synth.set() without any additional bookkeeping.

SynthDef(\lanth0nVoice, {
	arg out=4,              // default = ~synthSendBus (set at runtime)
	freq=440, gate=1, vel=0.8,
	// --- Oscillator levels (0=off, 1=full, smoothed by lag) ---
	sqLevel=0, sawLevel=0, supLevel=0, sineLevel=0, tb303Level=0, noiseLevel=0,
	// --- Octave doublers (per column, 0=off, 1=on) ---
	sqOctDn=0, sqOctUp=0,
	sawOctDn=0, sawOctUp=0,
	supOctDn=0, supOctUp=0,
	sineOctDn=0, sineOctUp=0,
	tb303OctDn=0, tb303OctUp=0,
	noiseOctDn=0, noiseOctUp=0,
	// --- Global ADSR + tone ---
	attack=0.01, sustain=0.7, release=0.3,
	cutoff=4000,            // pre-LPF cutoff on the voice (not the FX chain LPF)
	dryWet=1.0,             // mix level into the send bus
	amp=0.5;                // master amplitude (Fader 1 maps here)

	var lagT = 0.02;        // lag time for all level params (prevents clicks)

	// ── Square (Pulse 50%) ───────────────────────────────────────────────
	var sq  = Pulse.ar(freq);
	var sqD = Pulse.ar(freq * 0.5) * sqOctDn.lag(lagT);
	var sqU = Pulse.ar(freq * 2.0) * sqOctUp.lag(lagT);
	var sqMix = (sq + sqD + sqU) * sqLevel.lag(lagT);

	// ── Saw ──────────────────────────────────────────────────────────────
	var sw  = Saw.ar(freq);
	var swD = Saw.ar(freq * 0.5) * sawOctDn.lag(lagT);
	var swU = Saw.ar(freq * 2.0) * sawOctUp.lag(lagT);
	var swMix = (sw + swD + swU) * sawLevel.lag(lagT);

	// ── SuperSaw (4 detuned saws, cheaper than the classic 7-osc) ───────
	var sup = Mix.ar(Array.fill(4, { |i|
		Saw.ar(freq * (1 + ((i - 1.5) * 0.007)))
	})) * 0.25;
	var supD = Saw.ar(freq * 0.5) * supOctDn.lag(lagT);
	var supU = Saw.ar(freq * 2.0) * supOctUp.lag(lagT);
	var supMix = (sup + supD + supU) * supLevel.lag(lagT);

	// ── Sine ─────────────────────────────────────────────────────────────
	var si  = SinOsc.ar(freq);
	var siD = SinOsc.ar(freq * 0.5) * sineOctDn.lag(lagT);
	var siU = SinOsc.ar(freq * 2.0) * sineOctUp.lag(lagT);
	var siMix = (si + siD + siU) * sineLevel.lag(lagT);

	// ── TB-303 (Saw → resonant filter w/ short attack accent) ───────────
	// The accent envelope is internal — it opens the filter briefly on each
	// note-on, giving the characteristic "acid" bite.
	var tbSaw = Saw.ar(freq);
	var tbEnv = EnvGen.kr(Env.perc(0.01, 0.2), gate: Trig.kr(gate, 0.001));
	var tbFilt = MoogFF.ar(tbSaw, (cutoff * (1 + tbEnv * 2)).clip(80, 18000), 3.0);
	var tbD = Saw.ar(freq * 0.5) * tb303OctDn.lag(lagT);
	var tbU = Saw.ar(freq * 2.0) * tb303OctUp.lag(lagT);
	var tb303Mix = (tbFilt + tbD + tbU) * tb303Level.lag(lagT);

	// ── White Noise ──────────────────────────────────────────────────────
	var wn  = WhiteNoise.ar;
	var wnD = WhiteNoise.ar * noiseOctDn.lag(lagT);   // noise doublers add density
	var wnU = WhiteNoise.ar * noiseOctUp.lag(lagT);
	var noiseMix = (wn + wnD * 0.5 + wnU * 0.5) * noiseLevel.lag(lagT);

	// ── Mix all oscillators ──────────────────────────────────────────────
	var rawMix = (sqMix + swMix + supMix + siMix + tb303Mix + noiseMix);

	// Light pre-LPF on the voice to tame highs before the effect chain.
	// The FX chain's LPF/HPF are separate and user-controllable.
	var filtered = LPF.ar(rawMix, cutoff.lag(lagT).clip(80, 20000));

	// ── Amplitude ADSR ───────────────────────────────────────────────────
	var env = EnvGen.kr(
		Env.adsr(attack.lag(lagT), 0.1, sustain.lag(lagT), release.lag(lagT), curve: -4),
		gate: gate,
		levelScale: vel.clip(0.01, 1.0),
		doneAction: Done.freeSelf
	);

	var sig = filtered * env * amp.lag(lagT) * dryWet.lag(lagT);

	// Write to synthSendBus (stereo, panned centre)
	Out.ar(out, Pan2.ar(sig.clip2(1.0), 0));
}).add;


// =============================================================================
// MASTER EFFECT CHAIN — setup function (~initEffectChain)
// =============================================================================
// Called from main.scd after the server boots and ~synthSendBus is allocated.
// Creates an Ndef(\masterFX) that reads from ~synthSendBus, applies the
// effect chain, and plays to ~mainOutBus.
//
// Effect parameters are controlled via Ndef(\masterFX).set(\param, value).
// The apc_pads.scd file calls these when an effect pad is toggled or when
// faders are remapped in parameter-edit mode.
//
// XFade2 smoothly crossfades between the dry signal and each effect output,
// so toggling an effect doesn't produce an audible click.
// XFade2 range: -1 = 100% dry, 1 = 100% wet.

~initEffectChain = {
	Ndef(\masterFX, {
		|
		// Distortion (row 4)
		distActive=0, distDrive=0.3, distTone=0.6, distMix=0.5,
		// Tremolo / envelope LFO (row 5)
		envActive=0, envRate=4.0, envDepth=0.4,
		// Reverb (row 6)
		revActive=0, revRoom=0.5, revDamp=0.4, revMix=0.3,
		// LPF (row 7)
		lpfActive=0, lpfCutoff=0.8, lpfRes=0.1,
		// HPF (row 8)
		hpfActive=0, hpfCutoff=0.05
		|

		var sig = In.ar(~synthSendBus.index, 2);
		var p  = { |v| v.lag(0.05) };             // Lag wrapper
		var xf = { |dry, wet, amt, act|
			// Select.ar pattern: when act=0 → pass dry; when act=1 →
			// crossfade dry→wet by amt (0-1). amt*2-1 maps 0→-1 (dry) to 1→+1 (wet).
			Select.ar(act > 0, [dry, XFade2.ar(dry, wet, amt.lag(0.05) * 2.0 - 1.0)]);
		};

		// ── Distortion ──────────────────────────────────────────────────
		// Soft-clip waveshaper with tone (post-filter) control.
		var distSig = (sig * (1.0 + p.(distDrive) * 20.0)).tanh * 0.4;
		distSig = LPF.ar(distSig, p.(distTone).linexp(0.0, 1.0, 500.0, 15000.0));
		sig = xf.(sig, distSig, distMix, distActive);

		// ── Tremolo ──────────────────────────────────────────────────────
		var lfo = SinOsc.kr(p.(envRate), 0,
			p.(envDepth) * 0.5, 1.0 - (p.(envDepth) * 0.5));
		var envSig = sig * lfo;
		sig = xf.(sig, envSig, 1.0, envActive);

		// ── Reverb ───────────────────────────────────────────────────────
		var revSig = FreeVerb.ar(sig, p.(revMix), p.(revRoom), p.(revDamp));
		sig = xf.(sig, revSig, revMix, revActive);

		// ── LPF ─────────────────────────────────────────────────────────
		var lpfHz = p.(lpfCutoff).linexp(0.0, 1.0, 80.0, 20000.0);
		var lpfSig = RLPF.ar(sig, lpfHz, p.(lpfRes).clip(0.01, 1.0));
		sig = xf.(sig, lpfSig, 1.0, lpfActive);

		// ── HPF ─────────────────────────────────────────────────────────
		var hpfHz = p.(hpfCutoff).linexp(0.0, 1.0, 20.0, 8000.0);
		var hpfSig = HPF.ar(sig, hpfHz);
		sig = xf.(sig, hpfSig, 1.0, hpfActive);

		sig;
	});

	Ndef(\masterFX).play(~mainOutBus, numChannels: 2);
	"  Effect chain Ndef(\\masterFX) started → mainOutBus".postln;
};

// ── Convenience: set a single effect active/inactive ─────────────────────────
// effectKey is one of: \distActive, \envActive, \revActive, \lpfActive, \hpfActive
~setFXActive = { |effectKey, isActive|
	Ndef(\masterFX).set(effectKey, if(isActive, 1, 0));
};

// ── Convenience: set a parameter of an effect (normalized 0-1) ──────────────
~setFXParam = { |paramKey, val|
	Ndef(\masterFX).set(paramKey, val);
};

// ── Effect parameter tables (used by apc_pads.scd for fader remapping) ───────
// Each entry is [paramKey, defaultValue, label].
// Fader index 0 = fader 1 in the docs.
~fxParamTable = IdentityDictionary[
	\dist -> [
		[\distDrive, 0.3, "Drive"],
		[\distTone,  0.6, "Tone"],
		[\distMix,   0.5, "Mix"]
	],
	\env  -> [
		[\envRate,  4.0, "Rate"],
		[\envDepth, 0.4, "Depth"]
	],
	\rev  -> [
		[\revRoom, 0.5, "Room"],
		[\revDamp, 0.4, "Damp"],
		[\revMix,  0.3, "Mix"]
	],
	\lpf  -> [
		[\lpfCutoff, 0.8, "Cutoff"],
		[\lpfRes,    0.1, "Res"]
	],
	\hpf  -> [
		[\hpfCutoff, 0.05, "Cutoff"]
	]
];

// ── Per-row effect key lookup (row 0-indexed) ─────────────────────────────────
~rowFXKey = [nil, nil, nil, \dist, \env, \rev, \lpf, \hpf];
// rows 0,1,2 = oscillators/octave — no FX chain effect
// rows 3-7 map to effect keys

// =============================================================================
// SAMPLE VOICE — \sampleVoice (for Worlde Easypad 12)
// =============================================================================
// Plays a pre-loaded Buffer with velocity scaling and per-pad ADSR.
// Pads use Buffer.read (not disk-streaming) because percussion samples are
// short (< 5 s, < 10 MB each); 12 pads × 10 MB = 120 MB max, well within
// the Pi's 512 MB headroom when accounting for SC and OS overhead.
// If a sample file is larger than 10 MB, use \backtrackVS instead and route
// it to the FOH bus.

SynthDef(\sampleVoice, {
	arg out=0, buf=0,
	vel=0.8,
	attack=0.005, decay=0.1, sustain=0.8, release=0.3,
	amp=0.8, pan=0;

	var sig, env;

	// PlayBuf: mono or stereo depending on buffer's numChannels.
	// Done.freeSelf releases the Synth when the buffer finishes.
	sig = PlayBuf.ar(1, buf, BufRateScale.kr(buf), doneAction: Done.freeSelf);

	// Per-pad ADSR with velocity scaling
	env = EnvGen.kr(
		Env.adsr(attack, decay, sustain, release, curve: -4),
		gate: 1,                         // auto-gate: on at creation, off at end
		levelScale: vel.clip(0.01, 1.0),
		doneAction: Done.freeSelf
	);

	sig = sig * env * amp;
	Out.ar(out, Pan2.ar(sig, pan));
}).add;

// =============================================================================
// BACKTRACK PLAYERS — disk-streaming (VDiskIn / DiskIn)
// =============================================================================
// VDiskIn streams audio from disk without loading the full file into RAM.
// Files MUST be WAV or AIFF (not MP3). The web interface converts MP3→WAV
// at upload time using ffmpeg. Buffer.cue opens a streaming buffer.
//
// \backtrackVS  — VS (main backtrack) → writes to ~mainOutBus (FOH)
// \backtrackIEM — Click or Dica → writes to ~iemOutBus (IEM/monitor)

SynthDef(\backtrackVS, {
	arg out=0,   // FOH bus
	buf=0,
	rate=1.0,
	amp=1.0;

	var sig = VDiskIn.ar(2, buf, rate, loop: 0, sendID: 0);
	Out.ar(out, sig * amp.lag(0.05));
}).add;

SynthDef(\backtrackIEM, {
	arg out=2,   // IEM bus
	buf=0,
	rate=1.0,
	amp=1.0;

	var sig = VDiskIn.ar(2, buf, rate, loop: 0, sendID: 1);
	Out.ar(out, sig * amp.lag(0.05));
}).add;

// =============================================================================
// PERCUSSION / ONE-SHOT VOICES (legacy — kept for compatibility)
// =============================================================================
// These are preserved for testing and fallback; the primary percussion engine
// in the new architecture uses \sampleVoice driven by the Worlde Easypad 12.

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

// =============================================================================
// CLICK — IEM only
// =============================================================================
// A short sine burst routed exclusively to ~iemOutBus (the IEM/monitor output).
// The clock.scd file calls this on each beat via the shared TempoClock.
// The click MUST never reach ~mainOutBus (FOH).

SynthDef(\click, {
	arg out=2,            // default = ~iemOutBus
	freq=1800,            // Hz — 1800 for downbeat, 1000 for other beats
	duration=0.03,
	amp=0.5;

	var env = EnvGen.kr(
		Env.perc(0.001, duration, curve: -4),
		doneAction: Done.freeSelf
	);
	var sig = (SinOsc.ar(freq) * 0.8 + WhiteNoise.ar(0.15)) * env * amp;
	Out.ar(out, Pan2.ar(sig, 0));
}).add;


// =============================================================================
// VERIFICATION HELPERS — Step 1 checkpoint
// =============================================================================
// Run these in the sclang interpreter after booting main.scd to confirm
// correct audio and measure CPU headroom.
//
//   // Test melodic voice (saw + square active)
//   var v = Synth(\lanth0nVoice, [out: ~synthSendBus.index, freq: 220,
//     sawLevel: 1, sqLevel: 0.5, gate: 1, vel: 0.8, amp: 0.5]);
//   // After 2s: v.set(\gate, 0);
//
//   // Test effect chain (after ~initEffectChain has been called)
//   Ndef(\masterFX).set(\revActive, 1);
//   Ndef(\masterFX).set(\revRoom, 0.7);
//
//   // Test sample voice (requires a Buffer)
//   // var b = Buffer.read(s, "/path/to/kick.wav");
//   // Synth(\sampleVoice, [buf: b.bufnum, vel: 0.9]);
//
//   // Test click (should come through IEM bus only)
//   Synth(\click, [out: ~iemOutBus, freq: 1800]);
//
//   // Stress test: 8 simultaneous voices, all oscillators
//   8.do { |i|
//     Synth(\lanth0nVoice, [out: ~synthSendBus.index,
//       freq: (50 + (i * 7)).midicps, sawLevel: 1, sineLevel: 0.5,
//       gate: 1, vel: 0.7, amp: 0.4]);
//   };
//   s.avgCPU.postln;   // should be < 50% on Pi Zero 2W with 8 voices + FX
//   s.peakCPU.postln;
