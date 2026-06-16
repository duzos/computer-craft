-- radioping.lua  radio link tester + GPS distance-accuracy probe.
-- Broadcasts a ping on the radio every interval and watches for it to echo back.
-- The mini antenna only hears its own broadcast when a tower in range relays it,
-- so a returning echo = the tower responded (and gives the link distance).
--
-- Use it to vet whether radio_message distance is good enough for the radio-GPS
-- (3D trilateration). The monitor shows the RAW distance with decimals, jitter
-- (min/max over recent samples), whether the value looks integer-rounded, and the
-- error vs a known actual distance. Stand the responder at a FIXED point, read its
-- F3 coords and yours, walk to known distances (close/mid/far + a big VERTICAL
-- gap) and compare: integer-rounding or a hard distance cap kills 3D and forces a
-- pivot. Standalone: does not use comms.lua.
--
-- modes:
--   radioping [knownDist]   ping monitor (default; the moving turtle/pocket).
--                           optional knownDist = true distance to the peer, for
--                           the error readout (or set it live with the 'd' key).
--   radioping respond       headless responder: pongs every ping it hears. Run on
--                           a second computer at a FIXED, known position to be the
--                           reference peer for the round trip.
-- keys (monitor): b = ping now   d = set known distance   q = quit

local PROTO = "store"
local FREQ  = 1000
local PERIOD = 2      -- seconds between pings
local STALE  = 6      -- no echo within this many seconds = link DOWN
local MAXS   = 20     -- recent distance samples kept for jitter/precision stats

local function methodsOf(name)
  local ok, m = pcall(peripheral.getMethods, name)
  if ok and type(m) == "table" then return m end
  return {}
end
local function hasMethod(name, want)
  for _, m in ipairs(methodsOf(name)) do if m == want then return true end end
  return false
end
local function findRadio()
  for _, n in ipairs(peripheral.getNames()) do
    if hasMethod(n, "broadcast") then return n end
  end
end

local args  = { ... }
local mode  = (args[1] == "respond") and "respond" or "monitor"
local known = tonumber(args[1]) or tonumber(args[2])   -- true distance to peer, for the error readout
local me    = os.getComputerID()
local radio = findRadio()
if not radio then print("No radio antenna found."); return end
if hasMethod(radio, "setFrequency") then pcall(peripheral.call, radio, "setFrequency", FREQ) end

local function bcast(m) pcall(peripheral.call, radio, "broadcast", textutils.serialise(m)) end

if mode == "respond" then
  print("radioping responder #" .. me .. " on freq " .. FREQ .. " -- pongs every ping. Ctrl+T to quit.")
  local n = 0
  while true do
    local ev = { os.pullEventRaw() }
    if ev[1] == "terminate" then break
    elseif ev[1] == "radio_message" then
      local raw = ev[3]
      if type(raw) == "string" then local ok, dd = pcall(textutils.unserialise, raw); if ok then raw = dd end end
      if type(raw) == "table" and raw.__p and raw.seq and not raw.pong and raw.from ~= me then
        bcast({ __p = true, from = me, pong = raw.from, seq = raw.seq })
        n = n + 1
        print(("pong #%d -> #%s seq %s (%sm)"):format(n, tostring(raw.from), tostring(raw.seq), tostring(ev[4])))
      end
    end
  end
  print("responder stopped"); return
end

local seq, lastEcho, lastDist = 0, nil, nil
local pings, echoes = 0, 0
local seen = {}
local samples = {}    -- recent raw echo distances

local function pushSample(d)
  if type(d) ~= "number" then return end
  samples[#samples + 1] = d
  while #samples > MAXS do table.remove(samples, 1) end
end

local function stats()
  local n = #samples
  if n == 0 then return nil end
  local mn, mx, frac = samples[1], samples[1], false
  for _, d in ipairs(samples) do
    if d < mn then mn = d end
    if d > mx then mx = d end
    if math.abs(d - math.floor(d + 0.5)) > 1e-6 then frac = true end
  end
  return { n = n, min = mn, max = mx, spread = mx - mn, frac = frac }
end

local function send()
  seq = seq + 1; pings = pings + 1
  bcast({ __p = true, id = me .. "-" .. seq, from = me, seq = seq })
end

local function up() return lastEcho and (os.clock() - lastEcho) <= STALE end

local W, Hh = term.getSize()
local function at(x, y, s, c)
  term.setCursorPos(x, y); if c then term.setTextColor(c) end; term.write(s)
end

local function setKnown()
  term.setBackgroundColor(colors.black); term.clear(); term.setCursorPos(1, 1)
  term.setTextColor(colors.white); term.write("actual distance (blank = clear): ")
  known = tonumber(read())     -- nil clears it
end

local function draw()
  term.setBackgroundColor(colors.black); term.clear()
  at(1, 1, "GPS DIST PROBE #" .. me, colors.cyan)
  at(1, 2, up() and "LINK UP" or "LINK DOWN", up() and colors.lime or colors.red)
  local d   = lastDist and (("%.3f"):format(lastDist) .. "m") or "?"
  local age = lastEcho and (math.floor(os.clock() - lastEcho) .. "s ago") or "never"
  at(1, 3, "echo: " .. d .. " (" .. age .. ")", colors.white)
  local y = 4
  local s = stats()
  if s then
    if s.n >= 5 then
      if s.frac then at(1, y, ("prec: float (3D ok)  n=%d"):format(s.n), colors.lime)
      else at(1, y, ("prec: INTEGER? coarse  n=%d"):format(s.n), colors.orange) end
    else
      at(1, y, ("prec: sampling... n=%d"):format(s.n), colors.gray)
    end
    y = y + 1
    at(1, y, ("jitter: %.3fm  [%.2f..%.2f]"):format(s.spread, s.min, s.max),
       s.spread > 1 and colors.orange or colors.lightGray); y = y + 1
  end
  if known then
    if lastDist then
      local err = lastDist - known
      local pct = known ~= 0 and (err / known * 100) or 0
      at(1, y, ("err: %+.3fm (%+.1f%%) vs %.2f"):format(err, pct, known),
         math.abs(pct) > 5 and colors.orange or colors.lime); y = y + 1
    else
      at(1, y, ("known %.2f, no echo yet"):format(known), colors.gray); y = y + 1
    end
  else
    at(1, y, "known: unset (press d)", colors.gray); y = y + 1
  end
  at(1, y, ("ping %d  echo %d"):format(pings, echoes), colors.gray); y = y + 1
  at(1, y, "others heard:", colors.cyan); y = y + 1
  local rows = {}
  for id, info in pairs(seen) do rows[#rows + 1] = { id = id, info = info } end
  table.sort(rows, function(a, b) return (a.info.dist or 1e9) < (b.info.dist or 1e9) end)
  for _, r in ipairs(rows) do
    if y > Hh - 1 then break end
    local rd = r.info.dist and (("%.2f"):format(r.info.dist) .. "m") or "?"
    at(1, y, ("#%s %s %ds"):format(r.id, rd, math.floor(os.clock() - r.info.t)), colors.white)
    y = y + 1
  end
  at(1, Hh, "b=ping d=known q=quit", colors.gray)
end

send()
local pt = os.startTimer(PERIOD)
local dt = os.startTimer(0.5)
while true do
  local ev = { os.pullEventRaw() }
  local k = ev[1]
  if k == "terminate" then break
  elseif k == "timer" then
    if ev[2] == pt then send(); pt = os.startTimer(PERIOD)
    elseif ev[2] == dt then draw(); dt = os.startTimer(0.5) end
  elseif k == "char" then
    if ev[2] == "q" then break
    elseif ev[2] == "b" then send()
    elseif ev[2] == "d" then setKnown(); draw() end
  elseif k == "radio_message" then
    local raw, dist = ev[3], ev[4]
    if type(raw) == "string" then local ok, dd = pcall(textutils.unserialise, raw); if ok then raw = dd end end
    if type(raw) == "table" and raw.__p then
      if raw.from == me then
        echoes = echoes + 1; lastEcho = os.clock(); lastDist = dist; pushSample(dist)  -- own broadcast relayed back
      elseif raw.pong == me then
        echoes = echoes + 1; lastEcho = os.clock(); lastDist = dist; pushSample(dist)  -- responder answered our ping
        seen[raw.from] = { dist = dist, t = os.clock() }
      else
        seen[raw.from] = { dist = dist, t = os.clock() }
      end
    end
  end
end
term.setTextColor(colors.white); term.setBackgroundColor(colors.black); term.clear(); term.setCursorPos(1, 1)
print("radioping stopped")
