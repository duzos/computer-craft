-- radiotest: probe ClassicPeripherals radio (mini antenna / radio tower)
-- modes: info (default) | listen | send [text]
local FREQ = 100

local function call(p, fn)
  if not p[fn] then return "n/a" end
  local ok, v = pcall(p[fn])
  return ok and tostring(v) or ("err:" .. tostring(v))
end

local function findRadio()
  for _, name in ipairs(peripheral.getNames()) do
    local t = peripheral.getType(name)
    if t and (t:find("radio") or t:find("antenna")) then
      return peripheral.wrap(name), name, t
    end
  end
  return nil
end

local function dumpAll()
  print("peripherals:")
  for _, name in ipairs(peripheral.getNames()) do
    print("  " .. name .. " :: " .. tostring(peripheral.getType(name)))
  end
end

local function dumpMethods(name)
  print("methods of " .. name .. ":")
  local m = peripheral.getMethods(name)
  if not m then print("  (none)"); return end
  table.sort(m)
  for _, fn in ipairs(m) do print("  " .. fn) end
end

local function tryFreq(p)
  if p.setFrequency then
    local ok, err = pcall(p.setFrequency, FREQ)
    print("setFrequency(" .. FREQ .. "): " .. (ok and "ok" or ("FAIL " .. tostring(err))))
    print("getFrequency -> " .. call(p, "getFrequency"))
  else
    print("no setFrequency (frequency likely tower-side only)")
  end
end

local mode = ... or "info"
local _, arg2 = ...

local radio, rname, rtype = findRadio()
print("=== radiotest ===")
if not radio then
  print("no radio/antenna peripheral found")
  dumpAll()
  return
end
print("found: " .. rname .. " (type " .. rtype .. ")")

if mode == "info" then
  dumpAll()
  print("")
  dumpMethods(rname)
  print("")
  tryFreq(radio)
  print("isValid     -> " .. call(radio, "isValid"))
  print("canBroadcast-> " .. call(radio, "canBroadcast"))
  print("getHeight   -> " .. call(radio, "getHeight"))
  print("")
  print("then: 'radiotest listen' on one device, 'radiotest send hi' on another")

elseif mode == "listen" then
  tryFreq(radio)
  print("listening for radio_message (q to quit)...")
  parallel.waitForAny(
    function()
      while true do
        local ev = { os.pullEvent() }
        if ev[1] == "radio_message" then
          print(("RADIO side=%s dist=%s data=%s"):format(tostring(ev[2]), tostring(ev[4]), tostring(ev[3])))
        elseif ev[1] == "modem_message" then
          print(("MODEM ch=%s dist=%s data=%s"):format(tostring(ev[3]), tostring(ev[6]), tostring(ev[5])))
        end
      end
    end,
    function()
      while true do local _, k = os.pullEvent("char"); if k == "q" then return end end
    end
  )

elseif mode == "send" then
  tryFreq(radio)
  local text = arg2 or "ping"
  print("broadcasting '" .. text .. "' every 2s, also listening for echo. q to quit")
  if not radio.broadcast then print("NO broadcast method on this peripheral!"); return end
  parallel.waitForAny(
    function()
      while true do
        local ok, err = pcall(radio.broadcast, text)
        if not ok then print("broadcast FAIL: " .. tostring(err)) end
        sleep(2)
      end
    end,
    function()
      while true do
        local ev = { os.pullEvent() }
        if ev[1] == "radio_message" then
          print(("echo? side=%s dist=%s data=%s"):format(tostring(ev[2]), tostring(ev[4]), tostring(ev[3])))
        end
      end
    end,
    function()
      while true do local _, k = os.pullEvent("char"); if k == "q" then return end end
    end
  )
end
