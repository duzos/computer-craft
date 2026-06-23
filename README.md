<div align="center">

# ComputerCraft Scripts

### A grab-bag of Lua programs for ComputerCraft / CC: Tweaked turtles and computers.

![Lua](https://img.shields.io/badge/Lua-2C2D72?style=for-the-badge&logo=lua&logoColor=white)
![CC: Tweaked](https://img.shields.io/badge/CC%3A%20Tweaked-Minecraft-62B47A?style=for-the-badge)

</div>

## What is it?

A collection of [ComputerCraft / CC: Tweaked](https://tweaked.cc/) Lua programs written for the **Summerhelm** Minecraft server — automation for turtles, GPS, communications, and general utilities. They're drop-in scripts rather than a single packaged program.

## What's in here

**Turtle automation**
- `quarry.lua`, `quarry2.lua` — dig out a quarry
- `treefarm.lua` — automated tree farming
- `wheatfarm.lua` — automated wheat farming
- `crafter.lua` — turtle crafting

**GPS & positioning**
- `gpshost.lua`, `gps2.lua`, `gpsprobe.lua`, `gpsrange.lua`, `range.lua` — set up and query a GPS network

**Communications & radio**
- `comms.lua`, `radioping.lua`, `radioinfo.lua`, `radiotest.lua` — messaging between computers

**Navigation & mapping**
- `shipnav.lua`, `fleetmap.lua`, `map.lua` — movement and map tooling

**Utilities**
- `startup.lua` — runs on boot
- `update.lua` — pull the latest scripts
- `store.lua`, `storepad.lua` — storage handling
- `beacon.lua`, `boilerkeeper.lua`, `redstone.lua` — assorted helpers

## Usage

Drop a script onto a ComputerCraft computer or turtle (paste it in, or `wget` it from this repo's raw URLs) and run it by name:

```
quarry
```

Some programs expect a particular setup — fuelled turtles, a running GPS host, or paired computers on the same channel — so read the top of each file before running it.

## Notes

These are personal/server scripts for Summerhelm, shared as-is. There's no build step — it's all plain Lua.

By [Duzo](https://duzo.is-a.dev/).
