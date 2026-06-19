-- crafter: a stationary crafty turtle that fulfils the store's craft jobs. the store owns the
-- recipe DB and does all the planning (architecture B); this turtle is a thin executor. it
-- learns recipes by example and runs craftplans handed back as a telem reply.
--
-- BUILD (the turtle never moves; directions are fixed):
--   * a crafting table EQUIPPED on one side (turtle.equipLeft/equipRight) so turtle.craft works
--   * a mini radio antenna on the other side, + comms.lua present
--   * craftIn chest  IN FRONT  -- the store pushes raws here; the turtle sucks them (turtle.suck)
--   * craftOut chest BELOW     -- the turtle dropDowns finished goods + leftovers here
--   both chests on the store's WIRED-modem network. mark craftOut `input` (announce does this) so
--   the store vacuums it back into the pool; craftIn is left unmarked and the store keeps it out
--   of the pool by name (learned from this turtle's telem).
-- the 3x3 crafting grid is turtle slots 1-3 / 5-7 / 9-11; slots 4,8,12-16 are scratch + output.
-- v1 assumes a plan's raws + intermediates fit the turtle's 16 slots; on overflow it reports
-- craftdone{ok=false} and the store logs it.
--
-- run: crafter         start the executor (asks the two chest names on first boot -> crafter.cfg)
--      crafter learn   read the recipe arranged in the grid now, craft 1, upload it to the store
--      crafter reset   wipe the saved chest config

local comms  = require("comms")
local gps2   = require("gps2")
local beacon = require("beacon")
local sendLoc = beacon.sender(os.getComputerLabel() or ("crafter#" .. os.getComputerID()), "craft")
local craftPos = nil   -- world position; located once and cached (the crafter is stationary)

local STORE_PROTOCOL = "store"
local STORE_NAME     = "store"
local RADIO_FREQ     = 1000        -- must match the store's RADIO_FREQ
local TELEM_INTERVAL = 2           -- seconds between progress telemetry pings while crafting
local CFG_FILE       = "crafter.cfg"

-- store-side wired names of the two chests, asked on first boot. the turtle sucks/drops by
-- direction (front/down); these names only tell the store where to push raws and vacuum output.
local CRAFT_IN  = ""               -- chest in front; store pushes raws here (kept out of the pool)
local CRAFT_OUT = ""               -- chest below; finished goods land here (marked input)

-- turtle.craft reads the 3x3 crafting region = the TOP-LEFT of the 4-wide inventory, which spans the
-- whole top 3 rows (slots 1-12). a stray item anywhere in slots 1-12 (incl. the column-4 slots 4/8/12)
-- breaks the recipe match - a shapeless recipe counts every item in that region. so only the bottom row
-- (13-16) is safe for leftovers + output, and the whole region 1-12 is cleared before each craft.
local GRID  = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }   -- the 3x3 recipe cells
local STASH = { 13, 14, 15, 16 }                 -- bottom row: outside the region, holds leftovers + output

local args = { ... }

----------------------------------------------------------------- comms
-- a queued "reboot" from the store is honored wherever we read a reply, so `reboot fleet`
-- makes the crafter pick up freshly pulled code. nothing here moves, so there is no position
-- to save first.
local function rebootIfAsked(body)
  if body == "reboot" then os.reboot() end
end

local function request(cmd)
  comms.send(STORE_NAME, cmd, STORE_PROTOCOL)
  local m = comms.receive(STORE_PROTOCOL, 1.5)
  rebootIfAsked(m and m.body)
  return m and m.body
end

-- send telemetry; `phase` is what we're doing (the target item while crafting), `pct` the overall
-- progress, `wait` how long to listen for a reply (short while crafting, default at idle). the store
-- derives "time remaining" from the pct climbing over successive pings.
local function checkin(phase, pct, wait)
  if not comms.up() then return nil end
  comms.send(STORE_NAME, {
    type = "telem", kind = "craft", id = os.getComputerID(), label = os.getComputerLabel(),
    phase = phase or "idle", pct = pct or 0, halted = false,
    fuel = 1, fuelMax = 1,
    craftIn = CRAFT_IN,            -- so the store learns where to deliver raws
  }, STORE_PROTOCOL)
  if craftPos then sendLoc(os.clock(), craftPos) end   -- presence beacon -> fleet maps
  local m = comms.receive(STORE_PROTOCOL, wait or 1.5)
  local body = m and m.body
  rebootIfAsked(body)
  return body
end

local function announce()
  if CRAFT_OUT ~= "" then request("mark " .. CRAFT_OUT .. " input") end
end

----------------------------------------------------------------- inventory
local function shortId(id) return id and (id:match("[^:]+$") or id) or "?" end

local function countId(id)
  local n = 0
  for s = 1, 16 do local d = turtle.getItemDetail(s); if d and d.name == id then n = n + d.count end end
  return n
end

local function dumpAll()                              -- everything -> craftOut (below)
  for s = 1, 16 do
    if turtle.getItemCount(s) > 0 then turtle.select(s); turtle.dropDown() end
  end
  turtle.select(1)
end

-- empty the whole crafting region (slots 1-12) into the bottom-row stash, so the only items
-- turtle.craft will see are the ones we arrange into the grid for this step
local function clearArea()
  local ok = true
  for s = 1, 12 do
    if turtle.getItemCount(s) > 0 then
      turtle.select(s)
      for _, f in ipairs(STASH) do
        if turtle.getItemCount(s) == 0 then break end
        turtle.transferTo(f)
      end
      if turtle.getItemCount(s) > 0 then ok = false end
    end
  end
  turtle.select(1)
  return ok
end

-- gather up to `want` of `id` into grid cell `dst`, pulling from the bottom-row stash (the region
-- is cleared first, so every loose ingredient lives in the stash)
local function gather(id, dst, want)
  local have = 0
  local d = turtle.getItemDetail(dst)
  if d and d.name == id then have = turtle.getItemCount(dst) end
  for _, s in ipairs(STASH) do
    if have >= want then break end
    local sd = turtle.getItemDetail(s)
    if sd and sd.name == id then
      turtle.select(s)
      turtle.transferTo(dst, want - have)
      have = turtle.getItemCount(dst)
    end
  end
  return have
end

local function freeOutSlot(out)                       -- empty stash slot (or one already holding `out`)
  for _, f in ipairs(STASH) do
    local d = turtle.getItemDetail(f)
    if not d or d.name == out then return f end
  end
  return nil
end

local function dropAllToFront()                       -- return everything to craftIn (front; not pooled)
  for s = 1, 16 do
    if turtle.getItemCount(s) > 0 then turtle.select(s); turtle.drop() end
  end
  turtle.select(1)
end

----------------------------------------------------------------- craft
-- craft ONE application of `grid`. turtle.craft scans the WHOLE inventory and (for shapeless recipes)
-- demands it hold EXACTLY the recipe items - any extra item makes the match fail. so materials buffer
-- in craftIn (front; the store never vacuums it): suck them in, keep only this recipe's items, return
-- everything else to craftIn, craft, then return the output to craftIn too. returns ok, reason.
local function craftOne(grid)
  if not turtle.craft then return false, "no crafting table" end
  while turtle.suck() do end                          -- pull the whole material buffer from craftIn
  if not clearArea() then dropAllToFront(); return false, "inv full" end
  for slot, id in pairs(grid) do
    if gather(id, slot, 1) < 1 then dropAllToFront(); return false, "need " .. shortId(id) end
  end
  for s = 1, 16 do                                    -- everything that isn't an arranged cell -> craftIn
    if not grid[s] and turtle.getItemCount(s) > 0 then turtle.select(s); turtle.drop() end
  end
  local out                                           -- output to an empty bottom-row slot (now clear)
  for _, s in ipairs(STASH) do if turtle.getItemCount(s) == 0 then out = s; break end end
  turtle.select(out or 13)
  if not turtle.craft(1) then
    local g = {}
    for s = 1, 16 do local d = turtle.getItemDetail(s); if d then g[#g + 1] = s .. ":" .. shortId(d.name) end end
    print("craft rejected; inv " .. (#g > 0 and table.concat(g, " ") or "empty"))
    dropAllToFront()
    return false, "bad recipe (relearn)"
  end
  dropAllToFront()                                    -- output + remnants back to craftIn for the next craft
  return true
end

-- runs the plan; reports live progress to the store (phase = target item, pct = batches done out of
-- total) so the Overview/pocket can show the current craft + a derived time-remaining. returns ok, made, err
local function execute(steps)
  dumpAll()                                           -- clean the turtle (materials live in craftIn)
  local target = steps[#steps] and steps[#steps].out
  local total = 0
  for _, s in ipairs(steps) do total = total + s.batches end
  local done, lastPing = 0, 0
  local function ping(force)                          -- time-gated progress telem (drains the reply / honors reboot)
    if not comms.up() then return end
    if not force and os.clock() - lastPing < TELEM_INTERVAL then return end
    lastPing = os.clock()
    checkin(shortId(target), total > 0 and math.floor(done / total * 100) or 0, 0.2)
  end
  print(("crafting %s  (%d step%s)"):format(shortId(target), #steps, #steps == 1 and "" or "s"))
  ping(true)
  local err
  for i, step in ipairs(steps) do
    print(("  [%d/%d] %d x %s"):format(i, #steps, step.batches * step.yield, shortId(step.out)))
    for _ = 1, step.batches do
      local ok, why = craftOne(step.grid)
      if not ok then err = shortId(step.out) .. ": " .. (why or "failed"); break end
      done = done + 1
      ping(false)
    end
    if err then break end
  end
  while turtle.suck() do end                          -- collect the buffer from craftIn...
  local made = target and countId(target) or 0
  dumpAll()                                           -- ...and drop everything to craftOut -> pool
  if err then print("FAILED " .. err) else print("done: made " .. made .. " x " .. shortId(target)) end
  return not err, made, err
end

----------------------------------------------------------------- learn
local function learn()
  if not turtle.craft then print("no crafting table equipped (equipLeft/equipRight a crafting table)"); return end
  local grid = {}
  for _, s in ipairs(GRID) do
    local d = turtle.getItemDetail(s)
    if d then grid[s] = d.name end
  end
  if next(grid) == nil then print("grid empty - load slots 1-3,5-7,9-11, then run 'crafter learn'"); return end
  local out = freeOutSlot("")
  if not out then print("no free output slot - clear slots 4,8,12-16"); return end
  turtle.select(out)
  if not turtle.craft(1) then print("craft failed - is a crafting table equipped, and the grid valid?"); return end
  local d = turtle.getItemDetail(out)
  if not d then print("no result produced"); return end
  local outId, yield = d.name, d.count
  comms.send(STORE_NAME, { type = "recipe", out = outId, yield = yield, grid = grid }, STORE_PROTOCOL)
  local m = comms.receive(STORE_PROTOCOL, 3)
  dumpAll()                                           -- return the result + leftover ingredients to the pool
  print(("learned %s x%d (%s)"):format(outId, yield, (m and m.body == "ok") and "stored" or "no store ack"))
end

----------------------------------------------------------------- config (first boot)
local function askChest(label)
  write(label .. ": ")
  local s = read() or ""
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function loadOrAskCfg()
  if fs.exists(CFG_FILE) then
    local f = fs.open(CFG_FILE, "r"); local t = textutils.unserialize(f.readAll()); f.close()
    if type(t) == "table" then
      CRAFT_IN  = t["in"] or ""
      CRAFT_OUT = t.out or ""
      return
    end
  end
  print("first boot - name the two chests (run 'invs' on the store for wired names).")
  print("blank = run standalone with no store link.")
  CRAFT_IN  = askChest("craftIn chest (in front, store pushes raws)")
  CRAFT_OUT = askChest("craftOut chest (below, marked input)")
  local f = fs.open(CFG_FILE, "w")
  f.write(textutils.serialize({ ["in"] = CRAFT_IN, out = CRAFT_OUT }))
  f.close()
  print("saved to " .. CFG_FILE .. "  (run 'crafter reset' to re-enter)")
end

----------------------------------------------------------------- main
local function main()
  if args[1] == "reset" then
    if fs.exists(CFG_FILE) then fs.delete(CFG_FILE) end
  end
  loadOrAskCfg()
  comms.open({ freq = RADIO_FREQ, proto = STORE_PROTOCOL })

  if args[1] == "learn" or args[1] == "teach" then learn(); return end

  announce()
  print("crafter online (freq " .. RADIO_FREQ .. ")")
  while true do
    if not craftPos then craftPos = gps2.locate(1.5, 6) end   -- one-shot fix; stationary so cache it
    local cmd = checkin("idle")
    if type(cmd) == "table" and cmd.type == "craftplan" then
      local ok, made, err = execute(cmd.steps or {})
      comms.send(STORE_NAME, { type = "craftdone", id = os.getComputerID(), ok = ok, made = made, err = err }, STORE_PROTOCOL)
      comms.receive(STORE_PROTOCOL, 2)                -- wait for the store's ack
    else
      sleep(2)
    end
  end
end

main()
