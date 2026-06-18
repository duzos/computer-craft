-- gpsprobe.lua  live radio-GPS field-accuracy probe (coloured GUI). Continuously
-- pings the LIVE gpshost towers (no tower changes, no responder peer -- they reply
-- on the "gps" proto).
--   run:  gpsprobe          interactive GUI (below)
--         gpsprobe list      one-shot text dump of each tower's pos + stats to the
--                            screen AND gpsprobe.txt (latest run), then exit
-- Two views in the GUI, toggle with m:
--   TABLE  per tower: measured distance, jitter, and -- if you've entered your F3
--          position -- the error vs true distance, plus the trilaterated fix/error.
--   MAP    top-down (x/z) minimap: each tower is an id node, you are a '@' node, and
--          a faint range ring is drawn at each tower's measured distance (they cross
--          at you). With only 3 towers it still plots an approximate x/z '@' (yellow,
--          altitude ignored); a 4th tower or an entered Y makes it an exact fix.
-- Needs the gpshost towers running (4 for a 3D fix; 3 gives a 2D x/z fix once you've
-- entered your Y), and comms.lua + gps2.lua here (radio antenna -- distance only
-- arrives over radio). AVG mode windows the samples for an accurate stationary fix;
-- LIVE mode uses only the latest ping per tower so the fix tracks you as you move.
-- keys: m = table/map   p = set my F3 pos   l = AVG/LIVE   r = clear samples   q = quit

local comms  = require("comms")
local gps2   = require("gps2")
local map    = require("map")
local beacon = require("beacon")

local GPS_PROTO  = "gps"
local RADIO_FREQ = 1000
local PING_EVERY = 0.5     -- seconds between locate pings
local REDRAW     = 0.3     -- seconds between redraws
local MAXS       = 16      -- distance samples kept per tower
local STALE      = 4       -- tower dropped from the view if unheard this long
local LIST_SECS  = 2.5     -- "gpsprobe list" gather window
local LIST_FILE  = "gpsprobe.txt"  -- "gpsprobe list" also writes the latest dump here

local args = { ... }
local listMode = (args[1] == "list")

comms.open({ freq = RADIO_FREQ, proto = GPS_PROTO })
if not comms.up() then print("no radio/modem found"); return end

local mypos = nil          -- your actual F3 position, for the error columns
local live  = false        -- LIVE = latest ping only (tracks movement); AVG = windowed
local view  = "table"      -- "table" | "map"
local hosts = {}           -- id -> { pos, ds = {recent dists}, last }
local vp     = map.viewport({ auto = true })          -- map viewport: auto-fit until you zoom/pan
local locs   = beacon.tracker()                       -- other devices heard via loc beacons
local mapProj = nil                                   -- last map projection, for click->world
local sendLoc = beacon.sender("probe#" .. os.getComputerID(), "probe")  -- make this probe visible
local function panStep() return 5 / math.max(vp.scale or 1, 0.001) end

local function ping() comms.send("all", { type = "gpsq" }, GPS_PROTO) end

local function record(id, pos, dist)
  local h = hosts[id]
  if not h then h = { ds = {} }; hosts[id] = h end
  h.pos = pos
  h.ds[#h.ds + 1] = dist
  while #h.ds > MAXS do table.remove(h.ds, 1) end
  h.last = os.clock()
end

local function dist3(a, b)
  local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function liveIds()
  local now, ids = os.clock(), {}
  for id, h in pairs(hosts) do
    if #h.ds > 0 and now - (h.last or 0) <= STALE then ids[#ids + 1] = id end
  end
  table.sort(ids)
  return ids
end

-- shared: live towers with their chosen distance + spread, and the current fix
local function compute()
  local towers, pts, anyFrac = {}, {}, false
  for _, id in ipairs(liveIds()) do
    local h = hosts[id]
    local mn, mx, sum = h.ds[1], h.ds[1], 0
    for _, d in ipairs(h.ds) do
      if d < mn then mn = d end
      if d > mx then mx = d end
      sum = sum + d
      if math.abs(d - math.floor(d + 0.5)) > 1e-6 then anyFrac = true end
    end
    local val = live and h.ds[#h.ds] or (sum / #h.ds)
    towers[#towers + 1] = { id = id, pos = h.pos, val = val, spread = mx - mn }
    pts[#pts + 1] = { x = h.pos.x, y = h.pos.y, z = h.pos.z, d = val }
  end
  local fix, kind
  if #pts >= 4 then fix, kind = gps2.trilaterate(pts), "3D"
  elseif #pts == 3 and mypos then fix, kind = gps2.trilaterate2d(pts, mypos.y), "2D" end
  return towers, pts, fix, kind, anyFrac
end

local W, H = term.getSize()
local function at(x, y, s, c)
  if y < 1 or y > H or x < 1 or x > W then return end
  term.setCursorPos(x, y)
  if c then term.setTextColor(c) end
  term.setBackgroundColor(colors.black)
  term.write(s)
end

local function ncolour(n) return n >= 4 and colors.lime or (n >= 3 and colors.orange or colors.red) end

local function strip(y, bg)
  if y < 1 or y > H then return end
  term.setCursorPos(1, y); term.setBackgroundColor(bg); term.write((" "):rep(W))
  term.setBackgroundColor(colors.black)
end

local function atc(x, y, s, fg, bg)
  if y < 1 or y > H or x < 1 or x > W then return end
  term.setCursorPos(x, y); term.setTextColor(fg or colors.white); term.setBackgroundColor(bg or colors.black)
  term.write(s); term.setBackgroundColor(colors.black)
end

local function drawTable()
  term.setBackgroundColor(colors.black); term.clear()
  local towers, _, fix, kind, anyFrac = compute()
  at(1, 1, "GPS PROBE", colors.cyan)
  local tag = "n" .. #towers
  at(W - #tag + 1, 1, tag, ncolour(#towers))
  local badge = live and "[LIVE]" or "[AVG]"
  at(1, 2, badge, live and colors.lime or colors.lightBlue)
  at(#badge + 2, 2, anyFrac and "float" or "INT?", anyFrac and colors.lime or colors.orange)
  if mypos then
    at(1, 3, ("@ %d,%d,%d"):format(mypos.x, mypos.y, mypos.z), colors.lightGray)
  else
    at(1, 3, "no pos (press p)", colors.gray)
  end

  local y = 4
  for _, t in ipairs(towers) do
    at(1, y, "#" .. t.id, colors.white)
    at(5, y, ("%6.1f"):format(t.val), colors.white)
    at(12, y, ("j%.1f"):format(t.spread), t.spread > 1 and colors.orange or colors.lightGray)
    if mypos then
      local td = dist3(t.pos, mypos)
      local err = t.val - td
      local pct = td ~= 0 and math.abs(err / td * 100) or 0
      local c = pct < 2 and colors.lime or (pct < 5 and colors.orange or colors.red)
      at(18, y, ("e%+.1f"):format(err), c)
    end
    y = y + 1
  end

  y = y + 1
  if kind == "3D" then
    if fix then
      at(1, y, ("FIX %.1f %.1f %.1f"):format(fix.x, fix.y, fix.z), colors.cyan); y = y + 1
      if mypos then
        local fe = dist3(fix, mypos)
        local c = fe < 2 and colors.lime or (fe < 5 and colors.orange or colors.red)
        at(1, y, ("err %.2fm  dy%+.1f"):format(fe, fix.y - mypos.y), c)
      end
    else
      at(1, y, "FIX: degenerate geom", colors.red)
    end
  elseif kind == "2D" then
    if fix then
      at(1, y, ("2D %.1f %.1f  y%d"):format(fix.x, fix.z, mypos.y), colors.cyan); y = y + 1
      local ex, ez = fix.x - mypos.x, fix.z - mypos.z
      local he = math.sqrt(ex * ex + ez * ez)
      local c = he < 2 and colors.lime or (he < 5 and colors.orange or colors.red)
      at(1, y, ("2D err %.2fm (y given)"):format(he), c)
    else
      at(1, y, "2D: towers collinear", colors.red)
    end
  elseif #towers == 3 then
    at(1, y, "3 towers: press p (need Y)", colors.orange)
  else
    at(1, y, ("need 3+ towers (have %d)"):format(#towers), colors.orange)
  end
  at(1, H, "m=map p=pos l=live r=clr q", colors.gray)
end

-- top-down minimap, now rendered by the shared map.lua module: gpsprobe just builds
-- the marker list (towers + you + any loc beacons heard) and the range rings, then
-- hands them to map.draw with the current viewport. zoom/pan/follow live in vp.
local function drawMap()
  term.setBackgroundColor(colors.black); term.clear()
  local towers, pts, fix = compute()

  strip(1, colors.blue)
  atc(2, 1, "MINIMAP", colors.white, colors.blue)
  local modeTag = (live and "LIVE" or "AVG") .. (vp.follow and " FOL" or (vp.auto and " FIT" or ""))
  atc(W - #modeTag, 1, modeTag, colors.white, colors.blue)

  if #towers == 0 then
    at(2, 3, "no towers heard", colors.gray)
    at(1, H, "m=table  p=pos  l=live  q", colors.gray)
    return
  end

  -- self fix: exact (3D/2D) or rough 2D, falling back to an entered pos
  local me, approx = fix, false
  if not me and #towers >= 3 then me = gps2.trilaterate2d(pts, mypos and mypos.y or nil); approx = not mypos end
  if not me then me, approx = mypos, true end
  local pcol = approx and colors.yellow or colors.lime

  -- markers: each tower (its id as the glyph), other devices' loc beacons, then you
  local markers, rings = {}, {}
  for _, t in ipairs(towers) do
    markers[#markers + 1] = map.marker(t.pos.x, t.pos.z, "#" .. t.id, "tower", { char = tostring(t.id) })
    rings[#rings + 1] = { x = t.pos.x, z = t.pos.z, r = t.val, colour = colors.gray }
  end
  local now = os.clock()
  for _, r in ipairs(locs.list(now)) do
    if r.id ~= os.getComputerID() then markers[#markers + 1] = map.marker(r.pos.x, r.pos.z, r.label, r.kind) end
  end
  if mypos and me ~= mypos then
    markers[#markers + 1] = map.marker(mypos.x, mypos.z, "pos", nil, { char = "+", colour = colors.lightGray })
  end
  if me then
    markers[#markers + 1] = map.marker(me.x, me.z, "you", "self", { char = "@", colour = pcol, follow = true })
  end

  at(1, 2, ("n%d  x%.2f"):format(#towers, vp.scale or 0), ncolour(#towers))
  if me then
    local r = ("@ %.0f,%.0f"):format(me.x, me.z)
    at(W - #r + 1, 2, r, pcol)
  end

  mapProj = map.draw(term, markers, vp, {
    box = { x1 = 1, y1 = 3, x2 = W, y2 = H - 2 }, border = true, rings = rings,
  })

  at(1, H - 1, "#", colors.cyan); at(3, H - 1, "tower", colors.lightGray)
  at(11, H - 1, "@", colors.lime); at(13, H - 1, "you", colors.lightGray)
  at(1, H, "m +/-zoom arrows f=fol g=fit q", colors.gray)
end

local function draw()
  if view == "map" then drawMap() else drawTable() end
end

local function askPos()
  term.setBackgroundColor(colors.black); term.clear(); term.setCursorPos(1, 1)
  term.setTextColor(colors.white)
  local function num(label) write(label .. ": "); return tonumber(read()) end
  local x, y, z = num("my X"), num("my Y"), num("my Z")
  if x and y and z then mypos = { x = x, y = y, z = z } end
end

-- one-shot text dump for "gpsprobe list": ping for a couple of seconds, then print
-- each tower's surveyed pos + measured distance/jitter/sample count and the fix.
-- Reuses compute() (AVG, partial-tower tolerant) so it shows even 1-3 towers.
local function runList()
  ping()
  local deadline, nextPing = os.clock() + LIST_SECS, os.clock() + PING_EVERY
  while os.clock() < deadline do
    local m = comms.receive(GPS_PROTO, 0.3)
    if m and m.dist and type(m.body) == "table" and m.body.type == "gpsr"
       and type(m.body.pos) == "table" then
      record(m.from, m.body.pos, m.dist)
    end
    if os.clock() >= nextPing then ping(); nextPing = os.clock() + PING_EVERY end
  end
  local towers, _, fix, kind = compute()
  local lines = {}
  local function emit(s) lines[#lines + 1] = s; print(s) end   -- to screen and file
  emit(("gps towers heard: %d"):format(#towers))
  if #towers > 0 then
    emit("id      x     y     z     dist  jit  n")
    for _, t in ipairs(towers) do
      emit(("#%-4d %5d %5d %5d %6.1f %4.1f %2d"):format(
        t.id, t.pos.x, t.pos.y, t.pos.z, t.val, t.spread, #hosts[t.id].ds))
    end
    if kind == "3D" and fix then
      emit(("fix: %.1f %.1f %.1f (3D)"):format(fix.x, fix.y, fix.z))
    elseif kind == "2D" and fix then
      emit(("fix: %.1f ?  %.1f (2D x/z, need 4 for 3D)"):format(fix.x, fix.z))
    else
      emit(("no fix: need 4 towers, have %d"):format(#towers))
    end
  else
    emit("  none -- towers down or out of radio range")
  end
  local f = fs.open(LIST_FILE, "w")
  if f then
    f.write(table.concat(lines, "\n") .. "\n")
    f.close()
    print("-> " .. LIST_FILE)
  end
end

if listMode then runList(); return end

ping()
local pt = os.startTimer(PING_EVERY)
local dt = os.startTimer(REDRAW)
draw()
while true do
  local ev = { os.pullEventRaw() }
  local k = ev[1]
  if k == "terminate" then break
  elseif k == "timer" then
    if ev[2] == pt then
      ping()
      local _, _, f = compute(); if f then sendLoc(os.clock(), f) end   -- beacon our fix to other maps
      pt = os.startTimer(PING_EVERY)
    elseif ev[2] == dt then draw(); dt = os.startTimer(REDRAW) end
  elseif k == "char" then
    if ev[2] == "q" then break
    elseif ev[2] == "r" then hosts = {}; draw()
    elseif ev[2] == "l" then live = not live; draw()
    elseif ev[2] == "m" then view = (view == "map") and "table" or "map"; draw()
    elseif ev[2] == "f" then map.setFollow(vp, not vp.follow); draw()
    elseif ev[2] == "g" then vp.follow = false; map.fit(vp); draw()
    elseif ev[2] == "+" or ev[2] == "=" then map.zoom(vp, 1.5); draw()
    elseif ev[2] == "-" or ev[2] == "_" then map.zoom(vp, 1 / 1.5); draw()
    elseif ev[2] == "p" then
      askPos(); pt = os.startTimer(PING_EVERY); dt = os.startTimer(REDRAW); draw()
    end
  elseif k == "key" then
    if ev[2] == keys.left then map.pan(vp, -panStep(), 0); draw()
    elseif ev[2] == keys.right then map.pan(vp, panStep(), 0); draw()
    elseif ev[2] == keys.up then map.pan(vp, 0, -panStep()); draw()
    elseif ev[2] == keys.down then map.pan(vp, 0, panStep()); draw() end
  elseif k == "mouse_click" then
    if view == "map" and mapProj and map.inBox(mapProj, ev[3], ev[4]) then
      local wx, wz = map.screenToWorld(mapProj, ev[3], ev[4])   -- tap to recentre there
      map.center(vp, wx, wz); draw()
    end
  elseif k == "radio_message" then
    local raw, dist = ev[3], ev[4]
    if type(raw) == "string" then local ok, d = pcall(textutils.unserialise, raw); if ok then raw = d end end
    if dist and type(raw) == "table" and raw.__c and raw.proto == GPS_PROTO and raw.from ~= os.getComputerID()
       and type(raw.body) == "table" then
      if raw.body.type == "gpsr" and type(raw.body.pos) == "table" then
        record(raw.from, raw.body.pos, dist)
      elseif raw.body.type == "loc" then
        locs.offer(raw.from, raw.body, dist, os.clock())
      end
    end
  end
end
term.setTextColor(colors.white); term.setBackgroundColor(colors.black); term.clear(); term.setCursorPos(1, 1)
print("gpsprobe stopped")
