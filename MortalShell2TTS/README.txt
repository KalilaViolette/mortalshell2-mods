MortalShell2TTS v0.9.263
Reads the game's lore and documents aloud (UE4SS Lua mod)
On Nexus this is published as "Text to Speech (TTS) - Lore Narrator". The folder
has to stay MortalShell2TTS, because that is the name UE4SS loads.

WHAT IT DOES
  When you open a note, letter, book or any other "read" prompt in Mortal
  Shell II, this mod reads the page aloud, and reads the next page when you
  turn it. It uses the voices already on your Windows install, or Azure
  neural voices if you have an Azure Speech key. Everything is set from an
  in-game settings window: voice (a searchable browser with previews and
  favorites), speed, pitch, volume, speaking style, the output device,
  what happens when a new page starts while the last one is still being
  read, a read delay for the page animation, page-number announcements, and
  a pronunciation dictionary for names the voices get wrong.

REQUIREMENTS
  - Mortal Shell II (Steam), on Windows 10 or 11.
  - UE4SS, the build published for Mortal Shell II on Nexus. The stock UE4SS
    release from GitHub is not built for this game's engine version.
  - MortalShell2ModUI (the shared in-game settings window). Install it first,
    because this mod will not start without it.
  - Windows PowerShell 5.1 (part of Windows). The speech itself runs in a
    small helper script the mod starts in the background (see HOW IT WORKS).
  - For Azure voices only: an Azure Speech resource (key + region). Windows
    voices need nothing.

INSTALL
  Extract the archive into the game's Win64 folder so that you end up with
    ...\steamapps\common\Sparta\MortalShell2\Binaries\Win64\ue4ss\Mods\MortalShell2TTS\
  containing "Scripts", "TTSHelper.ps1", "AzureStream.ps1",
  "PronunciationCorrections.default.txt" and "enabled.txt". Do the same for
  MortalShell2ModUI. Start the game and open a note.

  To update, replace the folder. TTSConfig.ini (your settings) is written
  by the mod next to the scripts and is never in the archive, so it is kept.
  TTSConfig.example.ini shows what it contains.

  To uninstall, delete the folder. To also remove an Azure key or your own
  pronunciation rules, delete %LOCALAPPDATA%\MortalShell2TTS.

CONTROLS
  Ctrl, then T, T, S ..... open the settings window (keyboard: hold Ctrl and
                           tap T, T, S)
  L3 + R3 ................ open the settings window (controller)
  Both can be re-recorded on the MOD tab. Escape (Circle / B) closes the
  window. In the voice browser the right stick or Page Up / Page Down turn
  pages, Home / End jump, typing searches. Every tab has a reset row that
  puts that tab back to its defaults.

SETTINGS (tabs in the window)
  MOD      narration on/off, read delay, announce page numbers, the two
           open bindings, modifier sides, pause the game while the window is
           open, Controller Settings (the shared calibration and test screen),
           performance logging, debug logging, reset.
  SPEECH   voice browser, speaking style, rate, pitch, volume, speech queue
           (interrupt / queue / ignore), duplicate suppression, pronunciation
           corrections on/off, test voice, reset.
  ENGINE   Windows Speech or Azure, audio output device, engine status,
           Azure region, Azure key (imported from the clipboard), refresh the
           Azure voice list, clear the key, engine help, reset.

HOW IT WORKS (read this if you run antivirus)
  Lua inside UE4SS cannot play audio, so the mod starts
  TTSHelper.ps1 with Windows PowerShell, hidden, when the game starts, and
  talks to it through small text files in the mod folder (tts_command.txt,
  tts_sequence.txt, tts_voices.txt and so on, which you can open because they
  are plain text). The helper uses Windows' own System.Speech for local voices.
  It exits when the game does. It is started with -ExecutionPolicy Bypass
  for its own process only. Your machine's execution policy is not changed.

  Azure: the key you paste is imported from the clipboard inside the game
  and stored encrypted with Windows DPAPI (readable only by your Windows
  account) at %LOCALAPPDATA%\MortalShell2TTS\AzureSpeechKey.dat. It is never
  written to TTSConfig.ini or any log. The first time Azure speaks, the
  helper compiles a small audio player (AzureWaveOutPlayer.v1.dll) into that
  same folder from the C# source inside AzureStream.ps1. Some antivirus
  products flag a freshly compiled DLL, and that is what this one is.
  Azure requests go to <region>.tts.speech.microsoft.com and nowhere else.

FILES THE MOD WRITES
  In the mod folder: TTSConfig.ini (+ .bak), tts_helper.log (2 MB, rotated),
  and the tts_*.txt files above.
  In %LOCALAPPDATA%\MortalShell2TTS: the encrypted Azure key, your own
  PronunciationCorrections.txt, the compiled Azure player.
  It never touches your save.

PRONUNCIATION
  PronunciationCorrections.default.txt ships with rules for names the voices
  mangle. Your own rules go in
  %LOCALAPPDATA%\MortalShell2TTS\PronunciationCorrections.txt, same format
  (the default file explains it), and win over the shipped ones. The SPEECH
  tab has an on/off switch for the whole thing.

KNOWN LIMITATIONS
  - Only the lore / document reader is narrated. Dialogue, item descriptions
    and menus are not.
  - Azure "Dragon HD" voices do not support pitch, so the row shows N/A.
  - If PowerShell is missing or blocked by policy, the ENGINE tab's status
    row says so and nothing is read. tts_helper.log has the reason.

REPORTING A BUG
  Turn on "Debug Logging" on the MOD tab first if you can reproduce the
  problem (the mod is quiet in the log by default, and with it on every menu
  input, redraw and helper exchange is written), then reproduce it. Run
  CollectSupportBundle.cmd in the mod folder afterwards (with the game
  closed). It zips the mod's lines from UE4SS.log and tts_helper.log plus
  version and settings metadata, and deliberately leaves out your
  TTSConfig.ini, the Azure key, narrated text and voice lists. Attach that
  zip and say what page you opened and what you heard.

CREDITS
  Built on UE4SS. Uses the game's own menu widgets and font by reference.
  Nothing from the game is redistributed. Windows Speech is Microsoft's, and
  Azure Speech is a paid Microsoft service you bring your own key to.

LICENSE
  MIT (see the LICENSE file): use it, change it, redistribute it, keep the
  notice.
