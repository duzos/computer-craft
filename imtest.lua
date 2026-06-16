-- imtest.lua  --  Advanced Peripherals Inventory Manager diagnostic
-- run on the computer the manager is attached/wired to.
-- a Memory Card bound to YOU must be inserted in the manager.
--   imtest         full diagnostic (default)
--   imtest watch   live inventory readout
--   imtest add     pull 1 test item from the source chest into you
--   imtest remove  push 1 test item from you back to the source chest
--   imtest range   blink the test item in your offhand; walk off to find the range

local TEST_ITEM = "minecraft:cobblestone"
local OFFHAND   = 36

local function findManager()
  local m = peripheral.find("inventoryManager") or peripheral.find("inventory_manager")
  if m then return m, peripheral.getName(m) end
  for _, n in ipairs(peripheral.getNames()) do
    if (peripheral.getType(n) or ""):lower():find("manager") then return peripheral.wrap(n), n end
  end
end

local mgr, name = findManager()
if not mgr then
  print("No inventory manager found. Peripherals seen:")
  for _, n in ipairs(peripheral.getNames()) do
    print("  " .. n .. "  (" .. (peripheral.getType(n) or "?") .. ")")
  end
  return
end

local methodSet = {}
for _, m in ipairs(peripheral.getMethods(name)) do methodSet[m] = true end
local function has(m) return methodSet[m] == true end

local function get(m, ...)
  if not has(m) then return nil, "no method" end
  local ok, r = pcall(mgr[m], ...)
  if ok then return r end
  return nil, tostring(r)
end

local function itemStr(it)
  if type(it) ~= "table" or not it.name then return "empty" end
  return (it.displayName or it.name) .. " x" .. (it.count or 1)
end

local function invSummary(items)
  if type(items) ~= "table" then return "?" end
  local stacks, total = 0, 0
  for _, it in pairs(items) do stacks = stacks + 1; total = total + (it.count or 0) end
  return ("%d stacks, %d items"):format(stacks, total)
end

local function info()
  print("manager: " .. name .. "  (" .. (peripheral.getType(name) or "?") .. ")")
  print("methods: " .. table.concat(peripheral.getMethods(name), ", "))
  print("---")
  local owner, e = get("getOwner")
  print("owner: " .. (owner ~= nil and tostring(owner) or ("(none) " .. (e or "insert a bound card"))))
  print("inventory: " .. invSummary((get("getItems"))))
  print("free slot: " .. tostring((get("getFreeSlot"))))
  print("space available: " .. tostring((get("isSpaceAvailable"))))
  print("empty slots: " .. tostring((get("getEmptySpace"))))
  print("hand: " .. itemStr((get("getItemInHand"))))
  print("offhand: " .. itemStr((get("getItemInOffHand"))))
  print("---")
  print("modes: watch | add | remove | range [dir]")
  print("add/remove/range probe all faces; the chest must TOUCH the manager")
end

local DIRS = { "up", "down", "north", "south", "east", "west" }

local function detectDir()
  for _, d in ipairs(DIRS) do
    local ok, r = pcall(mgr.addItemToPlayer, d, { name = TEST_ITEM, count = 1 })
    if ok and r and r > 0 then
      pcall(mgr.removeItemFromPlayer, d, { name = TEST_ITEM, count = r })   -- put it back
      return d
    end
  end
end

local function addOne(dir)
  local sp = get("isSpaceAvailable")
  if sp == false then print("inventory full - aborting (would void)"); return end
  for _, d in ipairs(dir and { dir } or DIRS) do
    local ok, r = pcall(mgr.addItemToPlayer, d, { name = TEST_ITEM, count = 1 })
    if not ok then print(d .. ": ERR " .. tostring(r))
    elseif r and r > 0 then print("added " .. r .. " from the '" .. d .. "' chest"); return end
  end
  print("no " .. TEST_ITEM .. " on any face - a chest must physically touch the manager")
end

local function removeOne(dir)
  for _, d in ipairs(dir and { dir } or DIRS) do
    local ok, r = pcall(mgr.removeItemFromPlayer, d, { name = TEST_ITEM, count = 1 })
    if not ok then print(d .. ": ERR " .. tostring(r))
    elseif r and r > 0 then print("removed " .. r .. " into the '" .. d .. "' chest"); return end
  end
  print("nothing removed - no reachable chest, or you have no " .. TEST_ITEM)
end

local function range(dir)
  dir = dir or detectDir()
  if not dir then
    print("No source chest found on any face.")
    print("Put a chest with " .. TEST_ITEM .. " directly against the manager.")
    return
  end
  print("Source face: '" .. dir .. "'. Blinking 1x " .. TEST_ITEM .. " in your OFFHAND.")
  print("Walk away; when your offhand stops blinking you are out of range.")
  print("Ctrl+T to stop.")
  local n = 0
  while true do
    pcall(mgr.addItemToPlayer, dir, { name = TEST_ITEM, count = 1, toSlot = OFFHAND })
    sleep(1.5)
    pcall(mgr.removeItemFromPlayer, dir, { name = TEST_ITEM, fromSlot = OFFHAND, count = 1 })
    sleep(1.5)
    n = n + 1
    print("cycle " .. n)
  end
end

local function watch()
  while true do
    term.clear(); term.setCursorPos(1, 1)
    print("manager watch  (Ctrl+T to stop)")
    print("owner: " .. tostring((get("getOwner"))))
    print("inv:   " .. invSummary((get("getItems"))))
    print("hand:  " .. itemStr((get("getItemInHand"))))
    print("off:   " .. itemStr((get("getItemInOffHand"))))
    print("free:  " .. tostring((get("getFreeSlot"))) ..
          "  space: " .. tostring((get("isSpaceAvailable"))))
    sleep(1)
  end
end

local cmd, arg = ...
cmd = cmd or "info"
if cmd == "watch" then watch()
elseif cmd == "add" then addOne(arg)
elseif cmd == "remove" then removeOne(arg)
elseif cmd == "range" then range(arg)
else info() end
