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

local comms = require("comms")

local STORE_PROTOCOL = "store"
local STORE_NAME     = "store"
local RADIO_FREQ     = 1000        -- must match the store's RADIO_FREQ
local CFG_FILE       = "crafter.cfg"

-- store-side wired names of the two chests, asked on first boot. the turtle sucks/drops by
-- direction (front/down); these names only tell the store where to push raws and vacuum output.
local CRAFT_IN  = ""               -- chest in front; store pushes raws here (kept out of the pool)
local CRAFT_OUT = ""               -- chest below; finished goods land here (marked input)

local GRID = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }    -- turtle slots that form the 3x3 crafting grid
local FREE = { 4, 8, 12, 13, 14, 15, 16 }       -- non-grid slots: scratch + crafted output

local args = { ... }

local gridSet = {}
for _, s in ipairs(GRID) do gridSet[s] = true end

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

local function checkin(phase)
  if not comms.up() then return nil end
  local fl = turtle.getFuelLevel()
  comms.send(STORE_NAME, {
    type = "telem", kind = "craft", id = os.getComputerID(), label = os.getComputerLabel(),
    phase = phase or "idle", pct = 0, halted = false,
    fuel = (fl == "unlimited") and 1 or fl, fuelMax = 1,
    craftIn = CRAFT_IN,            -- so the store learns where to deliver raws
  }, STORE_PROTOCOL)
  local m = comms.receive(STORE_PROTOCOL, 1.5)
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

-- move grid slot `s` into the non-grid scratch slots so it can be re-arranged for a step
local function clearGridSlot(s)
  turtle.select(s)
  for _, f in ipairs(FREE) do
    if turtle.getItemCount(s) == 0 then break end
    turtle.transferTo(f)
  end
  return turtle.getItemCount(s) == 0
end

local function clearGrid()
  local ok = true
  for _, s in ipairs(GRID) do
    if turtle.getItemCount(s) > 0 and not clearGridSlot(s) then ok = false end
  end
  turtle.select(1)
  return ok
end

-- gather up to `want` of `id` into grid slot `dst`, pulling only from non-grid slots so a grid
-- slot arranged earlier in the same step is never raided
local function gather(id, dst, want)
  local have = 0
  local d = turtle.getItemDetail(dst)
  if d and d.name == id then have = turtle.getItemCount(dst) end
  for s = 1, 16 do
    if have >= want then break end
    if s ~= dst and not gridSet[s] then
      local sd = turtle.getItemDetail(s)
      if sd and sd.name == id then
        turtle.select(s)
        turtle.transferTo(dst, want - have)
        have = turtle.getItemCount(dst)
      end
    end
  end
  return have
end

-- arrange `chunk` of each ingredient into its grid slot for one recipe step; returns ok, reason
local function arrange(grid, chunk)
  if not clearGrid() then return false, "inv full" end
  for slot, id in pairs(grid) do
    if gather(id, slot, chunk) < chunk then return false, "need " .. shortId(id) end
  end
  return true
end

local function freeOutSlot(out)                       -- empty scratch slot (or one already holding `out`)
  for _, f in ipairs(FREE) do
    local d = turtle.getItemDetail(f)
    if not d or d.name == out then return f end
  end
  return nil
end

----------------------------------------------------------------- craft
-- one recipe step: craft `step.batches` times, chunked so neither a grid slot (<=64) nor the
-- output stack (<=64) overflows. intermediates stay in the inventory for later steps.
-- run one recipe step; returns ok, reason. reason is short on failure: "bad recipe (relearn)"
-- (grid didn't match a recipe), "need <item>" (ingredient short), "inv full", "no crafting table".
local function runStep(step)
  if not turtle.craft then return false, "no crafting table" end
  local per = math.max(1, math.min(64, math.floor(64 / math.max(1, step.yield))))
  local remaining = step.batches
  local done = 0
  while remaining > 0 do
    local chunk = math.min(remaining, per)
    local ok, why = arrange(step.grid, chunk)
    if not ok then return false, why end
    local out = freeOutSlot(step.out)
    if not out then return false, "inv full" end
    turtle.select(out)
    if not turtle.craft(chunk) then return false, "bad recipe (relearn)" end
    remaining = remaining - chunk
    done = done + chunk
    if step.batches > per then print(("    %d/%d"):format(done, step.batches)) end   -- chunked progress
  end
  return true
end

local function execute(steps)
  dumpAll()                                           -- clean slate
  while turtle.suck() do end                          -- pull all the raws the store pushed to craftIn
  local target = steps[#steps] and steps[#steps].out
  print(("crafting %s  (%d step%s)"):format(shortId(target), #steps, #steps == 1 and "" or "s"))
  local err
  for i, step in ipairs(steps) do
    print(("  [%d/%d] %d x %s"):format(i, #steps, step.batches * step.yield, shortId(step.out)))
    local ok, why = runStep(step)
    if not ok then err = shortId(step.out) .. ": " .. (why or "failed"); break end
  end
  local made = target and countId(target) or 0
  dumpAll()                                           -- finished goods + leftovers -> craftOut -> pool
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
    local cmd = checkin("idle")
    if type(cmd) == "table" and cmd.type == "craftplan" then
      checkin("crafting")
      local ok, made, err = execute(cmd.steps or {})
      comms.send(STORE_NAME, { type = "craftdone", id = os.getComputerID(), ok = ok, made = made, err = err }, STORE_PROTOCOL)
      comms.receive(STORE_PROTOCOL, 2)                -- wait for the store's ack
    else
      sleep(2)
    end
  end
end

main()
