-- fleetmap.lua  standalone fleet map for a computer wired to an advanced MONITOR (falls
-- back to the terminal). It listens for the presence beacons every fleet device now
-- broadcasts (beacon.lua, `{type="loc"}` on the "gps" proto) and plots them top-down with
-- map.lua, auto-fit to a SQUARE that stays zoomed to show every device at once: the CORE
-- (store), the airship, the quarry/tree/wheat/crafter turtles, the pad and any probe.
--
-- It mainly pulls the aggregated fleet from the STORE (the store hears every device via its
-- tall tower, so a far/short-range map device still gets the whole picture), and merges in any
-- beacons it can hear directly as a fallback. Give the host a RADIO ANTENNA or wireless modem.
-- Deploy as role `map`.
--   keys: f = follow nothing/auto, q = quit   tap a marker (monitor) to centre on it
--
-- The renderer is reused verbatim from gpsprobe/shipnav; this file just feeds it markers.

local comms  = require("comms")
local map    = require("map")
local beacon = require("beacon")

local RADIO_FREQ = 1000
local GPS_PROTO  = "gps"
local STORE_PROTO = "store"
local REDRAW     = 1.0     -- seconds between redraws
local LOCS_EVERY = 2.0     -- seconds between asking the store for its fleet aggregate

comms.open({ freq = RADIO_FREQ, proto = GPS_PROTO })
if not comms.up() then print("no radio antenna or modem found"); return end

local mon = peripheral.find("monitor")
if mon then pcall(mon.setTextScale, 0.5) end
local dev = mon or term

local tracker = beacon.tracker()
local storeList = {}      -- aggregated fleet from the store (primary source)
local lastLocs = -1e9
local vp = map.viewport({ auto = true, aspect = map.SQUARE_ASPECT })   -- square, zoomed to fit all
local proj = nil
local me = os.getComputerID()

local function at(x, y, s, fg, bg)
  dev.setCursorPos(x, y)
  if fg then dev.setTextColor(fg) end
  if bg then dev.setBackgroundColor(bg) end
  dev.write(s); dev.setBackgroundColor(colors.black)
end

-- decode a raw transport event into the comms envelope (+ radio distance), or nil
local function decode(ev)
  local k = ev[1]
  if k == "radio_message" then
    local raw, dist = ev[3], ev[4]
    if type(raw) == "string" then local ok, d = pcall(textutils.unserialise, raw); if ok then raw = d end end
    if type(raw) == "table" and raw.__c then return raw, dist end
  elseif k == "rednet_message" then
    local msg = ev[3]
    if type(msg) == "table" and msg.__c then return msg, nil end   -- dispatch on env.proto below
  end
  return nil
end

local function render()
  local w, h = dev.getSize()
  dev.setBackgroundColor(colors.black); dev.setTextColor(colors.white); dev.clear()
  local now = os.clock()

  -- primary: the store's aggregate; fall back to anything we heard directly. Merge by id.
  local byId = {}
  for _, r in ipairs(storeList) do if r.pos then byId[r.id] = r end end
  for _, r in ipairs(tracker.list(now)) do if not byId[r.id] then byId[r.id] = r end end
  local markers = {}
  for _, r in pairs(byId) do
    if r.id ~= me and r.pos then markers[#markers + 1] = map.marker(r.pos.x, r.pos.z, r.label, r.kind) end
  end

  dev.setCursorPos(1, 1); dev.setBackgroundColor(colors.blue); dev.clearLine()
  at(1, 1, " FLEET MAP", colors.white, colors.blue)
  local tag = (#markers == 0) and "waiting" or (#markers .. " online")
  at(w - #tag, 1, tag, colors.white, colors.blue)

  if #markers == 0 then
    at(2, 3, "no fleet yet", colors.gray)
    at(2, 4, "(store quiet / nothing beaconing)", colors.gray)
    at(1, h, "q quit", colors.gray)
    proj = nil
    return
  end

  proj = map.draw(dev, markers, vp, {
    box = { x1 = 1, y1 = 2, x2 = w, y2 = h - 1 }, border = true, scalebar = true, chunkGrid = true,
  })

  -- legend of the kinds currently visible
  local seen, parts = {}, {}
  for _, m in ipairs(markers) do
    if m.kind and not seen[m.kind] then seen[m.kind] = true; parts[#parts + 1] = (m.char or "?") .. m.kind end
  end
  at(1, h, table.concat(parts, " "), colors.gray)
end

render()
local rt = os.startTimer(REDRAW)
while true do
  local ev = { os.pullEventRaw() }
  local k = ev[1]
  if k == "terminate" then break
  elseif k == "timer" and ev[2] == rt then
    if os.clock() - lastLocs >= LOCS_EVERY then comms.send("store", "locs", STORE_PROTO); lastLocs = os.clock() end
    render(); rt = os.startTimer(REDRAW)
  elseif k == "char" then
    if ev[2] == "q" then break
    elseif ev[2] == "f" then map.setFollow(vp, false); map.fit(vp); render() end
  elseif k == "monitor_touch" or k == "mouse_click" then
    if proj and map.inBox(proj, ev[3], ev[4]) then
      local wx, wz = map.screenToWorld(proj, ev[3], ev[4])
      map.center(vp, wx, wz); render()
    end
  else
    local env, dist = decode(ev)
    if env and env.from ~= me then
      if env.proto == GPS_PROTO then
        tracker.offer(env.from, env.body, dist, os.clock())            -- direct beacons (fallback)
      elseif env.proto == STORE_PROTO and (env.to == me or env.to == "all") and type(env.body) == "string" then
        local ok, arr = pcall(textutils.unserialise, env.body)         -- the store's aggregate
        if ok and type(arr) == "table" then storeList = arr end
      end
    end
  end
end
dev.setBackgroundColor(colors.black); dev.setTextColor(colors.white); dev.clear(); dev.setCursorPos(1, 1)
if mon then pcall(mon.setBackgroundColor, colors.black); pcall(mon.clear) end
print("fleetmap stopped")
