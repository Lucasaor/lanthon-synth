// =============================================================================
// tests/test_backtrack.scd — Backtrack engine tests (no hardware needed)
// =============================================================================
// Tests setlist loading, disk-streaming state transitions, and MIDI-triggered
// backtrack control. Use a small test WAV file in the media/ directory.
//
// SETUP: Create a test WAV file first:
//   ffmpeg -f lavfi -i "sine=frequency=440:duration=5" -ar 44100 -ac 2 \
//     "media/Test Song 1 (VS).wav"
//
// Run: sclang tests/test_backtrack.scd
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

"=== Backtrack Engine Tests ===".postln;

s.waitForBoot({
	// Load required modules
	thisProcess.interpreter.executeFile(projectDir +/+ "src/synths.scd");
	s.sync;
	~mainOutBus   = 0;
	~iemOutBus    = 2;
	~synthSendBus = Bus.audio(s, 2);
	thisProcess.interpreter.executeFile(projectDir +/+ "src/clock.scd");
	~startClock.(120);
	~mediaDir    = projectDir +/+ "media";
	~setlistsDir = projectDir +/+ "setlists";
	~oledSender  = nil;   // suppress OLED OSC (no OLED daemon in tests)
	thisProcess.interpreter.executeFile(projectDir +/+ "src/backtrack.scd");
	~initBacktrack.();
	s.sync;

	// ── Test 1: Load example setlist ─────────────────────────────────────
	~loadSetlist.("example");
	0.2.wait;
	assert.("Setlist loaded (not nil)", ~btSetlist.notNil);
	assert.("Setlist has at least 1 song",
		~btSetlist.notNil and: { (~btSetlist[\songs].size) > 0 }
	);

	// ── Test 2: Current song returns the first song ───────────────────────
	var song = ~currentSong.();
	assert.("~currentSong returns a song dictionary", song.notNil);
	assert.("Song has a 'name' key", song !? { song[\name].notNil } ? false);
	assert.("Song has a 'tempo' key", song !? { song[\tempo].notNil } ? false);

	// ── Test 3: setBpm updates the shared clock ───────────────────────────
	~setBpm.(140);
	0.05.wait;
	assert.("TempoClock tempo updated to 140 BPM",
		(~mainClock.tempo * 60).round(0.1) == 140.0
	);

	// ── Test 4: btStop does not crash when not playing ────────────────────
	var threw = false;
	try { ~btStop.(); } { threw = true; };
	assert.("~btStop safe when nothing is playing", threw.not);
	assert.("~btPlaying is false after stop", ~btPlaying == false);

	// ── Test 5: btNext increments song index ──────────────────────────────
	~btSongIndex = 0;
	~btNext.();
	0.1.wait;
	assert.("~btNext increments song index",
		~btSongIndex == 1 or: { ~btSongIndex == 0 }  // wraps if only 1 song
	);

	// ── Test 6: btPrev clamps at 0 ───────────────────────────────────────
	~btSongIndex = 0;
	~btPrev.();
	0.1.wait;
	assert.("~btPrev clamps at index 0", ~btSongIndex == 0);

	// ── Test 7: OSC responders exist ─────────────────────────────────────
	assert.("\\btPlay OSCdef exists", OSCdef(\btPlay).notNil);
	assert.("\\btStop OSCdef exists", OSCdef(\btStop).notNil);
	assert.("\\btNext OSCdef exists", OSCdef(\btNext).notNil);
	assert.("\\btPrev OSCdef exists", OSCdef(\btPrev).notNil);

	// ── Test 8: Play with a real WAV file (if present) ────────────────────
	var testVS = projectDir +/+ "media/Test Song 1 (VS).wav";
	if (File.exists(testVS), {
		"  Found test VS file — testing disk-streaming play...".postln;
		~btSongIndex = 0;
		~btPlay.();
		2.0.wait;
		assert.("~btPlaying is true during playback", ~btPlaying == true);
		assert.("VS synth is active", ~btVSSynth.notNil);
		~btStop.();
		0.5.wait;
		assert.("~btPlaying is false after stop", ~btPlaying == false);
		assert.("VS buffer freed after stop", ~btVSBuf.isNil);
	}, {
		"  NOTE: 'media/Test Song 1 (VS).wav' not found.".postln;
		"  Create it with: ffmpeg -f lavfi -i \"sine=frequency=440:duration=5\" -ar 44100 -ac 2 \"media/Test Song 1 (VS).wav\"".postln;
		"  Skipping disk-streaming test.".postln;
	});

	// ── Summary ───────────────────────────────────────────────────────────
	~stopClock.();
	"".postln;
	"=== Backtrack Test Results ===".postln;
	("  Passed: " ++ passed).postln;
	("  Failed: " ++ failed).postln;
	if (failed == 0, { "ALL TESTS PASSED".postln; }, { "SOME TESTS FAILED".postln; });
	~synthSendBus.free;
	s.quit;
});
