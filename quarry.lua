-- chunk quarry, dead reckoning, built perimeter staircase, lava/water-safe
-- chest keeps ONLY ores + andesite; all other blocks are voided.
-- place turtle on the top corner of the 16x16, facing along the +X edge.
-- fuel chest directly ABOVE the turtle, output chest directly BEHIND it.
-- run: quarry        (start / resume)
--      quarry reset  (wipe saved state, start fresh)

local WIDTH       = 16
local LENGTH      = 16
local FUEL_TARGET = 2000
local FUEL_MARGIN = 96
local BUILD_KEEP  = 320          -- reserve held back for stairs + liquid plugging
local STATE_FILE  = "quarry.state"

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

-- whole namespaces to keep (e.g. all Create-mod items, incl. create:raw_zinc)
local KEEP_NAMESPACES = {
  "create:",
}

local BUILD_BLOCKS = {
  ["minecraft:cobblestone"]      = true,
  ["minecraft:cobbled_deepslate"]= true,
}

local DIR = { [0]={x=1,z=0}, [1]={x=0,z=1}, [2]={x=-1,z=0}, [3]={x=0,z=-1} }

local args = {...}
local state

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
  local f = fs.open(STATE_FILE, "w")
  f.write(textutils.serialize(state))
  f.close()
end

local function load()
  if not fs.exists(STATE_FILE) then return false end
  local f = fs.open(STATE_FILE, "r")
  state = textutils.unserialize(f.readAll())
  f.close()
  return state ~= nil
end

local function fresh()
  return {
    pos = {x=0, y=0, z=0},
    heading = 0,
    phase = "mine",
    xdir = nil, zdir = nil,
    bottomY = nil,
    resume = nil,
    returnPhase = nil,
  }
end

local function selectBuild()
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d and BUILD_BLOCKS[d.name] then turtle.select(s); return true end
  end
  return false
end

-- make the target cell safe to enter, sealing liquid once (never looping for air).
-- returns: "go" enter it, "wait" unsealed lava, "stop" unbreakable (bedrock)
local function prepare(detect, dig, inspect, place)
  if detect() then
    if not dig() then return "stop" end
    if detect() then return "go" end          -- gravel refilled; caller retries
  end
  local ok, data = inspect()
  if not ok or not isLiquid(data) then return "go" end
  if selectBuild() then
    place(); dig()
    return "go"
  end
  if data.name == "minecraft:lava" then return "wait" end
  return "go"                                 -- water, no block: enter unsealed
end

local function forward()
  while true do
    local s = prepare(turtle.detect, turtle.dig, turtle.inspect, turtle.place)
    if s == "go" then
      if turtle.forward() then break end
      if turtle.getFuelLevel() == 0 then print("out of fuel mid-move"); sleep(3)
      else turtle.attack(); sleep(0.3) end
    elseif s == "wait" then
      print("lava ahead, drop me a block"); sleep(3)
    else
      return false                    -- unbreakable ahead (bedrock)
    end
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
      if turtle.getFuelLevel() == 0 then print("out of fuel mid-move"); sleep(3)
      else turtle.attackUp(); sleep(0.3) end
    elseif s == "wait" then
      print("lava above, drop me a block"); sleep(3)
    else
      return false
    end
  end
  state.pos.y = state.pos.y + 1; save(); return true
end

local function down()
  while true do
    local s = prepare(turtle.detectDown, turtle.digDown, turtle.inspectDown, turtle.placeDown)
    if s == "stop" then return false end
    if s == "go" then
      if turtle.down() then state.pos.y = state.pos.y - 1; save(); return true end
      if turtle.getFuelLevel() == 0 then print("out of fuel mid-move"); sleep(3)
      else turtle.attackDown(); sleep(0.3) end
    else
      print("lava below, drop me a block"); sleep(3)
    end
  end
end

local function turnRight()
  turtle.turnRight(); state.heading = (state.heading + 1) % 4; save()
end

local function turnTo(h)
  while state.heading ~= h do turnRight() end
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

local function ascendTo0()
  while state.pos.y < 0 do up() end
end

local function moveX(tx)
  if state.pos.x ~= tx then turnTo(state.pos.x < tx and 0 or 2) end
  while state.pos.x ~= tx do forward() end
end

local function moveZ(tz)
  if state.pos.z ~= tz then turnTo(state.pos.z < tz and 1 or 3) end
  while state.pos.z ~= tz do forward() end
end

local function descendTo(ty)
  while state.pos.y > ty do
    if not down() then break end
  end
end

local function travelTo(tx, ty, tz)
  ascendTo0()
  moveX(tx)
  moveZ(tz)
  descendTo(ty)
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
  while turtle.getFuelLevel() < FUEL_TARGET do
    turtle.select(1)
    if turtle.suckUp(64) then
      for s = 1, 16 do turtle.select(s); turtle.refuel() end
      turtle.select(1)
    else
      print("fuel chest empty, waiting"); sleep(5)
    end
  end
end

local function requestService(returnPhase)
  state.resume = {x=state.pos.x, y=state.pos.y, z=state.pos.z, h=state.heading}
  state.returnPhase = returnPhase
  state.phase = "service"
  save()
end

local function beginLayer()
  state.xdir = (state.pos.x == 0) and 1 or -1
  state.zdir = (state.pos.z == 0) and 1 or -1
  save()
end

local function clearLayer()
  while true do
    if turtle.getItemCount(14) > 0 then voidJunk() end
    if needService() then requestService("mine"); return "service" end
    local farX = (state.xdir == 1) and (WIDTH - 1) or 0
    if state.pos.x ~= farX then
      turnTo(state.xdir == 1 and 0 or 2)
      if not forward() then return "bedrock" end
    else
      local farZ = (state.zdir == 1) and (LENGTH - 1) or 0
      if state.pos.z == farZ then
        return "layerdone"
      else
        turnTo(state.zdir == 1 and 1 or 3)
        if not forward() then return "bedrock" end
        state.xdir = -state.xdir
        save()
      end
    end
  end
end

local function runMine()
  if state.xdir == nil then beginLayer() end
  while state.phase == "mine" do
    local r = clearLayer()
    if r == "service" then
      return
    elseif r == "bedrock" then
      state.bottomY = state.pos.y
      state.phase = "stairs"; save()
      return
    elseif r == "layerdone" then
      if down() then
        beginLayer()
      else
        state.bottomY = state.pos.y
        state.phase = "stairs"; save()
        return
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
  if not onPerimeter() then travelTo(0, 0, 0) end
  local floor = state.bottomY + 1
  while state.pos.y > floor do
    if needService() then requestService("stairs"); return end
    turnTo(stairHeading())
    placeStep()
    forward()
    if state.pos.y > floor then down() end
  end
  state.phase = "done"; save()
end

local function main()
  if args[1] == "reset" and fs.exists(STATE_FILE) then fs.delete(STATE_FILE) end

  if not load() then
    state = fresh(); save()
    refuelFromChest()
  end

  print("phase: " .. state.phase)
  while state.phase ~= "done" do
    if state.phase == "mine" then
      runMine()
    elseif state.phase == "service" then
      travelTo(0, 0, 0)
      dumpInventory()
      refuelFromChest()
      travelTo(state.resume.x, state.resume.y, state.resume.z)
      turnTo(state.resume.h or 0)
      state.phase = state.returnPhase or "mine"
      state.resume = nil; save()
    elseif state.phase == "stairs" then
      runStairs()
    end
  end
  print("quarry complete")
end

main()
