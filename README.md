# Mortal Shell II mods - source

Source for three UE4SS Lua mods for Mortal Shell II, published on Nexus Mods:

| Mod | Nexus | Version |
| --- | --- | --- |
| Cartographer - Minimap and Dungeon Maps | [mods/497](https://www.nexusmods.com/mortalshell2/mods/497) | 0.18.46 |
| ModUI - Shared Settings Window | [mods/495](https://www.nexusmods.com/mortalshell2/mods/495) | 0.71.8 |
| Text to Speech (TTS) - Lore Narrator | [mods/498](https://www.nexusmods.com/mortalshell2/mods/498) | 0.9.263 |

MIT licensed. Each mod folder carries its own `LICENSE` and `README.txt`.

## There is no build step

These are interpreted scripts. Nothing is compiled to produce the uploaded files, and no
binary is distributed. The archive on Nexus and the folder in this repository contain the
same plain-text files.

- 123 `.lua` (UE4SS Lua 5.4, loaded by UE4SS at game start)
- 9 `.txt`, 3 `.sha256`, 1 `.ini` (readme, manifest, example config)
- 3 `.ps1` and 1 `.cmd` (Windows PowerShell, TTS only - see below)
- 3 `LICENSE`

To reproduce an uploaded archive, zip the mod's folder so that it sits under
`ue4ss/Mods/<ModName>/`. Each mod ships a `*_ReleaseManifest.sha256` listing every file it
contains, so any copy can be verified file by file.

The archives currently published:

```
da20edea82e2a93974155dc575f49494bb3084ad4ec8022d0ca13289e7d7eb24  Cartographer_Minimap_and_Dungeon_Maps_v0.18.46.zip
196682f303d12b60e3e195b6146b92d4e7627e49a2709ba5a914e34799865486  ModUI_Shared_Settings_Window_v0.71.8.zip
197b3d73a786e8b745ad1ff773b645ae83bb5514e4d4c5935e15ef0a465c45b8  TTS_Lore_Narrator_v0.9.263.zip
```

## Installation

Install [UE4SS for Mortal Shell II](https://www.nexusmods.com/mortalshell2/mods/45) and run
the game once. Then place a mod folder so it ends up at:

```
steamapps/common/Sparta/MortalShell2/Binaries/Win64/ue4ss/Mods/<ModName>/
```

UE4SS loads a mod when `enabled.txt` is present in its folder. Cartographer requires ModUI.

## The one thing worth reviewing closely

**`MortalShell2TTS/AzureStream.ps1` compiles C# at runtime on the user's machine.** This is
stated here rather than left to be found.

What it does and why: the Azure Speech voice path streams audio, and playing a stream
through WinMM needs a small amount of C# that PowerShell cannot express directly. The C#
source is written out in readable form in the script and compiled on first use:

```powershell
Add-Type -TypeDefinition $source -Language CSharp -OutputAssembly $tempAssembly
```

- The C# is plain text inside `AzureStream.ps1`. Nothing is downloaded and nothing is
  obfuscated.
- The output is `AzureWaveOutPlayer.v1.dll`, written to the mod's own cache folder on the
  user's machine. It is a local build artifact and is not distributed.
- The compile is cached against a hash of the source and only repeats when that changes.
- It only runs if the user has configured the optional Azure engine. The default Windows
  Speech engine never reaches this code.

The other PowerShell files do not compile anything. `CollectSupportBundle.ps1` gathers logs
into a zip for bug reports, and `RunCompatibilityCheck.ps1` and
`RunReleaseCandidatePreflight.ps1` are development checks.

## Network use

- **Cartographer** and **ModUI** make no network calls of any kind.
- **TTS** contacts Microsoft Azure Speech endpoints, and only when the user has entered
  their own Azure key and selected that engine. Keys are never written to
  `TTSConfig.ini`; the example config says so, and the region is the only Azure value
  stored. The default engine is the Windows Speech API, which is local.

## Saves and game files

None of the three mods write to save files or modify any game file. Nothing from the game
is redistributed here - the mods reference the game's own textures and fonts by path at
runtime.
