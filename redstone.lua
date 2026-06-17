-- redstone.lua  --  loop that emits redstone output from the computer.
-- no peripheral needed: every computer drives redstone on its own six sides via the
-- built-in redstone API. type "<side> <level>" (e.g. "up 15", "left 10"), or just a
-- level (0-15) to use the default side. up/down alias top/bottom. q to quit.

local SIDE = "back"   -- default side when none is given: top/bottom/left/right/front/back

local SIDES = { top = true, bottom = true, left = true, right = true, front = true, back = true }
local ALIAS = { up = "top", down = "bottom" }

local function main()
  print(('redstone loop  -- "<side> <level>" e.g. up 15 / left 10, or 0-15 for %s. q to quit')
    :format(SIDE))
  while true do
    write("> ")
    local line = (read() or ""):gsub("^%s*(.-)%s*$", "%1"):lower()
    if line == "q" or line == "quit" then break end
    local a, b = line:match("^(%S+)%s+(%S+)$")
    local side = a and (ALIAS[a] or a) or SIDE
    local n = tonumber(a and b or line)
    if not SIDES[side] then
      print("  sides: top/bottom/left/right/front/back (up=top, down=bottom)")
    elseif n and n >= 0 and n <= 15 and n == math.floor(n) then
      redstone.setAnalogOutput(side, n)
      print(("  %s = %d"):format(side, n))
    else
      print("  need a whole number 0-15")
    end
  end
end

main()
