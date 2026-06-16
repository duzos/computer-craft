-- startup  --  combined launcher for the computer that owns the radio tower.
-- Runs store.lua and gpshost.lua together on ONE computer, in parallel. A single
-- tower delivers its radio_message events to only ONE computer, so a SECOND computer
-- sharing the tower goes deaf (that is why the store stopped hearing the fleet). The
-- fix is to run the store and the GPS host on the same computer / one radio.
--
-- On this computer you need: store.lua, gpshost.lua, comms.lua, and every store
-- peripheral reachable from HERE -- barrels/furnaces over the wired modem, plus the
-- monitors, chat box and inventory manager (networked, or attached to this computer).
--
-- FIRST set the GPS position: run `gpshost` once by hand to save gpshost.state, so it
-- does not sit on its first-boot prompt while the store's command line also wants
-- input. After that, this startup runs both with no prompts.
--
-- shell.run launches each program the normal way, so require() and the module path
-- are set up (loadfile alone does NOT give the chunk require). They get a comms
-- instance each and coexist on the one radio via distinct protos ("store" vs "gps").
-- Adjust the names below if your files are saved without the .lua extension.

parallel.waitForAny(
  function() shell.run("store.lua") end,
  function() shell.run("gpshost.lua") end
)
