// =============================================================================
// backtrack.scd — LANTH0N 5YNTH: Backtrack / VS / Click / Cue player
// =============================================================================
//
// Streams audio files from disk (never loaded into RAM) using VDiskIn UGens.
// File format MUST be WAV or AIFF — NOT MP3.  The web interface converts
// uploaded MP3s to WAV using ffmpeg before saving to the media/ directory.
//
// File naming convention (relative to ~mediaDir):
//   "<song name> (VS).wav"    — main backtrack  → FOH bus
//   "<song name> (click).wav" — click track     → IEM bus
//   "<song name> (Dica).wav"  — cue track       → IEM bus
//
// Setlist format (JSON, in the setlists/ directory):
//   {
//     "name": "Night 1",
//     "songs": [
//       { "name": "Song Name", "artist": "Artist", "tempo": 128 },
//       ...
//     ]
//   }
//
// Song file paths are resolved automatically from the song name and media dir.
// If a file is missing, a warning is logged and playback of other channels
// continues uninterrupted.
//
// OSC interface (sclang listens on ~oscPort, default 57121):
//   /backtrack/play
//   /backtrack/stop
//   /backtrack/next
//   /backtrack/prev
//   /backtrack/load  <setlistName>   (string, no ".json" extension)
//   /backtrack/tempo <bpm>           (float, overrides song tempo)
//
// Playback state is broadcast to the OLED daemon via OSC on ~oledOscPort.
// =============================================================================

// =============================================================================
// CONFIGURATION (set in main.scd or here)
// =============================================================================

~mediaDir     = thisProcess.nowExecutingPath.dirname.dirname +/+ "media";
~setlistsDir  = thisProcess.nowExecutingPath.dirname.dirname +/+ "setlists";
~oledOscHost  = "127.0.0.1";
~oledOscPort  = 9000;          // OLED daemon listens on this port

// Audio routing (bus indices, set by synths.scd)
// ~mainOutBus (FOH) and ~iemOutBus (IEM) must be set before calling ~initBacktrack

// =============================================================================
// PLAYBACK STATE
// =============================================================================

~btSetlist    = nil;           // current loaded setlist Dictionary
~btSongIndex  = 0;             // current song index within the setlist
~btPlaying    = false;         // true when playback is active

// Currently running backtrack Synth nodes
~btVSSynth    = nil;
~btClickSynth = nil;
~btCueSynth   = nil;

// Currently open (cue'd) streaming buffers
~btVSBuf      = nil;
~btClickBuf   = nil;
~btCueBuf     = nil;

// Volume controls (updated by faders 7-9)
~btVSVol      = 1.0;
~btClickVol   = 1.0;
~btCueVol     = 1.0;

// OSC sender to the OLED daemon
~oledSender   = nil;

// =============================================================================
// SETLIST LOADING
// =============================================================================

~loadSetlist = { |name|
	var path = ~setlistsDir +/+ (name ++ ".json");
	if (File.exists(path), {
		// Use JSONlib for robust parsing (installed by setup.sh).
		// Falls back to the regex stub if JSONlib is not available.
		var json;
		var jsonClass = \Json.asClass;   // nil when JSONlib is not installed
		if (jsonClass.notNil, {
			try { json = jsonClass.parse(path); } { |err| json = nil; };
		});

		if (json.isNil, {
			var content = File.use(path, "r", { |f| f.readAllString });
			"[BT] JSONlib not available — using fallback parser.".postln;
			json = ~parseSetlistJSON.(content);
		});

		~btSetlist = json;
		~btSongIndex = 0;
		if (~btSetlist.notNil, {
			"[BT] Setlist '%' loaded — % songs".format(name,
				~btSetlist[\songs].size).postln;
			~writeState.();
			~oledUpdate.();
		}, {
			"[BT] ERROR: could not parse setlist file: %".format(path).postln;
		});
	}, {
		"[BT] WARNING: setlist file not found: %".format(path).postln;
	});
};

// Minimal JSON parser for setlist files.
// Returns: (name: String, songs: Array of (name, artist, tempo, vs, click, dica))
// This is intentionally simple. Use JSONlib for production robustness.
~parseSetlistJSON = { |jsonString|
	// Extract top-level "name" field
	var nameMatch = jsonString.findRegexp("\"name\"\\s*:\\s*\"([^\"]+)\"");
	var setlistName = if (nameMatch.size > 1, { nameMatch[1][1] }, { "unknown" });

	// Extract songs array entries
	var songs = List.new;
	var songMatches = jsonString.findRegexp("\\{[^{}]*\"artist\"[^{}]*\\}");
	songMatches.do { |m|
		var entry = m[1];
		var songName   = ~extractJSON.(entry, "name");
		var artist     = ~extractJSON.(entry, "artist");
		var tempoStr   = ~extractJSON.(entry, "tempo");
		var tempo      = tempoStr !? { tempoStr.asFloat } ? 120.0;
		var vsFile     = ~extractJSON.(entry, "vs");
		var clickFile  = ~extractJSON.(entry, "click");
		var dicaFile   = ~extractJSON.(entry, "dica");

		songs.add(IdentityDictionary[
			\name   -> songName,
			\artist -> artist,
			\tempo  -> tempo,
			\vs     -> vsFile,
			\click  -> clickFile,
			\dica   -> dicaFile
		]);
	};

	IdentityDictionary[
		\name  -> setlistName,
		\songs -> songs.asArray
	]
};

// Extract a single string field value from a JSON fragment.
~extractJSON = { |jsonFragment, fieldName|
	var pattern = "\"" ++ fieldName ++ "\"\\s*:\\s*\"?([^,\"\\}]+)\"?";
	var m = jsonFragment.findRegexp(pattern);
	if (m.size > 1, { m[1][1].stripWhiteSpace }, { nil })
};

// =============================================================================
// CURRENT SONG HELPER
// =============================================================================

~currentSong = {
	if (~btSetlist.notNil and: { ~btSetlist[\songs].size > ~btSongIndex }, {
		~btSetlist[\songs][~btSongIndex]
	}, { nil })
};

// Build file path for a given track type (\vs, \click, \dica).
// If the song has an explicit file name (set via web UI), use that directly.
// Otherwise fall back to the naming convention: "<Song Name> (VS).wav" etc.
// Tries multiple case variants since ffmpeg may preserve original capitalization.
~songFilePath = { |song, trackType|
	var explicit = song[trackType];   // e.g. song[\vs], song[\click], song[\dica]
	if (explicit.notNil and: { explicit.asString != "" }, {
		// Explicit file path from web UI — just join with media dir
		~mediaDir +/+ explicit.asString
	}, {
		// Fallback: auto-detect by naming convention
		// Try multiple case variants for the suffix (ffmpeg may preserve caps)
		var baseName = song[\name] ? "unknown";
		var suffixes = switch(trackType,
			\vs,    ["(VS)", "(vs)"],
			\click, ["(click)", "(Click)", "(click)"],
			\dica,  ["(Dica)", "(dica)"],
			[""]
		);
		// Also try .mp3 / .aiff extensions
		var exts = ["wav", "WAV", "mp3", "aiff", "AIFF"];
		var result = block { |break|
			suffixes.do { |sfx|
				exts.do { |ext|
					var path = ~mediaDir +/+ "%% %.%".format(baseName, sfx, ext);
					if (File.exists(path), { break.(path); });
				};
			};
			// Return the first (default) path even if it doesn't exist
			// — ~btPlay will log a warning if missing
			~mediaDir +/+ "% %.wav".format(baseName, suffixes[0])
		};
		result
	});
};

// =============================================================================
// PLAY / STOP
// =============================================================================
// NOTE: ~btPlay is called from OSCdef and MIDIdef handlers which run on
// AppClock (no Routine context). s.sync REQUIRES being inside a Routine.
// We wrap the cue+sync+play sequence in a Routine to provide that context.
// See mitigation plan issue #1.

~btPlay = {
	var song = ~currentSong.();
	if (song.notNil, {
		Routine {
			// Open streaming buffers for each track that exists
			var vsPath    = ~songFilePath.(song, \vs);
			var clickPath = ~songFilePath.(song, \click);
			var cuePath   = ~songFilePath.(song, \dica);
			var hasClick  = File.exists(clickPath);
			~btStop.();

			// Buffer.cueSoundFile queues the file read on the server —
			// it does NOT block. We call s.sync to wait for cue completion.
			// This is safe because we are inside a Routine.
			if (File.exists(vsPath), {
				~btVSBuf = Buffer.cueSoundFile(s, vsPath, 0, 2, bufferSize: 32768);
			}, {
				"[BT] WARNING: file not found — %".format(vsPath).postln;
			});
			if (hasClick, {
				~btClickBuf = Buffer.cueSoundFile(s, clickPath, 0, 2, bufferSize: 32768);
			}, {
				"[BT] WARNING: file not found — %".format(clickPath).postln;
			});
			if (File.exists(cuePath), {
				~btCueBuf = Buffer.cueSoundFile(s, cuePath, 0, 2, bufferSize: 32768);
			}, {
				"[BT] WARNING: file not found — %".format(cuePath).postln;
			});

			s.sync;

			// If the song has its own click track, disable SC metronome click
			// to avoid double-click (unsynchronized).
			// If no click track, start the SC metronome for timing reference.
			("[BT] DEBUG hasClick=%, startClick=%, stopClick=%".format(
				hasClick, ~startClick.notNil, ~stopClick.notNil)).postln;
			if (hasClick, {
				if (~stopClick.notNil, { ~stopClick.(); });
			}, {
				if (~startClick.notNil, { ~startClick.(); });
			});

			// Spawn a Synth for each available buffer
			if (~btVSBuf.notNil, {
				~btVSSynth = Synth(\backtrackVS, [
					\out, ~mainOutBus,
					\buf, ~btVSBuf.bufnum,
					\amp, ~btVSVol
				]);
			});
			if (~btClickBuf.notNil, {
				~btClickSynth = Synth(\backtrackIEM, [
					\out, ~iemOutBus,
					\buf, ~btClickBuf.bufnum,
					\amp, ~btClickVol
				]);
			});
			if (~btCueBuf.notNil, {
				~btCueSynth = Synth(\backtrackIEM, [
					\out, ~iemOutBus,
					\buf, ~btCueBuf.bufnum,
					\amp, ~btCueVol
				]);
			});

			// Update shared clock to song's tempo
			if (song[\tempo].notNil, {
				~setBpm.(song[\tempo].asFloat);
			});

			~btPlaying = true;
			~writeState.();
			~oledUpdate.();
			"[BT] PLAYING: % — % @ % BPM".format(
				song[\name], song[\artist], song[\tempo]).postln;
		}.play(AppClock);
	}, {
		"[BT] No song selected (load a setlist first)".postln;
	});
};

~btStop = {
	// Free synths
	if (~btVSSynth.notNil, { ~btVSSynth.free; ~btVSSynth = nil; });
	if (~btClickSynth.notNil, { ~btClickSynth.free; ~btClickSynth = nil; });
	if (~btCueSynth.notNil, { ~btCueSynth.free; ~btCueSynth = nil; });

	// Close streaming buffers to release memory
	if (~btVSBuf.notNil, { ~btVSBuf.close; ~btVSBuf.free; ~btVSBuf = nil; });
	if (~btClickBuf.notNil, { ~btClickBuf.close; ~btClickBuf.free; ~btClickBuf = nil; });
	if (~btCueBuf.notNil, { ~btCueBuf.close; ~btCueBuf.free; ~btCueBuf = nil; });

	// Stop SC metronome click when backtrack stops
	if (~stopClick.notNil, { ~stopClick.(); });

	~btPlaying = false;
	~writeState.();
	~oledUpdate.();
	"[BT] STOPPED".postln;
};

// =============================================================================
// NAVIGATION
// =============================================================================

~btNext = {
	var wasPlaying = ~btPlaying;
	~btStop.();
	~btSongIndex = (~btSongIndex + 1) % max(1, ~btSetlist !? { ~btSetlist[\songs].size } ? 1);
	~writeState.();
	~oledUpdate.();
	if (wasPlaying, { ~btPlay.(); });
	"[BT] NEXT: index=%".format(~btSongIndex).postln;
};

~btPrev = {
	var wasPlaying = ~btPlaying;
	~btStop.();
	~btSongIndex = (~btSongIndex - 1).max(0);
	~writeState.();
	~oledUpdate.();
	if (wasPlaying, { ~btPlay.(); });
	"[BT] PREV: index=%".format(~btSongIndex).postln;
};

// =============================================================================
// VOLUME CONTROLS (called from fader handlers in midi_routing.scd)
// =============================================================================

~setVSVolume = { |normVal|
	~btVSVol = normVal;
	if (~btVSSynth.notNil, { ~btVSSynth.set(\amp, normVal); });
};
~setClickVolume = { |normVal|
	~btClickVol = normVal;
	if (~btClickSynth.notNil, { ~btClickSynth.set(\amp, normVal); });
};
~setCueVolume = { |normVal|
	~btCueVol = normVal;
	if (~btCueSynth.notNil, { ~btCueSynth.set(\amp, normVal); });
};

// =============================================================================
// STATE FILE WRITER (for web UI state tracking)
// =============================================================================
// Writes current playback state to config/state.json so the web dashboard
// can show the current song/artist/playing status without polling SC via OSC.
// JSON is formatted manually since JSONlib may not be installed on the Pi.

~jsonEscape = { |s|
	var str = s.asString;
	str = str.replace("\\", "\\\\");   // escape backslashes first
	str = str.replace("\"", "\\\"");
	str = str.replace("\n", "\\n");
	str = str.replace("\t", "\\t");
	str;
};

~writeState = {
	var song    = ~currentSong.();
	var setName = ~btSetlist !? { ~btSetlist[\name] } ? "";
	var name   = song !? { song[\name] } ? "";
	var artist = song !? { song[\artist] } ? "";
	var bpm    = song !? { song[\tempo].asInteger } ? 0;
	var playing = if (~btPlaying, "true", "false");
	var json;
	var f;

	json = "{\"activeSetlist\":\"%\",\"songName\":\"%\",\"artist\":\"%\",\"playing\":%, \"bpm\":%}".format(
		~jsonEscape.(setName),
		~jsonEscape.(name),
		~jsonEscape.(artist),
		playing,
		bpm
	);

	// Write to config/state.json in the project root
	f = File.open((~projectDir +/+ "config/state.json").standardizePath, "w");
	if (f.notNil, {
		f.write(json);
		f.close;
	});
};

// =============================================================================
// OLED UPDATE
// =============================================================================
// Sends an OSC message to the OLED daemon with the current playback state.
// Message format: /oled/update <setlistName> <artist> <songName> <state> <bpm>

~oledUpdate = {
	var song = ~currentSong.();
	var setlistName = ~btSetlist !? { ~btSetlist[\name] } ? "—";
	var artist  = song !? { song[\artist] } ? "—";
	var name    = song !? { song[\name]   } ? "—";
	var state   = if (~btPlaying, "PLAYING", "STOP");
	var bpm     = song !? { song[\tempo].asInteger.asString } ? "—";

	if (~oledSender.notNil, {
		~oledSender.sendMsg("/oled/update", setlistName, artist, name, state, bpm);
	});
};

// =============================================================================
// OSC RESPONDERS (so the web interface and MIDI maps can trigger playback)
// =============================================================================

~initBacktrackOSC = {
	OSCdef(\btPlay,  { ~btPlay.();             }, "/backtrack/play");
	OSCdef(\btStop,  { ~btStop.();             }, "/backtrack/stop");
	OSCdef(\btNext,  { ~btNext.();             }, "/backtrack/next");
	OSCdef(\btPrev,  { ~btPrev.();             }, "/backtrack/prev");
	OSCdef(\btLoad,  { |msg|
		var name = msg[1].asString;
		~loadSetlist.(name);
	}, "/backtrack/load");
	OSCdef(\btTempo, { |msg|
		var bpm = msg[1].asFloat;
		~setBpm.(bpm);
	}, "/backtrack/tempo");
	// Health / ping — used by the web UI health indicator
	OSCdef(\ping, {
	}, "/ping");
	// Notes Mode manual toggle — used when auto-detection fails
	OSCdef(\notesModeToggle, {
		if (~apcNotesMode.notNil, {
			if (~apcNotesMode, {
				if (~exitNotesMode.notNil, { ~exitNotesMode.(); });
			}, {
				if (~enterNotesMode.notNil, { ~enterNotesMode.(); });
			});
		});
	}, "/notes_mode_toggle");
	"[BT] OSC responders registered".postln;
};

// =============================================================================
// INIT
// =============================================================================

~initBacktrack = {
	// Ensure media and setlists directories exist
	var ensureDir = { |dir|
		if (File.exists(dir).not, {
			File.mkdir(dir);
			"[BT] Created directory: %".format(dir).postln;
		})
	};
	ensureDir.(~mediaDir);
	ensureDir.(~setlistsDir);

	// Connect OSC sender for OLED
	~oledSender = NetAddr(~oledOscHost, ~oledOscPort);

	// Register OSC responders
	~initBacktrackOSC.();

	~oledUpdate.();
	"Backtrack engine initialized.".postln;
	"  Media dir : %".format(~mediaDir).postln;
	"  Setlists  : %".format(~setlistsDir).postln;
	"  OLED OSC  : %:%".format(~oledOscHost, ~oledOscPort).postln;
};
