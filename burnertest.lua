-- burnertest.lua  --  Create: Avionics hot air burner (gas_provider) diagnostic + setter
-- run on a computer placed against the burner, or wired to it via a modem.
-- interactive (default): type a number (e.g. 310) to set the max hot air output; it reads back.
--   i / info    one-shot snapshot incl. the peripheral's real method list
--   w / watch   live readout (press a key to stop)
--   q           quit
-- one-shot from the shell too:  burnertest watch  |  burnertest set 310  |  burnertest info
-- NOTE: actual output = target * redstoneSignal/15, so the burner needs a redstone signal to
-- do anything; this only sets the cap ("max hot air output", typically ~5-500).

local function findBurner()
  local p = peripheral.find("gas_provider")
  if p then return p, peripheral.getName(p) end
  for _, n in ipairs(peripheral.getNames()) do
    local t = (peripheral.getType(n) or ""):lower()
    if t:find("gas") or t:find("burner") then return peripheral.wrap(n), n end
  end
end

local burner, name = findBurner()
if not burner then
  print("No gas_provider (hot air burner) found. Peripherals seen:")
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
  local ok, r = pcall(burner[m], ...)
  if ok then return r end
  return nil, tostring(r)
end

local function fmt(x)
  if type(x) == "number" then
    if x == math.floor(x) then return tostring(x) end
    return string.format("%.2f", x)
  end
  if x == nil then return "-" end
  return tostring(x)
end

local function snapshot()
  print("burner: " .. name .. "  (" .. (peripheral.getType(name) or "?") .. ")")
  print(("active %s | signal %s/15 | gas %s")
    :format(fmt(get("isActive")), fmt(get("getSignalStrength")), fmt(get("getGasType"))))
  print(("max output %s -> current output %s | efficiency %s")
    :format(fmt(get("getTargetAmount")), fmt(get("getGasOutput")), fmt(get("getBoilerEfficiency"))))
  if get("hasBalloon") == true then
    print(("balloon: %s / %s filled (cap %s) | lift %s | dV %s")
      :format(fmt(get("getBalloonFilledVolume")), fmt(get("getBalloonTargetVolume")),
              fmt(get("getBalloonCapacity")), fmt(get("getBalloonLift")),
              fmt(get("getBalloonVolumeChange"))))
  else
    print("balloon: none attached")
  end
end

local function info()
  print("methods: " .. table.concat(peripheral.getMethods(name), ", "))
  snapshot()
end

local function watch()
  while true do
    term.clear(); term.setCursorPos(1, 1)
    print("burner watch  (press a key to stop)")
    snapshot()
    local timer = os.startTimer(1)
    while true do
      local ev = { os.pullEvent() }
      if ev[1] == "timer" and ev[2] == timer then break end
      if ev[1] == "key" or ev[1] == "char" then return end
    end
  end
end

local function setTarget(n)
  if not has("setTargetAmount") then print("  no setTargetAmount on this peripheral"); return end
  local ok, err = pcall(burner.setTargetAmount, n)
  if not ok then print("  ERR " .. tostring(err)); return end
  print(("  max output set %d -> now %s"):format(n, fmt(get("getTargetAmount"))))
end

local function loop()
  print('burner control  -- number = set max output (~5-500), "i" info, "w" watch, "q" quit')
  snapshot()
  while true do
    write("> ")
    local line = (read() or ""):gsub("^%s*(.-)%s*$", "%1"):lower()
    if line == "q" or line == "quit" then break
    elseif line == "i" or line == "info" then info()
    elseif line == "w" or line == "watch" then watch()
    elseif line ~= "" then
      local n = tonumber(line)
      if n and n >= 0 and n == math.floor(n) then setTarget(n)
      else print('  type a whole number, or "i" / "w" / "q"') end
    end
  end
end

local cmd, arg = ...
if cmd == "watch" then watch()
elseif cmd == "info" then info()
elseif cmd == "set" then
  local n = tonumber(arg)
  if n then setTarget(n) else print("usage: burnertest set <number>") end
else loop() end
