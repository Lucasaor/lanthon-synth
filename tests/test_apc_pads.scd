// =============================================================================
// tests/test_apc_pads.scd — APC pad state machine tests (no hardware needed)
// =============================================================================
// Tests the FX pad toggle logic, PC pad save/load, and fader routing
// by simulating pad presses without any real MIDI input.
//
// Run: sclang tests/test_apc_pads.scd
// =============================================================================

var projectDir = PathName(thisProcess.nowExecutingPath).parentPath.dirname;
var passed = 0; var failed = 0;
var assert = { |label, cond|
	if (cond, {
		("  PASS: " ++ label).postln;
		passed = passed + 1;
	}, {
		("  FAIL: " ++ label).postln;
		failed = failed + 1;
	});
};

"=== APC Pad State Machine Tests ===".postln;

s.waitForBoot({
	// Load required modules
	thisProcess.interpreter.executeFile(projectDir +/+ "src/synths.scd");
	s.sync;
	~mainOutBus = 0; ~iemOutBus = 2;
	~synthSendBus = Bus.audio(s, 2);
	~initEffectChain.();
	s.sync;
	thisProcess.interpreter.executeFile(projectDir +/+ "src/apc_leds.scd");
	thisProcess.interpreter.executeFile(projectDir +/+ "src/apc_pads.scd");
	~pcSnapshotsPath = projectDir +/+ "config/pc_snapshots.json";
	~lanth0nVoices  = List.new;
	~apcNotesVoices = List.new;
	// Don't call ~initAPCPads yet — we'll set state manually

	// ── Test 1: Initial state ─────────────────────────────────────────────
	~initFXPadState.();
	assert.("All row-0 pads start as \\idle",
		6.every { |c| ~fxPadState[0][c] == \idle }
	);

	// ── Test 2: FX pad toggle idle → active ───────────────────────────────
	~onFXPadPress.(0, 0);   // press col=0, row=0 (Sq oscillator)
	0.01.wait;
	assert.("Pad (0,0) becomes \\active after press",
		~fxPadState[0][0] == \active
	);

	// ── Test 3: FX pad toggle active → idle ───────────────────────────────
	~onFXPadRelease.(0, 0);
	~onFXPadPress.(0, 0);   // second press
	0.01.wait;
	assert.("Pad (0,0) returns to \\idle on second press",
		~fxPadState[0][0] == \idle
	);

	// ── Test 4: Effect row toggle ─────────────────────────────────────────
	~onFXPadPress.(0, 3);   // col=0, row=3 = Distortion
	0.01.wait;
	assert.("Distortion pad (0,3) becomes \\active",
		~fxPadState[3][0] == \active
	);

	// ── Test 5: applyEffectState doesn't crash ────────────────────────────
	var threwError = false;
	try { ~applyEffectState.(3); } { threwError = true; };
	assert.("~applyEffectState.(3) runs without error", threwError.not);

	// ── Test 6: Fader normal mode updates ~voiceParams ────────────────────
	~faderMode = \normal;
	~onFaderMove.(0, 64);   // fader 0 (amp), mid position
	assert.("Fader 0 updates ~voiceParams[\\amp]",
		~voiceParams[\amp].notNil
	);

	// ── Test 7: PC pad save (requires ~pcSnapshots) ───────────────────────
	~pcSnapshots = Array.fill(16, { nil });
	~pcPadState  = Array.fill(16, { \empty });
	~activePCIndex = nil;
	// Activate an oscillator pad to have something to snapshot
	~fxPadState[0][1] = \active;  // Saw
	~savePCSnapshot.(0);
	assert.("PC pad 0 state is \\active after save",
		~pcPadState[0] == \active
	);
	assert.("PC snapshot 0 is not nil",
		~pcSnapshots[0].notNil
	);

	// ── Test 8: PC pad load ───────────────────────────────────────────────
	~fxPadState[0][1] = \idle;  // Reset Saw
	~loadPCSnapshot.(0);
	0.05.wait;
	assert.("Saw pad (1,0) restored to \\active after snapshot load",
		~fxPadState[0][1] == \active
	);

	// ── Test 9: Notes mode toggle ─────────────────────────────────────────
	~enterNotesMode.();
	assert.("~apcNotesMode is true after ~enterNotesMode", ~apcNotesMode == true);
	~exitNotesMode.();
	assert.("~apcNotesMode is false after ~exitNotesMode", ~apcNotesMode == false);

	// ── Summary ───────────────────────────────────────────────────────────
	"".postln;
	"=== APC Pad Test Results ===".postln;
	("  Passed: " ++ passed).postln;
	("  Failed: " ++ failed).postln;
	if (failed == 0, { "ALL TESTS PASSED".postln; }, { "SOME TESTS FAILED".postln; });
	s.quit;
});
