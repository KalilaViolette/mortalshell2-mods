MortalShell2Minimap v0.18.46
A minimap for Mortal Shell II (UE4SS Lua mod)
On Nexus this is published as "Cartographer - Minimap and Dungeon Maps". The
folder has to stay MortalShell2Minimap, because that is the name UE4SS loads.

WHAT IT DOES
  Draws a minimap in the corner of the screen using the game's own world-map
  tiles and icons, and adds things the game's map does not show:

  - The world map's own points of interest (hub, dungeons, landing areas,
    beacons, map stations, boss gates, evil statues, shells, weapons, sidearms,
    traversal points, death spoils) and your own map pins, each with a
    toggle, a size, and an off-map edge indicator with its own range.
  - Local interactables near you, found from the game's own events as you
    play (no scanning): chests, pickups, plants and cages you hit for loot,
    lore notes, map fragments, shell ghosts, NPCs, Thestus, merchants,
    blacksmith / Tarforge, traversal points, rest / sit spots, locked doors,
    gloom siphons, bear traps, explosive barrels, enemies (red dots that leave
    when the enemy dies), bosses, and hidden or breakable walls (a white cross
    that disappears once the wall is open). Every category has its own
    toggle, size, a choice of icons and, for white icons, a color. Markers
    leave when the thing is used: an opened chest, a collected pickup, a
    sprung trap, an exploded barrel, a harvested plant, a torch or cage you
    have already shot (and one the game restored as shot never shows).
  - A frame around the map (GENERAL tab): a thin ring or crisp bars, an
    engine-drawn vector outline, or the world map's compass ring / the game's
    gold rule, in a choice of colors, or off.
  - A combat look (COMBAT tab): while you are fighting the map can dim, shrink
    in place, or disappear, and come back after the fight. "Fighting" is what
    the game itself calls combat, the moment its music switches to the fight
    (bosses included). Enemies that have merely noticed you do not count.
  - Inside dungeons, where the game has no map, a live top-down view of the
    rooms around you, drawn as the map background. It has its own lighting
    so it looks the same in a dark dungeon and a bright one, and a CAPTURE
    tab if you want to tune how it is rendered.
  - Optional map labels in the game's font (the region name under the map,
    cardinal letters on the edge), height markers for things above or below
    you (an arrow, sized to taste, and a fade so an icon on another level
    is told apart at a glance and gets fainter the further away it is,
    never below a minimum you set), backing plates behind icons, and a
    footstep trail.

REQUIREMENTS
  - Mortal Shell II (Steam).
  - UE4SS, the build published for Mortal Shell II on Nexus. The stock UE4SS
    release from GitHub is not built for this game's engine version.
  - MortalShell2ModUI (the shared in-game settings window). Install it first,
    because this mod will not start without it.

INSTALL
  1. Install UE4SS for Mortal Shell II and run the game once to be sure it
     loads (a UE4SS.log appears in ...\MortalShell2\Binaries\Win64\ue4ss\).
  2. Extract the archive into the game's Win64 folder so that you end up with
       ...\steamapps\common\Sparta\MortalShell2\Binaries\Win64\ue4ss\Mods\MortalShell2Minimap\
     containing "Scripts" and "enabled.txt". Do the same for MortalShell2ModUI.
  3. Start the game. The minimap appears once you are in the world.

  To update, replace the mod folder. Your settings live in MinimapConfig.ini
  next to it and are kept.

  To uninstall, delete the folder (and MinimapConfig.ini if you want a
  clean slate).

CONTROLS
  Ctrl + .  .............. open the settings window (keyboard)
  L3 + Cross/A ........... open the settings window (controller)
  Both can be changed on the INPUT tab. The settings window is navigated with
  the same keys and controller buttons as the game's own menus, or the mouse.
  Escape (Circle / B on a controller) closes it. Left/Right cycle a value
  (past the last choice comes the first).

  Ctrl+Delete ............ writes a diagnostics summary to UE4SS.log (for bug
                           reports, harmless otherwise)
  Ctrl+Shift+Delete ...... writes a heavy diagnostics snapshot (a short hitch,
                           about a fifth of a second)

SETTINGS (tabs in the window)
  Rows inside a tab are grouped under section titles (-- MINIMAP --,
  -- POSITION -- and so on). The titles are not rows you can select.
  GENERAL  Minimap: on/off, size, map range, opacity, player arrow.
           Position: X and Y.
           Shape & frame: square or circle, orientation (north-up or rotate
           with the camera), map frame (Off / Ring or Bars / Vector / Compass
           or Gold dividers) and its color.
  MAP      Dungeon map: on / transparent / the game's fog, its brightness in
           dungeons and in the open world, dungeon map everywhere, its update
           rate (2-60 Hz, default 30), the ceiling cut (Auto: measured from
           the headroom above you, low in a corridor and high in a hall.
           Fixed: the CAPTURE tab's height).
           Labels: region name / cardinals, their size, font (seven of the
           game's own faces, or whatever the last area announcement used),
           color, outline, shadow and North-only / N E S W.
           Markers: footstep trail and its size, backing plates.
           Height markers: on/off, the height that counts as another level
           (1-20 m, default 3), arrow size, and the height fade: its
           opacity at the threshold (75%), its minimum (35%) and how many
           meters past the threshold it takes to get there (15).
  ICONS    Map icons: the world map's icons on/off (and Edge visibility with
           Advanced settings on).
           Selected category: per-category on/off, discovered-only, size,
           off-map indicators, their range and far size.
           User pins: your own map pins' size, off-map indicators and range.
  LOCAL    Local markers: on/off, base icon size (and the icon budget with
           Advanced settings on).
           Selected category: per-category on/off, size, icon (each category
           cycles its own shortlist, and the first entry is the one it
           ships on) and, when the icon is white artwork, its color.
  COMBAT   Hide in combat (off by default), combat opacity and combat size
           (both 90% by default), the transition between the two
           looks (instant to 1 s) and the restore delay after the fight
           (0-8 s). Selecting the opacity, size or hide row previews it on
           the map while the window is open.
  INPUT    Hotkeys: the two hotkeys and whether left/right modifiers are
           treated alike. Controller: "Controller settings" (deadzones,
           calibration and a live controller test, shared with my other mods
           through ModUI).
  MOD      Window: pause while the window is open. Advanced: the Advanced
           settings switch. With it on, the same tab also gains Debug logging,
           Log performance, and the budget, update-rate and LOD rows.
           Leave Debug logging off unless you are chasing a bug. Measured
           2026-09-16: it writes about 460 lines a second and costs roughly ten
           times what the whole mod does, so a session with it on is not a
           measurement of the mod. Log performance is cheap (about 5 lines a
           second) and is the one to use for a [PERF] report.
  Advanced settings also adds the "Edge visibility" row on ICONS, the icon
  budget on LOCAL, and the CAPTURE tab:
  CAPTURE  how the dungeon view is rendered: Lighting (sun, sky, fog),
           Capture (source, format, tint, resolution, detail), Exposure
           (the capture's own post-process) and Camera (height, ceiling cut).
           The defaults are what I play with, and you should not need this tab.
  Every tab has a "Reset this tab" row at the bottom.

FILES THE MOD WRITES
  MinimapConfig.ini (in the mod folder), written by the mod whenever you
  change a setting. A few switches are ini-only (they have no row in the
  window): LocalDiscoveryTrace, EnemyRefreshHooks, MapLabelInk, MapLabelInset.
  LocalHeightThresholdMeters accepts fractions (2.5) in the ini. The row
  offers whole meters.
  Edit them with the game closed.

  The mod writes nothing else and never touches your save.

PERFORMANCE
  Everything is event-driven: the mod hooks the game's own functions and
  never scans the world on a timer. A world load costs a few sliced
  milliseconds. The dungeon view captures at 30 frames per second by default
  (MAP tab, 2-60), and it is the single most expensive row in the mod, so drop
  it first if you are short on headroom and raise it if you have room to spare.
  "Log performance" on the MOD tab writes a [PERF] line every 10 seconds to
  UE4SS.log if you want to see the numbers yourself.

KNOWN LIMITATIONS
  - Hidden walls are shown only while unopened and within range. Opened
    ones have no icon at all, by design.
  - Enemies come from the game's spawn and combat events. A type the mod has
    never seen may get its dot late or not at all. Bosses are recognized by
    name.
  - The dungeon view is a capture of the level around you, so stacked
    floors can look odd. The ceiling cut is automatic (MAP tab). Set it to
    Fixed and use "Ceiling cut" on the CAPTURE tab if you prefer one height.
  - The world map's icons for places you have not discovered follow the
    game's own rules. The ICONS tab has a "Discovered only" switch per
    category.
  - The Vector frame styles ask the engine to draw an outline without a
    texture. If the engine refuses, the Ring / Bars style is drawn instead
    and the Ctrl+Delete summary says "vector=failed".
  - The combat look follows the game's music state. A fight the game never
    switches its music for (it happens with a lone weak enemy) never
    triggers it, and the map comes back only when the music leaves the
    fight plus the restore delay. Ctrl+Delete prints the state it sees.

REPORTING A BUG
  Press Ctrl+Delete, then Ctrl+Shift+Delete, standing where the problem is,
  then quit to the desktop and attach
    ...\MortalShell2\Binaries\Win64\ue4ss\UE4SS.log
  and your MinimapConfig.ini. Say what you expected to see. If the mod
  crashed the game, turn on LocalDiscoveryTrace=true in MinimapConfig.ini
  and "Debug logging" on the MOD tab before reproducing it. The log will then
  name the last call the mod made. The optional debug collector (a separate
  download) gathers all of this into one zip.

CREDITS
  Built on UE4SS. Uses the game's own textures and font by reference. Nothing
  from the game is redistributed.

LICENSE
  MIT (see the LICENSE file): use it, change it, redistribute it, keep the
  notice.
