-- chunk quarry, dead reckoning, perimeter staircase, lava/water-safe
-- DIRECTIONAL: asks at startup whether to mine top->down or bottom->up.
--   down: clears top to bedrock, then builds the staircase (original behaviour)
--   up:   digs a corner shaft to bedrock first, then clears upward, then stairs
-- RESUME: over already-mined ground, full-clears until SKIP_TRIGGER all-air layers, then
--   fast-traverses (probing inward corner cells) to the first unmined layer. works up & down.
-- place turtle on the TOP corner of the 16x16; it digs 16 along its facing and 16 to its
-- right. (Heading is no longer assumed: GPS calibration MEASURES the world heading of that
-- facing on first boot, so face whichever edge orients the pit and the map still reads true.)
-- fuel chest directly ABOVE the turtle, output chest directly BEHIND it (same for both).
-- comms: turtle carries a mini radio antenna (pickaxe on the other side); talks to the store
--   via comms.lua over the radio tower. needs comms.lua + gps2.lua present on the turtle.
-- GPS: first boot does a 2-fix heading survey at the dock, saving that spot as HOME (world
--   origin + absolute heading). GPS X/Z is authoritative -- the turtle snaps its position to a
--   fix at safe points and on restart, so a reboot or shove can't lose it; dead reckoning only
--   bridges between fixes. Telemetry reports true world (F3) coords + heading. World Y rides
--   dead reckoning (Y PENDING until Tower Delta #5 is built -- set TRUST_GPS_Y then). No towers
--   / failed survey -> falls back to legacy local coords.
-- run: quarry2        (start / resume; asks the two chest names on first boot, saved to quarry2.cfg)
--      quarry2 reset  (wipe saved state AND chest config, start fresh)

local comms = require("comms")
local gps2  = require("gps2")

local WIDTH       = 16
local LENGTH      = 16
local FUEL_TARGET = 2000
local FUEL_MARGIN = 96
local BUILD_KEEP  = 384         -- cobble kept for stairs (~perimeter) + top cap (WIDTH*LENGTH)
local SKIP_TRIGGER = 2          -- consecutive all-air layers before fast-traversing mined ground
local STATE_FILE  = "quarry2.state"
local CFG_FILE    = "quarry2.cfg"   -- chest names, entered on first boot

-- store link (optional): turtle gets a mini radio antenna; its two chests are on the
-- store's WIRED network. their wired names are asked on FIRST BOOT and saved to
-- quarry2.cfg (blank answer = standalone, no store). re-enter with 'quarry2 reset'.
local STORE_PROTOCOL = "store"
local RADIO_FREQ     = 1000     -- must match the store's RADIO_FREQ
local TELEM_INTERVAL = 5        -- seconds between telemetry pings while working
local DEPOSIT_CHEST  = ""       -- chest BEHIND the turtle (marked input); set on first boot
local FUEL_CHEST     = ""       -- chest ABOVE the turtle (marked fuel);  set on first boot

-- GPS world-coord upgrade (PARTIAL: X/Z authoritative, Y PENDING). Calibration at the dock
-- saves a world origin (= HOME, the return point) + measured absolute heading. GPS X/Z is the
-- source of truth: at safe points the turtle SNAPS its grid position to the fix (fixes "lost on
-- restart" -- a reboot or shove can no longer desync it), with dead reckoning the fast
-- integrator between fixes. Safe because fixes are deterministic (zero jitter) and the
-- systematic bias cancels in the local snap. Vertical (Y) geometry is too weak on the current
-- 4-tower set (~6m off) so world Y rides dead reckoning (exact in a shaft); flip TRUST_GPS_Y
-- once Tower Delta (#5) is up and gpsrange confirms Y (flipping it also needs resync to snap
-- state.pos.y; today it snaps X/Z only). Calibration MEASURES absolute heading, dropping the old
-- "place facing +X" contract; no towers / failed survey falls back to legacy local behavior.
local TRUST_GPS_Y        = false  -- becomes true when Tower Delta lands + vertical is verified
local RESYNC_INTERVAL    = 30     -- seconds between GPS snaps at safe points (locate ~2s each)
local DISPLACE_THRESHOLD = 5      -- snap gap (blocks) above this also fires a "displaced" alert

local KEEP = {
  ["minecraft:andesite"]      = true,
  ["minecraft:coal"]          = true,
  ["minecraft:raw_iron"]      = true,
  ["minecraft:raw_copper"]    = true,
  ["minecraft:raw_gold"]      = true,
  ["minecraft:redstone"]      = true,
  ["minecraft:lapis_lazuli"]  = true,
  ["minecraft:diamond"]       = true,
  ["minecraft:emerald"]       = true,
  ["minecraft:quartz"]        = true,
  ["minecraft:ancient_debris"]= true,
}

local KEEP_NAMESPACES = { "create:" }

local BUILD_BLOCKS = {
  ["minecraft:cobblestone"]      = true,
  ["minecraft:cobbled_deepslate"]= true,
}

local DIR = { [0]={x=1,z=0}, [1]={x=0,z=1}, [2]={x=-1,z=0}, [3]={x=0,z=-1} }

local args = {...}
local state
local layerHadBlocks = false           -- per-layer: set when a primary dig hits real material
local lastResync, lastGpsOk = 0, nil   -- GPS re-sync throttle + last-fix-ok flag (for telem)

local function isKeeper(name)
  if KEEP[name] or name:find("ore", 1, true) then return true end
  for _, ns in ipairs(KEEP_NAMESPACES) do
    if name:find(ns, 1, true) == 1 then return true end
  end
  return false
end

local function isLiquid(data)
  return data and (data.name == "minecraft:lava" or data.name == "minecraft:water")
end

local function save()
  local f = fs.open(STATE_FILE, "w"); f.write(textutils.serialize(state)); f.close()
end

-- a queued "reboot" from the store is honored wherever we read a store reply. replies are
-- only read between completed moves, and every move persists state, so a reboot resumes
-- from a fully consistent saved position (and picks up freshly pulled code on the way up).
-- guard save(): replies are also read during early announce(), before state exists.
local function rebootIfAsked(reply)
  if reply == "reboot" then if state then save() end; os.reboot() end
end

local function load()
  if not fs.exists(STATE_FILE) then return false end
  local f = fs.open(STATE_FILE, "r"); state = textutils.unserialize(f.readAll()); f.close()
  return state ~= nil
end

local function fresh()
  return {
    pos = {x=0, y=0, z=0},
    heading = 0,
    dir = nil,                 -- "down" | "up"
    phase = "mine",
    xdir = nil, zdir = nil,
    bottomY = nil,
    resume = nil,
    returnPhase = nil,
    airStreak = 0,             -- consecutive all-air layers cleared (resume skip trigger)
    skipping = false,          -- mid fast-traverse over mined ground
  }
end

local function selectBuild()
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and BUILD_BLOCKS[d.name] then turtle.select(s); return true end
  end
  return false
end

local function isProtected(name)
  return name:find("chest", 1, true) ~= nil
      or name:find("barrel", 1, true) ~= nil
      or name:find("shulker_box", 1, true) ~= nil
end

local alertAt = {}
local function alert(kind, msg)
  local now = os.clock()
  if alertAt[kind] and now - alertAt[kind] < 30 then return end
  alertAt[kind] = now
  if not comms.up() then return end
  comms.send("store", {
    type = "alert", id = os.getComputerID(), label = os.getComputerLabel(),
    msg = msg or kind, phase = state and state.phase,
  }, STORE_PROTOCOL)
end

local function prepare(detect, dig, inspect, place)
  if detect() then
    local ok, d = inspect()
    if ok and d and d.name then
      lastBlock = d.name
      if isProtected(d.name) then return "protected" end
    end
    if not dig() then return "stop" end
    layerHadBlocks = true               -- real material on this layer (not the liquid-cap dig below)
    if detect() then return "go" end
  end
  local ok, data = inspect()
  if not ok or not isLiquid(data) then return "go" end
  if selectBuild() then place(); dig(); return "go" end
  if data.name == "minecraft:lava" then return "wait" end
  return "go"
end

local function forward()
  while true do
    local s = prepare(turtle.detect, turtle.dig, turtle.inspect, turtle.place)
    if s == "go" then
      if turtle.forward() then break end
      if turtle.getFuelLevel() == 0 then alert("out of fuel"); print("out of fuel mid-move"); sleep(3)
      else turtle.attack(); sleep(0.3) end
    elseif s == "wait" then alert("lava blocked"); print("lava ahead, drop me a block"); sleep(3)
    elseif s == "protected" then return false, "protected"
    else return false, "bedrock" end
  end
  local d = DIR[state.heading]
  state.pos.x = state.pos.x + d.x
  state.pos.z = state.pos.z + d.z
  save()
  return true
end

local function up()
  while true do
    local s = prepare(turtle.detectUp, turtle.digUp, turtle.inspectUp, turtle.placeUp)
    if s == "go" then
      if turtle.up() then break end
      if turtle.getFuelLevel() == 0 then alert("out of fuel"); print("out of fuel mid-move"); sleep(3)
      else turtle.attackUp(); sleep(0.3) end
    elseif s == "wait" then alert("lava blocked"); print("lava above, drop me a block"); sleep(3)
    else return false end
  end
  state.pos.y = state.pos.y + 1; save(); return true
end

local function down()
  while true do
    local s = prepare(turtle.detectDown, turtle.digDown, turtle.inspectDown, turtle.placeDown)
    if s == "stop" or s == "protected" then return false end
    if s == "go" then
      if turtle.down() then state.pos.y = state.pos.y - 1; save(); return true end
      if turtle.getFuelLevel() == 0 then alert("out of fuel"); print("out of fuel mid-move"); sleep(3)
      else turtle.attackDown(); sleep(0.3) end
    else alert("lava blocked"); print("lava below, drop me a block"); sleep(3) end
  end
end

local function turnRight()
  turtle.turnRight(); state.heading = (state.heading + 1) % 4; save()
end

local function turnTo(h)
  while state.heading ~= h do turnRight() end
end

-- local grid pos -> world coords, using the calibrated origin + worldHeading. Local +X
-- (local heading 0) points along world DIR[worldHeading]; local +Z along the next dir CW;
-- turnRight increments heading in both frames, so absolute heading = worldHeading + local
-- heading. World Y rides dead reckoning off origin.y (Y pending). Only valid when calibrated.
local function l2w(p)
  local o, wh = state.origin, state.worldHeading
  local fx = DIR[wh]                 -- world delta per +1 local x
  local fz = DIR[(wh + 1) % 4]       -- world delta per +1 local z
  return {
    x = o.x + p.x * fx.x + p.z * fz.x,
    y = o.y + p.y,
    z = o.z + p.x * fx.z + p.z * fz.z,
  }
end

local function absHeading()
  return (state.worldHeading + state.heading) % 4
end

-- world coords -> local grid cell (inverse of l2w): project the world offset from origin onto
-- the calibrated forward/right axes, round to the nearest block. X/Z only (Y is pending).
local function w2l(W)
  local o, wh = state.origin, state.worldHeading
  local fx = DIR[wh]
  local fz = DIR[(wh + 1) % 4]
  local dwx, dwz = W.x - o.x, W.z - o.z
  return {
    x = math.floor(dwx * fx.x + dwz * fx.z + 0.5),
    z = math.floor(dwx * fz.x + dwz * fz.z + 0.5),
  }
end

local function costHome()
  return math.abs(state.pos.x) + math.abs(state.pos.z) - state.pos.y
end

local function voidJunk()
  local kept = 0
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and not isKeeper(d.name) then
      if BUILD_BLOCKS[d.name] and kept < BUILD_KEEP then
        local take = math.min(d.count, BUILD_KEEP - kept)
        kept = kept + take
        if d.count > take then turtle.select(s); turtle.dropUp(d.count - take) end
      else
        turtle.select(s); turtle.dropUp()
      end
    end
  end
  turtle.select(1)
end

local function inventoryFull()
  for s = 1, 16 do
    if turtle.getItemCount(s) == 0 then return false end
  end
  return true
end

local function needService()
  if inventoryFull() then return true end
  local fuel = turtle.getFuelLevel()
  if fuel == "unlimited" then return false end
  return fuel < costHome() * 2 + FUEL_MARGIN
end

local function ascendTo(ty)
  while state.pos.y < ty do if not up() then break end end
end

local function descendTo(ty)
  while state.pos.y > ty do
    if not down() then break end
  end
end

local function moveX(tx)
  if state.pos.x ~= tx then turnTo(state.pos.x < tx and 0 or 2) end
  while state.pos.x ~= tx do if not forward() then break end end
end

local function moveZ(tz)
  if state.pos.z ~= tz then turnTo(state.pos.z < tz and 1 or 3) end
  while state.pos.z ~= tz do if not forward() then break end end
end

-- down-mode highway: the cleared top plane
local function travelTopPlane(tx, ty, tz)
  ascendTo(0); moveX(tx); moveZ(tz); descendTo(ty)
end

-- up-mode highway: drop to the cleared bottom plane, cross it, ride the corner shaft
local function travelHomeBU()
  descendTo(state.bottomY); moveX(0); moveZ(0); ascendTo(0)
end

local function travelBackBU(rx, ry, rz)
  descendTo(state.bottomY); moveX(rx); moveZ(rz); ascendTo(ry)
end

local function serviceHome(rp)
  if rp == "descend" then ascendTo(0)                       -- straight up the shaft
  elseif rp == "mine" and state.dir == "up" then travelHomeBU()
  else travelTopPlane(0, 0, 0) end                          -- mine-down, or stairs (box hollow)
end

local function serviceBack(rp, r)
  if rp == "descend" then descendTo(r.y)                    -- back down the shaft
  elseif rp == "mine" and state.dir == "up" then travelBackBU(r.x, r.y, r.z)
  else travelTopPlane(r.x, r.y, r.z) end
  turnTo(r.h or 0)
end

local lastBlock = "-"

local function net()
  return comms.up()
end

local function storeCmd(line)
  if not comms.up() then return nil end
  comms.send("store", line, STORE_PROTOCOL)
  local r = comms.receive(STORE_PROTOCOL, 5)
  local body = r and r.body
  rebootIfAsked(body)
  return body
end

local function announce()
  if DEPOSIT_CHEST ~= "" then storeCmd("mark " .. DEPOSIT_CHEST .. " input") end
  if FUEL_CHEST   ~= "" then storeCmd("mark " .. FUEL_CHEST   .. " fuel")  end
end

local function dumpInventory()
  turnTo(2)
  for s = 1, 16 do
    turtle.select(s)
    local d = turtle.getItemDetail(s)
    if d and isKeeper(d.name) then turtle.drop() end
  end
  turtle.select(1)
end

local function refuelFromChest()
  if turtle.getFuelLevel() == "unlimited" then return end
  local asked = false
  while turtle.getFuelLevel() < FUEL_TARGET do
    turtle.select(1)
    if turtle.suckUp(64) then
      for s = 1, 16 do turtle.select(s); turtle.refuel() end
      turtle.select(1)
      asked = false
    elseif comms.up() and FUEL_CHEST ~= "" and not asked then
      -- chest empty: have the store push fuel into it, then try again
      local reply = storeCmd("fuel " .. FUEL_CHEST .. " 64")
      asked = true
      if not reply then print("store unreachable, waiting"); sleep(5); asked = false end
    else
      print("fuel chest empty, waiting"); sleep(5); asked = false
    end
  end
end

-- boot calibration: at the dock (fresh start only, local origin = 0,0,0) survey the world
-- origin + absolute heading via two GPS fixes one block apart. Uses dig-capable move callbacks
-- so a block in front (the quarry top corner) is no obstacle; ends physically back on the dock
-- with state.pos untouched. On any fix/move failure, stays in legacy local mode (gps off).
local DIRNAME = { [0] = "+X", [1] = "+Z", [2] = "-X", [3] = "-Z" }

local calFwded = false                    -- true while the survey has us one block off the dock
local function calFwd()
  local tries = 0
  while turtle.detect() do
    if not turtle.dig() then
      tries = tries + 1
      if tries > 20 then return false end
      sleep(0.3)
    end
  end
  if turtle.forward() then calFwded = true; return true end
  return false
end

local function calBack()
  for _ = 1, 5 do if turtle.back() then calFwded = false; return true end; sleep(0.3) end
  return false
end

local function calibrateGps()
  if not comms.up() then print("gps: no antenna, legacy local mode"); return end
  print("gps: calibrating heading...")    -- survey runs along local head 0 (=+X) set by fresh()
  calFwded = false
  local origin, heading = gps2.calibrate(calFwd, calBack)
  if calFwded then                         -- moved out but never got back: we're off the dock
    alert("gps offdock", "gps calibration left me off the dock - check me")
    for _ = 1, 10 do if calBack() then break end; sleep(0.5) end
  end
  if not origin then
    print("gps: calibration failed (" .. tostring(heading) .. "); legacy local mode")
    state.gps = false; save(); return
  end
  -- round to integer block coords (the fractional part is GPS noise; within the ~1m budget)
  state.origin = { x = math.floor(origin.x + 0.5), y = math.floor(origin.y + 0.5),
                   z = math.floor(origin.z + 0.5) }
  state.worldHeading = heading
  state.gps = true
  save()
  print(("gps: origin %d,%d,%d facing %s%s"):format(
    state.origin.x, state.origin.y, state.origin.z, DIRNAME[heading],
    TRUST_GPS_Y and "" or " (Y pending)"))
end

local EST_DEPTH = 72   -- rough surface-to-bedrock, for % estimate only

local function pct()
  if state.phase == "done" then return 100 end
  local p = (state.phase == "service" or state.phase == "recalled")
            and (state.returnPhase or "mine") or state.phase
  if p == "cap" or p == "home" then return 99 end
  local y = (state.resume and state.resume.y) or state.pos.y
  local depth = math.abs(y)
  local bottom = math.abs(state.bottomY or -EST_DEPTH)
  if state.dir == "up" then
    if p == "descend" then return math.min(35, math.floor(35 * depth / EST_DEPTH)) end
    if p == "mine"    then return 35 + math.min(50, math.floor(50 * (bottom - depth) / math.max(1, bottom))) end
    if p == "stairs"  then return 85 + math.floor(15 * (1 - depth / math.max(1, bottom))) end
  else
    if p == "mine"    then return state.bottomY and 85 or math.min(85, math.floor(85 * depth / EST_DEPTH)) end
    if p == "stairs"  then return 85 + math.floor(15 * (1 - depth / math.max(1, bottom))) end
  end
  return 0
end

local function checkin()
  if not comms.up() then return nil end
  local fl = turtle.getFuelLevel()
  -- world coords when calibrated, else legacy local pos (gps=nil tells the store which)
  local pos, head, gpsFlag = state.pos, nil, nil
  if state.gps and state.origin then pos = l2w(state.pos); head = absHeading(); gpsFlag = lastGpsOk end
  comms.send("store", {
    type = "telem", kind = "quarry", id = os.getComputerID(), label = os.getComputerLabel(),
    phase = state.phase, dir = state.dir, pct = pct(),
    fuel = (fl == "unlimited") and FUEL_TARGET or fl, fuelMax = FUEL_TARGET,
    pos = { x = pos.x, y = pos.y, z = pos.z }, head = head, gps = gpsFlag,
    last = lastBlock, halted = (state.phase == "recalled"),
  }, STORE_PROTOCOL)
  local r = comms.receive(STORE_PROTOCOL, 1.5)
  rebootIfAsked(r and r.body)
  if r and type(r.body) == "string" and r.body ~= "ok" then return r.body end
  return nil
end

local function requestRecall(returnPhase)
  state.resume = { x = state.pos.x, y = state.pos.y, z = state.pos.z, h = state.heading }
  state.returnPhase = returnPhase
  state.phase = "recalled"
  save()
end

-- opportunistic GPS snap: at a safe point, take a fix and SNAP the local grid X/Z to it -- GPS
-- is authoritative, dead reckoning only bridges between fixes. Normally a no-op (gap 0: GPS
-- agrees with DR), it self-corrects a turtle that rebooted or got shoved. A large gap is also a
-- physical displacement, so it pings. Y is pending (snapped axes are X/Z only). force ignores
-- the cadence gate (used on restart and at the surface dock, where the fix is most reliable).
local function resync(force)
  if not (state.gps and state.origin) or not comms.up() then return end
  if not force and os.clock() - lastResync < RESYNC_INTERVAL then return end
  lastResync = os.clock()
  local fix = gps2.tryFix(0)
  if not fix then lastGpsOk = false; return end
  lastGpsOk = true
  local l = w2l(fix)
  local gap = math.max(math.abs(l.x - state.pos.x), math.abs(l.z - state.pos.z))
  if gap == 0 then return end
  print(("gps: snap X/Z %d,%d -> %d,%d"):format(state.pos.x, state.pos.z, l.x, l.z))
  if gap > DISPLACE_THRESHOLD then alert("displaced", ("displaced %d, re-homed"):format(gap)) end
  state.pos.x, state.pos.z = l.x, l.z       -- GPS owns X/Z; dead reckoning keeps Y (pending)
  save()
end

local lastTelem = 0
local function checkpoint(returnPhase)
  if os.clock() - lastTelem < TELEM_INTERVAL then return false end
  lastTelem = os.clock()
  resync(false)
  if checkin() == "rtb" then requestRecall(returnPhase); return true end
  return false
end

local function requestService(returnPhase)
  state.resume = {x=state.pos.x, y=state.pos.y, z=state.pos.z, h=state.heading}
  state.returnPhase = returnPhase
  state.phase = "service"
  save()
end

local function beginLayer()
  layerHadBlocks = false
  state.xdir = (state.pos.x == 0) and 1 or -1
  state.zdir = (state.pos.z == 0) and 1 or -1
  save()
end

-- is the current layer unmined? sample only the corner's two INWARD neighbors -- the outward
-- cells are the pit's natural walls and would false-positive. no moves; any detect -> unmined.
local function probeUnmined()
  turnTo(state.xdir == 1 and 0 or 2)
  if turtle.detect() then return true end
  turnTo(state.zdir == 1 and 1 or 3)
  return turtle.detect()
end

local function stepToNextRow()
  -- "ok" moved to next row | "done" no rows left | "bedrock"/"protected" blocked
  local farZ = (state.zdir == 1) and (LENGTH - 1) or 0
  if state.pos.z == farZ then return "done" end
  turnTo(state.zdir == 1 and 1 or 3)
  local ok, why = forward()
  if not ok then return why end
  state.xdir = -state.xdir
  save()
  return "ok"
end

local function clearLayer()
  while true do
    if turtle.getItemCount(14) > 0 then voidJunk() end
    if needService() then requestService("mine"); return "service" end
    if checkpoint("mine") then return "recalled" end
    local farX = (state.xdir == 1) and (WIDTH - 1) or 0
    if state.pos.x ~= farX then
      turnTo(state.xdir == 1 and 0 or 2)
      local ok, why = forward()
      if not ok then
        if why ~= "protected" then return "bedrock" end
        local s = stepToNextRow()                 -- chest ahead: end this row, drop to the next
        if s ~= "ok" then return "layerdone" end
      end
    else
      local s = stepToNextRow()
      if s == "done" or s == "protected" then return "layerdone" end
      if s == "bedrock" then return "bedrock" end
    end
  end
end

-- fast-traverse already-mined layers: probe the current layer (inward corner cells), and while it
-- is air step one layer deeper and probe again (Y only, orthogonal to the X/Z GPS snap) until an
-- unmined layer is found. probe-before-move so the entry layer is never skipped unprobed. honors
-- clearLayer's safe points. skipping/airStreak persist (not cleared on bedrock/top/service/
-- recalled) so a reboot or service trip resumes the traverse; only a "found" exits it.
local function skipToUnmined()
  state.skipping = true; save()
  while true do
    if turtle.getItemCount(14) > 0 then voidJunk() end
    if needService() then requestService("mine"); return "service" end
    if checkpoint("mine") then return "recalled" end
    if probeUnmined() then
      state.skipping = false; state.airStreak = 0; save()
      return "found"
    end
    if state.dir == "up" then
      if state.pos.y >= 0 then return "top" end
      if not up() then return "top" end
    else
      if not down() then state.bottomY = state.pos.y; return "bedrock" end
    end
    beginLayer(); save()
  end
end

local function runDescend()
  while state.phase == "descend" do
    if turtle.getItemCount(14) > 0 then voidJunk() end
    if checkpoint("descend") then return end
    if needService() then requestService("descend"); return end
    if not down() then
      state.bottomY = state.pos.y
      state.phase = "mine"
      beginLayer()
      save()
    end
  end
end

local function runMine()
  if state.xdir == nil then beginLayer() end
  while state.phase == "mine" do
    if state.skipping or state.airStreak >= SKIP_TRIGGER then
      local sr = skipToUnmined()
      if sr == "service" or sr == "recalled" then return end
      if sr == "bedrock" or sr == "top" then state.phase = "stairs"; save(); return end
      -- "found": fall through and clear this unmined layer now
    end
    local r = clearLayer()
    if r == "service" then
      return
    elseif r == "bedrock" then
      if state.dir == "up" then
        if state.pos.y < 0 and up() then beginLayer()
        else state.phase = "stairs"; save(); return end
      else
        state.bottomY = state.pos.y; state.phase = "stairs"; save(); return
      end
    elseif r == "layerdone" then
      if layerHadBlocks then state.airStreak = 0 else state.airStreak = state.airStreak + 1 end
      save()
      if checkpoint("mine") then return end
      if state.dir == "up" then
        if state.pos.y >= 0 then state.phase = "stairs"; save(); return end
        if up() then beginLayer() else state.phase = "stairs"; save(); return end
      else
        if down() then beginLayer()
        else state.bottomY = state.pos.y; state.phase = "stairs"; save(); return end
      end
    end
  end
end

local function placeStep()
  while not selectBuild() do
    print("out of build blocks, drop some in me"); sleep(5)
  end
  turtle.placeDown()
end

local function stairHeading()
  local x, z = state.pos.x, state.pos.z
  if z == 0        and x < WIDTH - 1  then return 0 end
  if x == WIDTH-1  and z < LENGTH - 1 then return 1 end
  if z == LENGTH-1 and x > 0          then return 2 end
  if x == 0        and z > 0          then return 3 end
  return 0
end

local function onPerimeter()
  return state.pos.x == 0 or state.pos.x == WIDTH - 1
      or state.pos.z == 0 or state.pos.z == LENGTH - 1
end

local function runStairs()
  if not onPerimeter() then travelTopPlane(0, 0, 0) end
  local floor = state.bottomY + 1
  while state.pos.y > floor do
    if checkpoint("stairs") then return end
    if needService() then requestService("stairs"); return end
    turnTo(stairHeading())
    placeStep()
    forward()
    if state.pos.y > floor then down() end
  end
  state.phase = "cap"; save()
end

local capMisses = 0

-- climb to the y=0 plane through the mined interior, never the perimeter staircase
local function climbToTop()
  if state.pos.x < 1 then moveX(1) elseif state.pos.x > WIDTH - 2 then moveX(WIDTH - 2) end
  if state.pos.z < 1 then moveZ(1) elseif state.pos.z > LENGTH - 2 then moveZ(LENGTH - 2) end
  ascendTo(0)
end

local function capCell()
  if not turtle.detectDown() then
    if selectBuild() then turtle.placeDown() else capMisses = capMisses + 1 end
  end
end

local function runCap()
  if not state.capStarted then
    climbToTop()
    travelTopPlane(0, 0, 0)
    state.xdir, state.zdir, state.capStarted = 1, 1, true
    save()
  else
    ascendTo(0)
  end
  capCell()
  while true do
    if needService() then requestService("cap"); return end
    if checkpoint("cap") then return end
    local farX = (state.xdir == 1) and (WIDTH - 1) or 0
    if state.pos.x ~= farX then
      turnTo(state.xdir == 1 and 0 or 2)
      if forward() then capCell()
      elseif stepToNextRow() == "ok" then capCell()
      else break end
    else
      if stepToNextRow() == "ok" then capCell() else break end
    end
  end
  if capMisses > 0 then print("cap: " .. capMisses .. " cells unfilled (out of blocks)") end
  state.phase = "home"; save()
end

local function runHome()
  travelTopPlane(0, 0, 0)
  dumpInventory()
  state.phase = "done"; save()
end

local function askDirection()
  while true do
    write("Mine direction - (d)own or (u)p? ")
    local a = (read() or ""):lower()
    if a == "d" or a == "down" then return "down" end
    if a == "u" or a == "up" then return "up" end
    print("type d or u")
  end
end

local function askChest(label)
  write(label .. ": ")
  local s = read() or ""
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function loadOrAskChests()
  if fs.exists(CFG_FILE) then
    local f = fs.open(CFG_FILE, "r"); local t = textutils.unserialize(f.readAll()); f.close()
    if type(t) == "table" then
      DEPOSIT_CHEST = t.deposit or ""
      FUEL_CHEST    = t.fuel or ""
      return
    end
  end
  print("first boot - name the home chests (run 'invs' on the store for wired names).")
  print("blank = run standalone with no store link.")
  DEPOSIT_CHEST = askChest("deposit chest (behind, marked input)")
  FUEL_CHEST    = askChest("fuel chest (above, marked fuel)")
  local f = fs.open(CFG_FILE, "w")
  f.write(textutils.serialize({ deposit = DEPOSIT_CHEST, fuel = FUEL_CHEST }))
  f.close()
  print("saved to " .. CFG_FILE .. "  (run 'quarry2 reset' to re-enter)")
end

local function main()
  if args[1] == "reset" then
    if fs.exists(STATE_FILE) then fs.delete(STATE_FILE) end
    if fs.exists(CFG_FILE) then fs.delete(CFG_FILE) end
  end

  loadOrAskChests()

  comms.open({ freq = RADIO_FREQ, proto = STORE_PROTOCOL })
  announce()

  if not load() then
    state = fresh()
    state.dir = askDirection()
    state.phase = (state.dir == "up") and "descend" or "mine"
    save()
    refuelFromChest()
    calibrateGps()                  -- fresh start only: a resume isn't at the dock so can't
                                    -- re-survey; a failed first survey needs 'quarry2 reset'
  else
    -- migrate state saved before the skip feature (else airStreak compares/adds vs nil)
    if state.airStreak == nil then state.airStreak = 0 end
    if state.skipping  == nil then state.skipping  = false end
  end

  print("dir: " .. state.dir .. "  phase: " .. state.phase)
  resync(true)                      -- recover X/Z from GPS after a restart (could have drifted/lost)
  while state.phase ~= "done" do
    if state.phase == "descend" then
      runDescend()
    elseif state.phase == "mine" then
      runMine()
    elseif state.phase == "service" then
      serviceHome(state.returnPhase)
      dumpInventory()
      refuelFromChest()
      resync(true)                  -- at the surface dock: most reliable fix
      if checkin() == "rtb" then
        state.phase = "recalled"; save()
      else
        serviceBack(state.returnPhase, state.resume)
        state.phase = state.returnPhase or "mine"
        state.resume = nil; save()
      end
    elseif state.phase == "recalled" then
      serviceHome(state.returnPhase)
      dumpInventory()
      resync(true)                  -- at the surface dock: most reliable fix
      print("recalled - holding at home until continue")
      while checkin() ~= "continue" do sleep(3) end
      refuelFromChest()
      serviceBack(state.returnPhase, state.resume)
      state.phase = state.returnPhase or "mine"
      state.resume = nil; save()
    elseif state.phase == "stairs" then
      runStairs()
    elseif state.phase == "cap" then
      runCap()
    elseif state.phase == "home" then
      runHome()
    end
  end
  checkin()
  print("quarry complete")
end

main()
