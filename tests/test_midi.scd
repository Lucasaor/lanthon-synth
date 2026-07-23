// =============================================================================
// tests/test_midi.scd — MIDI offline-resilience tests (no hardware needed)
// =============================================================================
// Verifies that the MIDI routing system boots cleanly with zero controllers
// attached, handles nil srcIDs without crashing, and that the device-watcher
// Routine starts without error.
//
// Run: sclang tests/test_midi.scd
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

"=== MIDI Offline-Resilience Tests ===".postln;

s.waitForBoot({
	thisProcess.interpreter.executeFile(projectDir +/+ "src/synths.scd");
	s.sync;
	~mainOutBus   = 0;
	~iemOutBus    = 2;
	~synthSendBus = Bus.audio(s, 2);
	~initEffectChain.();
	thisProcess.interpreter.executeFile(projectDir +/+ "src/apc_leds.scd");
	thisProcess.interpreter.executeFile(projectDir +/+ "src/apc_pads.scd");
	~pcSnapshotsPath = projectDir +/+ "config/pc_snapshots.json";
	~initAPCPads.();
	thisProcess.interpreter.executeFile(projectDir +/+ "src/backtrack.scd");
	~initBacktrack.();
	thisProcess.interpreter.executeFile(projectDir +/+ "src/clock.scd");
	~startClock.(120);
	s.sync;
	thisProcess.interpreter.executeFile(projectDir +/+ "src/midi_routing.scd");

	// ── Test 1: ~initMIDI runs without crash with no controllers ──────────
	var crashed = false;
	try { ~initMIDI.(); } { |e| crashed = true; ("  Error: " ++ e).postln; };
	assert.("~initMIDI runs cleanly with no controllers", crashed.not);

	// ── Test 2: srcIDs are nil (or set from actual connected devices) ──────
	// All three can be nil if no controllers are plugged in — that's expected.
	("  APC srcID: " ++ ~srcID_APC).postln;
	("  Easy srcID: " ++ ~srcID_Easy).postln;
	("  SMK srcID: " ++ ~srcID_SMK).postln;
	assert.("~srcID_APC is nil or Integer",
		~srcID_APC.isNil or: { ~srcID_APC.isKindOf(Integer) }
	);

	// ── Test 3: Simulate note-on with nil srcID (no crash) ────────────────
	var threw = false;
	try {
		// Manually call the SMK25 note-on handler with a fake srcID
		// (not matching ~srcID_SMK=nil, so it should silently return)
		var fakeSrc = -9999;
		MIDIdef(\smk_noteon).func.value(64, 60, 0, fakeSrc);
	} { threw = true; };
	assert.("SMK note-on with wrong srcID does not crash", threw.not);

	// ── Test 4: ~panicStop does not crash when nothing is playing ─────────
	threw = false;
	try { ~panicStop.(); } { threw = true; };
	assert.("~panicStop safe when nothing is playing", threw.not);

	// ── Test 5: Device watcher starts ────────────────────────────────────
	assert.("Device watcher Routine is running",
		~deviceWatcherRoutine.notNil
	);

	// ── Summary ───────────────────────────────────────────────────────────
	~stopClock.();
	if (~deviceWatcherRoutine.notNil, { ~deviceWatcherRoutine.stop; });
	"".postln;
	"=== MIDI Test Results ===".postln;
	("  Passed: " ++ passed).postln;
	("  Failed: " ++ failed).postln;
	if (failed == 0, { "ALL TESTS PASSED".postln; }, { "SOME TESTS FAILED".postln; });
	~synthSendBus.free;
	s.quit;
});
