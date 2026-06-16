-- radioinfo.lua  radio tower / antenna probe + range tester for a pocket computer.
-- Reports whatever methods the antenna actually exposes (no assumptions), shows
-- tower stats if present, and measures link distance by pinging and replying to
-- other radioinfo instances. Run it on the pocket and a second one on a turtle to
-- read range from a dig site. Use it to confirm the radio API before trusting the
-- fleet comms swap.
-- keys: b = ping now   q = quit

local PROTO = "store"
local FREQ  = 1000

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
local function findModem()
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "modem" and peripheral.call(n, "isWireless") then return n end
  end
end

local me    = os.getComputerID()
local radio = findRadio()
local modem = findModem()
if not radio and not modem then print("No radio antenna or wireless modem."); return end
if radio and hasMethod(radio, "setFrequency") then pcall(peripheral.call, radio, "setFrequency", FREQ) end
if modem then rednet.open(modem) end

local METHODS = { "broadcast", "setFrequency", "getFrequency", "getHeight", "canBroadcast", "isValid" }
local present = {}
if radio then for _, m in ipairs(METHODS) do present[m] = hasMethod(radio, m) end end

local function q(name, ...)
  if not radio or not present[name] then return nil end
  local r = { pcall(peripheral.call, radio, name, ...) }
  if r[1] then return r[2] end
  return nil
end

local seen = {}
local pings, heard, selfEcho = 0, 0, 0

local function envSend(body)
  local m = {
    __r = true,
    id = me .. "-" .. os.epoch("utc") .. "-" .. math.random(0, 9999),
    from = me, body = body,
  }
  if radio then pcall(peripheral.call, radio, "broadcast", textutils.serialise(m)) end
  if modem then rednet.broadcast(m, PROTO) end
end

local function ping() pings = pings + 1; envSend({ kind = "ping" }) end

local W, Hh = term.getSize()
local function at(x, y, s, c)
  term.setCursorPos(x, y); if c then term.setTextColor(c) end; term.write(s)
end

local function draw()
  term.setBackgroundColor(colors.black); term.clear()
  at(1, 1, "RADIO INFO", colors.cyan)
  at(1, 2, "antenna: " .. (radio or "none"), radio and colors.lime or colors.red)
  local ms = {}
  for _, m in ipairs(METHODS) do ms[#ms + 1] = (present[m] and "+" or "-") .. m:sub(1, 4) end
  at(1, 3, table.concat(ms, " "), colors.gray)
  local y = 4
  local freq = q("getFrequency"); if freq ~= nil then at(1, y, "freq: " .. tostring(freq), colors.white); y = y + 1 end
  local hgt = q("getHeight")
  if hgt ~= nil then
    at(1, y, "height: " .. tostring(hgt), colors.white); y = y + 1
    local rng = math.min(3072, (tonumber(hgt) or 0) * 128)
    at(1, y, ("range ~%d safe ~%d"):format(rng, math.floor(rng * 0.85)), colors.lightGray); y = y + 1
  end
  local cb = q("canBroadcast"); if cb ~= nil then at(1, y, "canBroadcast: " .. tostring(cb), colors.white); y = y + 1 end
  local iv = q("isValid"); if iv ~= nil then at(1, y, "isValid: " .. tostring(iv), colors.white); y = y + 1 end
  at(1, y, "modem: " .. (modem and "yes" or "no"), colors.gray); y = y + 1
  at(1, y, ("ping %d  heard %d  echo %d"):format(pings, heard, selfEcho), colors.gray); y = y + 1
  at(1, y, "heard:", colors.cyan); y = y + 1
  local rows = {}
  for id, info in pairs(seen) do rows[#rows + 1] = { id = id, info = info } end
  table.sort(rows, function(a, b) return (a.info.dist or 1e9) < (b.info.dist or 1e9) end)
  for _, r in ipairs(rows) do
    if y > Hh - 1 then break end
    local d = r.info.dist and (math.floor(r.info.dist) .. "m") or "?"
    at(1, y, ("#%s %s %s %ds"):format(r.id, r.info.kind or "?", d, math.floor(os.clock() - r.info.t)), colors.white)
    y = y + 1
  end
  at(1, Hh, "b=ping  q=quit", colors.gray)
end

ping()
local rt = os.startTimer(2)
local dt = os.startTimer(0.5)
while true do
  local ev = { os.pullEventRaw() }
  local k = ev[1]
  if k == "terminate" then break
  elseif k == "timer" then
    if ev[2] == rt then ping(); rt = os.startTimer(2)
    elseif ev[2] == dt then draw(); dt = os.startTimer(0.5) end
  elseif k == "char" then
    if ev[2] == "q" then break elseif ev[2] == "b" then ping() end
  elseif k == "radio_message" or k == "rednet_message" then
    local raw, dist
    if k == "radio_message" then
      raw, dist = ev[3], ev[4]
      if type(raw) == "string" then local ok, d = pcall(textutils.unserialise, raw); if ok then raw = d end end
    else
      raw, dist = ev[3], ev[5]
    end
    if type(raw) == "table" and raw.__r then
      if raw.from == me then
        if k == "radio_message" then selfEcho = selfEcho + 1 end
      else
        heard = heard + 1
        seen[raw.from] = { dist = dist, kind = raw.body and raw.body.kind, t = os.clock() }
        if raw.body and raw.body.kind == "ping" then envSend({ kind = "pong" }) end
      end
    end
  end
end
term.setTextColor(colors.white); term.setBackgroundColor(colors.black); term.clear(); term.setCursorPos(1, 1)
print("radioinfo stopped")
