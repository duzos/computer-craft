-- map.lua  reusable top-down (X/Z) map renderer for any CC terminal or advanced
-- monitor. Data-agnostic: draw(dev, markers, viewport, opts) takes a list of plain
-- markers { x, z, label, colour, char, kind, follow } and a viewport { cx, cz, scale };
-- it knows nothing about GPS, comms or the fleet, so any caller (gpsprobe, shipnav,
-- storepad) can feed it a GPS fix, the gpshost towers, loc beacons, or store telemetry.
--
-- Coordinates: world X -> screen column, world Z -> screen row (top-down, north up),
-- a single `scale` = screen chars per world block (bigger = zoomed in). draw() returns
-- a projection; screenToWorld() inverts it so a touch/click maps back to a world X/Z
-- (tap-to-pan, click-to-locate, tap-to-set-target) and worldToScreen() goes the other
-- way. Terminal cells are taller than wide, so the picture is stretched vertically the
-- same way the older hand-rolled minimaps were - distances read off it are approximate;
-- the world<->screen maths itself is exact and round-trips.
--
-- viewport (build with map.viewport):
--   cx, cz : world point at the centre of the box
--   scale  : chars per block (nil until first auto-fit)
--   auto   : true = ignore cx/cz/scale and fit every marker into the box this frame
--   follow : true = recentre cx/cz on the marker flagged .follow (e.g. "me") each frame
-- Pure (touches no peripheral but the passed `dev`), so it parse-checks standalone.

local map = {}

local MIN_SCALE, MAX_SCALE = 0.01, 16
local function clampScale(s) return math.max(MIN_SCALE, math.min(MAX_SCALE, s)) end

-- default glyph + colour per marker kind; map.marker() applies these, callers override
map.KIND = {
  self   = { colour = colors.lime,      char = "@" },
  me     = { colour = colors.lime,      char = "@" },
  ship   = { colour = colors.lime,      char = "^" },
  tower  = { colour = colors.cyan,      char = "T" },
  target = { colour = colors.red,       char = "X" },
  quarry = { colour = colors.yellow,    char = "Q" },
  tree   = { colour = colors.green,     char = "t" },
  craft  = { colour = colors.orange,    char = "C" },
  pad    = { colour = colors.magenta,   char = "P" },
  probe  = { colour = colors.lightBlue, char = "p" },
  player = { colour = colors.white,     char = "*" },
}

function map.styleFor(kind)
  local s = map.KIND[kind or ""] or { colour = colors.white, char = "*" }
  return s.colour, s.char
end

-- build a styled marker; `extra` overrides any field (colour, char, follow, label ...)
function map.marker(x, z, label, kind, extra)
  local colour, char = map.styleFor(kind)
  local m = { x = x, z = z, label = label, kind = kind, colour = colour, char = char }
  if extra then for k, v in pairs(extra) do m[k] = v end end
  return m
end

function map.viewport(o)
  o = o or {}
  return { cx = o.cx, cz = o.cz, scale = o.scale, auto = o.auto ~= false, follow = o.follow or false }
end

-- zoom in (factor>1) / out (factor<1) about the current centre; leaves auto-fit
function map.zoom(vp, factor)
  vp.auto = false
  vp.scale = clampScale((vp.scale or 1) * factor)
  return vp
end

-- pan by a world delta; leaves auto-fit
function map.pan(vp, dx, dz)
  vp.auto = false
  vp.cx = (vp.cx or 0) + dx
  vp.cz = (vp.cz or 0) + dz
  return vp
end

function map.center(vp, x, z) vp.auto = false; vp.cx, vp.cz = x, z; return vp end
function map.fit(vp) vp.auto = true; return vp end
function map.setFollow(vp, on) vp.follow = on and true or false; if on then vp.auto = false end; return vp end

-- proj is the table returned by draw(): { x1,y1,x2,y2 (plot box), cx, cz, scale }
function map.worldToScreen(proj, x, z)
  local midC = (proj.x1 + proj.x2) / 2
  local midR = (proj.y1 + proj.y2) / 2
  return math.floor(midC + (x - proj.cx) * proj.scale + 0.5),
         math.floor(midR + (z - proj.cz) * proj.scale + 0.5)
end

function map.screenToWorld(proj, col, row)
  local midC = (proj.x1 + proj.x2) / 2
  local midR = (proj.y1 + proj.y2) / 2
  return proj.cx + (col - midC) / proj.scale,
         proj.cz + (row - midR) / proj.scale
end

-- true when a screen cell falls inside the plot box (for touch hit-testing)
function map.inBox(proj, col, row)
  return col >= proj.x1 and col <= proj.x2 and row >= proj.y1 and row <= proj.y2
end

local function fitView(markers, dots, px1, py1, px2, py2, minSpan)
  local minX, maxX, minZ, maxZ
  local function inc(x, z)
    if not x then return end
    if not minX then minX, maxX, minZ, maxZ = x, x, z, z
    else
      if x < minX then minX = x end
      if x > maxX then maxX = x end
      if z < minZ then minZ = z end
      if z > maxZ then maxZ = z end
    end
  end
  for _, m in ipairs(markers) do inc(m.x, m.z) end
  if dots then for _, d in ipairs(dots) do inc(d.x, d.z) end end
  if not minX then minX, maxX, minZ, maxZ = 0, 1, 0, 1 end
  local cx, cz = (minX + maxX) / 2, (minZ + maxZ) / 2
  local spanX = math.max(maxX - minX, minSpan)
  local spanZ = math.max(maxZ - minZ, minSpan)
  local scale = math.min((px2 - px1) / spanX, (py2 - py1) / spanZ)
  if scale <= 0 then scale = 0.01 end
  return cx, cz, scale
end

-- draw(dev, markers, vp, opts) -> proj
--   markers : list of { x, z, label, colour, char, follow }
--   opts.box      : { x1,y1,x2,y2 } area to own (default = whole device)
--   opts.border   : draw a box border just inside the area, plot one cell in
--   opts.borderColour, opts.rings (list {x,z,r,colour}), opts.dots (list {x,z,colour,char})
--   opts.minSpan  : smallest world span auto-fit will zoom to (default 8)
--   opts.labels   : write each marker's label after its glyph when there is room
function map.draw(dev, markers, vp, opts)
  opts = opts or {}
  markers = markers or {}
  local W, H = dev.getSize()
  local x1 = opts.box and opts.box.x1 or 1
  local y1 = opts.box and opts.box.y1 or 1
  local x2 = opts.box and opts.box.x2 or W
  local y2 = opts.box and opts.box.y2 or H

  -- plot box (inset by one cell when a border is requested)
  local px1, py1, px2, py2 = x1, y1, x2, y2
  if opts.border then
    local bc = opts.borderColour or colors.gray
    dev.setBackgroundColor(colors.black); dev.setTextColor(bc)
    for x = x1, x2 do
      dev.setCursorPos(x, y1); dev.write("-")
      dev.setCursorPos(x, y2); dev.write("-")
    end
    for y = y1 + 1, y2 - 1 do
      dev.setCursorPos(x1, y); dev.write("|")
      dev.setCursorPos(x2, y); dev.write("|")
    end
    dev.setCursorPos(x1, y1); dev.write("+"); dev.setCursorPos(x2, y1); dev.write("+")
    dev.setCursorPos(x1, y2); dev.write("+"); dev.setCursorPos(x2, y2); dev.write("+")
    px1, py1, px2, py2 = x1 + 1, y1 + 1, x2 - 1, y2 - 1
  end

  local minSpan = opts.minSpan or 8
  local cx, cz, scale = vp.cx, vp.cz, vp.scale
  if vp.auto or not (cx and cz and scale) then
    cx, cz, scale = fitView(markers, opts.dots, px1, py1, px2, py2, minSpan)
    vp.cx, vp.cz, vp.scale = cx, cz, scale   -- seed so a later zoom/pan starts here
  end
  if vp.follow then
    for _, m in ipairs(markers) do
      if m.follow then cx, cz, vp.cx, vp.cz = m.x, m.z, m.x, m.z; break end
    end
  end
  scale = clampScale(scale)
  local proj = { x1 = px1, y1 = py1, x2 = px2, y2 = py2, cx = cx, cz = cz, scale = scale }

  dev.setBackgroundColor(colors.black)

  local function plot(c, r, s, fg)
    if c < px1 or c > px2 or r < py1 or r > py2 then return end
    dev.setCursorPos(c, r); dev.setTextColor(fg or colors.white); dev.write(s)
  end

  -- range rings (gpsprobe feeds tower distances; they cross at the fix)
  if opts.rings then
    for _, ring in ipairs(opts.rings) do
      local rc = ring.r * scale
      if rc >= 1 then
        local step = math.max(0.04, 1 / rc)
        local a = 0
        while a < 6.2832 do
          local c, r = map.worldToScreen(proj, ring.x + ring.r * math.cos(a), ring.z + ring.r * math.sin(a))
          plot(c, r, ".", ring.colour or colors.gray)
          a = a + step
        end
      end
    end
  end

  -- faint dot layer (e.g. a ship trail)
  if opts.dots then
    for _, d in ipairs(opts.dots) do
      local c, r = map.worldToScreen(proj, d.x, d.z)
      plot(c, r, d.char or ".", d.colour or colors.gray)
    end
  end

  -- markers last so they sit on top of rings/dots
  for _, m in ipairs(markers) do
    if m.x and m.z then
      local c, r = map.worldToScreen(proj, m.x, m.z)
      local glyph = m.char or (m.label and m.label:sub(1, 1)) or "*"
      plot(c, r, glyph, m.colour or colors.white)
      if opts.labels and m.label and c + #glyph <= px2 then
        plot(c + #glyph, r, m.label, m.colour or colors.white)
      end
    end
  end

  dev.setBackgroundColor(colors.black); dev.setTextColor(colors.white)
  map._last = proj
  return proj
end

return map
