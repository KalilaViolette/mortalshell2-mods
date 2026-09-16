MortalShell2ModUI v0.71.8
Shared in-game settings window for Mortal Shell II mods (UE4SS Lua mod)
On Nexus this is published as "ModUI - Shared Settings Window". The folder has to
stay MortalShell2ModUI, because that is the name UE4SS loads.

WHAT IT IS
  A framework, not a gameplay mod. It gives the mods built on it one
  in-game settings window drawn with the game's own menu style, so every mod
  is configured the same way without leaving the game: tabs, rows, values,
  keyboard, controller and mouse, in the game's font. It also owns the parts
  that only work when exactly one mod does them:

  - Keybind capture (record a key chord, sequence or controller combination
    for a mod's hotkey) and the shared hotkey listener.
  - Controller settings: stick deadzone / activation / release thresholds,
    a guided calibration (center both sticks, then the eight cardinal
    directions) and a live controller test. The saved profile is shared by
    every mod on this framework.
  - Menu awareness: mod windows and overlays get out of the way while any of
    the game's own menus is open (pause menu, level-up, beacon menu), and
    game input is blocked while a mod window is open.
  - The performance logging switch used by the mods.

  On its own it draws nothing. Install it because a mod you want requires
  it. Current mods on it: MortalShell2Minimap, MortalShell2TTS.

REQUIREMENTS
  - Mortal Shell II (Steam).
  - UE4SS, the build published for Mortal Shell II on Nexus. The stock UE4SS
    release from GitHub is not built for this game's engine version.

INSTALL
  Extract the archive into the game's Win64 folder so that you end up with
    ...\steamapps\common\Sparta\MortalShell2\Binaries\Win64\ue4ss\Mods\MortalShell2ModUI\
  containing "Scripts" and "enabled.txt". Then install the mods that use it.

  To update, replace the folder. Mods check the framework version they need
  and say so in UE4SS.log if this one is too old.

  To uninstall, delete the folder. The mods that depend on it will stop
  loading until it is back.

HOW YOU REACH IT
  There is no hotkey of its own. Each mod opens the window with its own
  hotkey (see that mod's README). The tabs you see belong to the mod that
  opened it. Controller Settings, calibration and the controller test are
  opened from a "Controller settings" row inside each mod's settings (the
  Minimap's INPUT tab, TTS's MOD tab), and the profile they edit is one and
  the same.

  In any mod's window: Up/Down pick a row, Left/Right change it, A/D or
  L1/R1 change tabs, Enter/Cross activate, Escape/Circle close. The tab
  strip scrolls when a mod has more tabs than fit ("<" and ">" at its ends).
  Holding R (keyboard) or L3 (controller) on a row for 5 seconds puts that
  one row back to its default without touching the rest of the tab.

FILES IT WRITES
  %LOCALAPPDATA%\MortalShell2ModUI_ControllerCalibration.ini, the shared
  controller profile, written when you save calibration or change a
  controller threshold. If that folder cannot be written it falls back to
  the mod folder. Nothing else. It never touches your save.

REPORTING A BUG
  Attach ...\MortalShell2\Binaries\Win64\ue4ss\UE4SS.log (lines tagged
  [MortalShell2ModUI]) and say which mod's window you had open and what you
  pressed. If a controller does something odd, open Controller Settings and
  run the controller test. What it shows is exactly what the framework reads.

CREDITS
  Built on UE4SS. Uses the game's own menu widgets, textures and font by
  reference. Nothing from the game is redistributed.

LICENSE
  MIT (see the LICENSE file): use it, change it, redistribute it, keep the
  notice.
