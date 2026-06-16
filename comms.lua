-- comms.lua  shared transport for the store / quarry / pad fleet.
-- One envelope over either rednet (wireless OR wired modem) or the ClassicPeripherals
-- radio (tower on the store, mini antenna on turtles/pocket). A dual node sends
-- on both; receivers dedupe by envelope id so a doubled delivery is harmless.
--
-- Addressing is by envelope, not transport: a sender sets `to` to a computer id,
-- "store", or "all"; a node answers to its own id, "all", and any name it
-- registered with listenAs. Both transports just broadcast and receivers filter,
-- so there is no rednet.lookup and nothing to discover.
--
-- RADIO ASSUMPTIONS - verify with radioinfo before trusting this on a live dig:
--   * the antenna/tower peripheral exposes broadcast(string)
--   * it fires a "radio_message" event shaped (event, side, message, distance)
--   * optional setFrequency(n) is used only if the peripheral has it
-- If the real antenna API differs, THIS FILE is the only thing to change.

local comms = {}

local FREQ  = 1000
local PROTO = "store"
local me    = os.getComputerID()

local radioName
local modemNames = {}   -- every modem opened for rednet (wireless AND wired)
local names = {}
local seen  = {}
local SEEN_TTL = 30
local lastPrune = 0

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
  return nil
end

-- open EVERY modem: wireless for over-air links, wired for the store/boiler cable
-- network (the store has no wireless modem - it uses the radio tower - so the only
-- way to reach the rednet-only boiler is over the wired modem they share). rednet.broadcast
-- then goes out on all open modems and the envelope dedupe drops any doubled delivery.
local function openModems()
  modemNames = {}
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "modem" then
      if not rednet.isOpen(n) then rednet.open(n) end
      modemNames[#modemNames + 1] = n
    end
  end
end

local function newId()
  return ("%d-%d-%d"):format(me, os.epoch("utc"), math.random(0, 999999))
end

local function prune()
  local now = os.clock()
  if now - lastPrune < SEEN_TTL then return end   -- O(n) sweep at most once per TTL
  lastPrune = now
  for k, t in pairs(seen) do if now - t > SEEN_TTL then seen[k] = nil end end
end

function comms.open(opts)
  opts = opts or {}
  if opts.freq then FREQ = opts.freq end
  if opts.proto then PROTO = opts.proto end
  radioName = findRadio()
  if radioName and hasMethod(radioName, "setFrequency") then
    pcall(peripheral.call, radioName, "setFrequency", FREQ)
  end
  openModems()
  return { radio = radioName ~= nil, rednet = #modemNames > 0, name = radioName }
end

function comms.listenAs(name) names[name] = true end

function comms.up() return radioName ~= nil or #modemNames > 0 end

function comms.transports()
  local t = {}
  if radioName then t[#t + 1] = "radio" end
  if #modemNames > 0 then t[#t + 1] = "rednet" end
  return t
end

function comms.send(to, body, proto)
  proto = proto or PROTO
  local env = { __c = true, id = newId(), from = me, to = to, proto = proto, body = body }
  if radioName then
    pcall(peripheral.call, radioName, "broadcast", textutils.serialise(env))
  end
  if #modemNames > 0 then
    rednet.broadcast(env, proto)
  end
end

local function forMe(to) return to == me or to == "all" or names[to] end

function comms.receive(proto, timeout)
  proto = proto or PROTO
  local timer = timeout and os.startTimer(timeout) or nil
  while true do
    local ev = { os.pullEvent() }
    local kind = ev[1]
    prune()   -- self-throttled; bounds `seen` even on the store's no-timeout receive path
    if kind == "timer" and timer and ev[2] == timer then return nil end
    local env, dist
    if kind == "rednet_message" then
      local msg, p = ev[3], ev[4]
      if p == proto and type(msg) == "table" and msg.__c then env = msg end
    elseif kind == "radio_message" then
      local raw, d = ev[3], ev[4]
      if type(raw) == "string" then
        local ok, dec = pcall(textutils.unserialise, raw)
        if ok and type(dec) == "table" and dec.__c then env, dist = dec, d end
      end
    end
    if env and env.proto == proto and env.from ~= me and forMe(env.to) and not seen[env.id] then
      seen[env.id] = os.clock()
      return { from = env.from, to = env.to, body = env.body, dist = dist }
    end
  end
end

return comms
