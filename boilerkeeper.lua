-- boilerkeeper.lua  --  keeps the blaze-burner charcoal buffer topped from the store pool.
-- runs on a stationary computer wired to the store network (to read the buffer barrel) with a
-- wireless modem / radio antenna (to ask the store for charcoal). no store changes: it just
-- sends the existing `give` command. the buffer barrel MUST be marked `fuel` on the store so
-- the pool never vacuums the delivered charcoal back.

local comms = require("comms")

----------------------------------------------------------------- config
local BUFFER       = "minecraft:barrel_26"   -- charcoal buffer the feed belt pulls from
local CHARCOAL_ID  = "minecraft:charcoal"
local FLOOR        = 128     -- never want fewer than this (2 stacks)
local TRIGGER      = 192     -- top up once the buffer dips below this (margin above FLOOR)
local TARGET       = 384     -- refill toward this many
local CHECK_EVERY  = 10      -- seconds between buffer checks
local REQ_COOLDOWN = 15      -- min seconds between store requests

local STORE_NAME     = "store"
local STORE_PROTOCOL = "store"
local GPS_PROTO      = "gps"   -- stations reboot broadcast rides this proto, so it can't crowd turtle check-ins
local RADIO_FREQ     = 1000

----------------------------------------------------------------- helpers
local function request(cmd)
  comms.send(STORE_NAME, cmd, STORE_PROTOCOL)
  local m = comms.receive(STORE_PROTOCOL, 1.5)
  return m and m.body
end

local lastAlert = 0
local function alert(msg)
  local now = os.clock()
  if now - lastAlert < 60 then return end       -- at most once a minute
  lastAlert = now
  print(msg)
  if comms.up() then
    comms.send(STORE_NAME, {
      type = "alert", id = os.getComputerID(), label = os.getComputerLabel() or "boiler",
      msg = msg, phase = "keeper",
    }, STORE_PROTOCOL)
  end
end

local function charcoalCount()
  if not peripheral.isPresent(BUFFER) then return nil end
  local n = 0
  for _, it in pairs(peripheral.call(BUFFER, "list") or {}) do
    if it.name == CHARCOAL_ID then n = n + it.count end
  end
  return n
end

----------------------------------------------------------------- main
local function main()
  comms.open({ freq = RADIO_FREQ, proto = STORE_PROTOCOL })
  if not comms.up() then print("no radio/modem found; cannot reach the store"); return end
  print(("boilerkeeper online: %s  floor %d  trigger %d  target %d")
    :format(BUFFER, FLOOR, TRIGGER, TARGET))

  local lastReq = 0
  while true do
    local have = charcoalCount()
    if not have then
      alert("buffer " .. BUFFER .. " not found on the network")
    elseif have < TRIGGER and (os.clock() - lastReq) >= REQ_COOLDOWN then
      lastReq = os.clock()
      local reply = request(("give %s %s %d"):format(BUFFER, CHARCOAL_ID, TARGET - have))
      sleep(0.3)                                  -- let the wired transfer settle
      local after = charcoalCount() or have
      print(("%d -> %d  (%s)"):format(have, after, tostring(reply)))
      if after < FLOOR then alert("charcoal below floor; store pool may be out of charcoal") end
    end
    -- idle until the next check, but reboot promptly on a stations reboot broadcast
    local deadline = os.clock() + CHECK_EVERY
    while true do
      local left = deadline - os.clock()
      if left <= 0 then break end
      local m = comms.receive(GPS_PROTO, left)
      if m and type(m.body) == "table" and m.body.type == "reboot" then os.reboot() end
    end
  end
end

main()
