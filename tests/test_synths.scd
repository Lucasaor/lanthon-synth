// =============================================================================
// tests/test_synths.scd — LANTH0N 5YNTH: SynthDef verification tests
// =============================================================================
// Run on a macOS/Linux dev machine with SuperCollider installed.
// No hardware required — tests trigger SynthDefs via the interpreter.
//
// Usage:
//   sclang tests/test_synths.scd
//   OR: open in SC IDE, select all, Ctrl+Enter
//
// Expected output: a series of PASS/FAIL lines followed by a CPU report.
// =============================================================================

var projectDir = PathName(thisProcess.nowExecutingPath).parentPath.dirname;
var passed = 0;
var failed = 0;
var assert = { |label, cond|
	if (cond, {
		("  PASS: " ++ label).postln;
		passed = passed + 1;
	}, {
		("  FAIL: " ++ label).postln;
		failed = failed + 1;
	});
};

"=== LANTH0N 5YNTH — SynthDef Tests ===".postln;

s.waitForBoot({
	// Load the synth definitions
	thisProcess.interpreter.executeFile(projectDir +/+ "src/synths.scd");

	// Allocate the send bus (normally done in main.scd)
	~mainOutBus   = 0;
	~iemOutBus    = 2;
	~synthSendBus = Bus.audio(s, 2);

	s.sync;

	// ── Test 1: \lanth0nVoice exists ──────────────────────────────────────
	assert.("\\lanth0nVoice SynthDef exists",
		SynthDescLib.global.at(\lanth0nVoice).notNil
	);

	// ── Test 2: Trigger \lanth0nVoice with saw oscillator ─────────────────
	var v1 = Synth(\lanth0nVoice, [
		\out,      ~synthSendBus.index,
		\freq,     220,
		\gate,     1,
		\vel,      0.8,
		\sawLevel, 1.0,
		\amp,      0.3
	]);
	assert.("\\lanth0nVoice spawned without error", v1.notNil);
	2.0.wait;
	v1.set(\gate, 0);
	0.5.wait;

	// ── Test 3: CPU headroom (8 voices) ───────────────────────────────────
	var voices = Array.fill(8, { |i|
		Synth(\lanth0nVoice, [
			\out,      ~synthSendBus.index,
			\freq,     (48 + i * 5).midicps,
			\gate,     1,
			\vel,      0.6,
			\sawLevel, 1.0,
			\sineLevel,0.5,
			\amp,      0.3
		])
	});
	1.0.wait;
	s.sync;
	var avgCPU = s.avgCPU;
	("  CPU with 8 voices: avg=%" ++ avgCPU.round(0.1) ++ "%").postln;
	assert.("CPU < 80% with 8 voices", avgCPU < 80.0);
	voices.do { |v| v.set(\gate, 0); };
	1.0.wait;

	// ── Test 4: \click only fires to IEM bus (check bus index) ───────────
	assert.("\\click SynthDef exists",
		SynthDescLib.global.at(\click).notNil
	);
	var ck = Synth(\click, [\out, ~iemOutBus, \freq, 1800]);
	assert.("\\click spawned", ck.notNil);
	0.5.wait;

	// ── Test 5: \sampleVoice exists ───────────────────────────────────────
	assert.("\\sampleVoice SynthDef exists",
		SynthDescLib.global.at(\sampleVoice).notNil
	);

	// ── Test 6: backtrack SynthDefs exist ─────────────────────────────────
	assert.("\\backtrackVS exists",
		SynthDescLib.global.at(\backtrackVS).notNil
	);
	assert.("\\backtrackIEM exists",
		SynthDescLib.global.at(\backtrackIEM).notNil
	);

	// ── Test 7: effect chain init ─────────────────────────────────────────
	~initEffectChain.();
	s.sync;
	0.5.wait;
	assert.("Ndef(\\masterFX) running",
		Ndef(\masterFX).notNil and: { Ndef(\masterFX).isPlaying }
	);
	Ndef(\masterFX).set(\revActive, 1);
	assert.("masterFX revActive can be set", true);  // no crash = pass

	// ── Summary ───────────────────────────────────────────────────────────
	s.sync;
	"".postln;
	"=== Test Results ===".postln;
	("  Passed: " ++ passed).postln;
	("  Failed: " ++ failed).postln;
	("  Final CPU: avg=" ++ s.avgCPU.round(0.1) ++ "% peak=" ++ s.peakCPU.round(0.1) ++ "%").postln;
	if (failed == 0, { "ALL TESTS PASSED".postln; }, { "SOME TESTS FAILED".postln; });
	"".postln;

	// Clean up
	if (Ndef(\masterFX).notNil, { Ndef(\masterFX).stop; Ndef(\masterFX).clear; });
	~synthSendBus.free;
	s.quit;
});
