-- storepad.lua  --  store + overview console for a pocket computer with a mini radio antenna
-- boot menu picks a mode; x returns to it. talks to the store over comms.lua.

local comms = require("comms")
local STORE_PROTOCOL = "store"
local RADIO_FREQ     = 1000       -- must match the store's RADIO_FREQ

local link = comms.open({ freq = RADIO_FREQ, proto = STORE_PROTOCOL })
if not comms.up() then print("No radio antenna or wireless modem found."); return end

local W, H = term.getSize()
local mode = "menu"               -- menu | store | overview
local status = ""

local function req(line)
  if not comms.up() then return nil end
  comms.send("store", line, STORE_PROTOCOL)
  local r = comms.receive(STORE_PROTOCOL, 3)
  return r and r.body
end

local function clamp(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end
local function clip(s, n) return #s > n and s:sub(1, n) or s end
local function short(id) return id:match("[^:]+$") or id end
local function fmtAgo(s) s = math.floor(s) if s < 15 then return "live" elseif s < 90 then return s .. "s" else return math.floor(s / 60) .. "m" end end
local function fmtEta(s)
  if not s or s <= 0 then return "?" end
  if s < 90 then return math.floor(s) .. "s" end
  if s < 5400 then return math.floor(s / 60) .. "m" end
  return string.format("%.1fh", s / 3600)
end

local function at(x, y, s, fg, bg)
  term.setCursorPos(x, y)
  if fg then term.setTextColor(fg) end
  if bg then term.setBackgroundColor(bg) end
  term.write(s)
  term.setBackgroundColor(colors.black)
end
local function rightAt(y, s, c) at(W - #s + 1, y, s, c) end
local function bar(x, y, w, frac, fill)
  frac = frac < 0 and 0 or (frac > 1 and 1 or frac)
  local f = math.floor(frac * w + 0.5)
  term.setCursorPos(x, y); term.setBackgroundColor(fill); term.write(string.rep(" ", f))
  term.setBackgroundColor(colors.gray); term.write(string.rep(" ", w - f)); term.setBackgroundColor(colors.black)
end
local function fillRow(y, bg)
  term.setCursorPos(1, y); term.setBackgroundColor(bg)
  term.write(string.rep(" ", W)); term.setBackgroundColor(colors.black)
end
local function titleBar(label, right, rcol)
  term.setCursorPos(1, 1); term.setBackgroundColor(colors.blue); term.setTextColor(colors.white)
  term.clearLine(); term.write(" " .. label)
  if right then at(W - #right, 1, right, rcol or colors.lightBlue, colors.blue) end
  term.setBackgroundColor(colors.black)
end

----------------------------------------------------------------- store mode
local items, header = {}, {}
local sel, scroll, amt = 1, 0, 64
local lastIdx, lastClick = nil, 0
local sortMode = 1
local procPick = false             -- store mode: PROCESS tapped, picking smelt/cook/wash
local AMOUNTS = { 1, 8, 16, 32, 64 }
local LIST_TOP, LIST_BOTTOM = 4, H - 4
local ROWS = LIST_BOTTOM - LIST_TOP + 1
local amtRegions, getBtn, procBtn, sortBtn, sortTagBtn = {}, nil, nil, nil, nil
local procBtns, cancelBtn = {}, nil   -- type buttons shown while picking; cancel

local SORTS = {
  { key = "qty", cmp = function(a, b) return a.n > b.n end },
  { key = "low", cmp = function(a, b) return a.n < b.n end },
  { key = "a-z", cmp = function(a, b) return short(a.id) < short(b.id) end },
}
local function applySort() table.sort(items, SORTS[sortMode].cmp) end
local function reselect(id) if id then for i, it in ipairs(items) do if it.id == id then sel = i; return end end end end

local function fetchStore()
  local keepId = items[sel] and items[sel].id
  local r = req("items")
  if not r then status = "offline / out of range"; items = {}; return end
  local d = textutils.unserialize(r)
  if type(d) ~= "table" then status = "bad reply"; return end
  items, header = d.list or {}, d
  applySort(); reselect(keepId)
  sel = clamp(sel, 1, math.max(1, #items))
  scroll = clamp(scroll, 0, math.max(0, #items - ROWS))
end

local function storeRender()
  term.setBackgroundColor(colors.black); term.clear()
  titleBar("STORE", header.mode == "SORT" and "SORT" or (header.mode and "WAIT" or nil),
           header.mode == "SORT" and colors.lime or colors.orange)
  if header.totalSlots then
    local pct = header.totalSlots > 0 and math.floor(header.usedSlots / header.totalSlots * 100) or 0
    at(1, 2, clip(("%d/%d  %d%%"):format(header.usedSlots, header.totalSlots, pct), W - 6), colors.lightGray)
  end
  local tag = " " .. SORTS[sortMode].key .. " "
  at(W - #tag + 1, 2, tag, colors.black, colors.cyan)
  sortTagBtn = { x1 = W - #tag + 1, x2 = W }
  at(1, 3, string.rep("-", W), colors.gray)

  for i = 1, ROWS do
    local idx = scroll + i
    local it = items[idx]
    local y = LIST_TOP + i - 1
    if it then
      local on = (idx == sel)
      if on then fillRow(y, colors.gray) end
      local cnt = tostring(it.n)
      at(1, y, clip(short(it.id), W - #cnt - 1), on and colors.white or colors.lightGray, on and colors.gray or nil)
      at(W - #cnt + 1, y, cnt, colors.yellow, on and colors.gray or nil)
    end
  end
  at(1, LIST_BOTTOM + 1, string.rep("-", W), colors.gray)

  local cur = items[sel]
  at(1, H - 3, cur and ("> " .. clip(short(cur.id), W - 8) .. " (" .. cur.n .. ")") or "> -", colors.white)
  amtRegions = {}
  at(1, H - 2, "amt", colors.cyan)
  local x = 5
  for _, a in ipairs(AMOUNTS) do
    local label = " " .. a .. " "
    local onA = (a == amt)
    at(x, H - 2, label, onA and colors.black or colors.white, onA and colors.lime or colors.gray)
    amtRegions[#amtRegions + 1] = { x1 = x, x2 = x + #label - 1, val = a }
    x = x + #label
  end
  local function button(bx, label, bg)
    at(bx, H - 1, label, colors.black, bg); return { x1 = bx, x2 = bx + #label - 1 }
  end
  if procPick then
    procBtns = {}
    local px = 1
    for _, t in ipairs({ "smelt", "cook", "wash" }) do
      local bg = t == "smelt" and colors.orange or (t == "cook" and colors.red or colors.lightBlue)
      local b = button(px, "[" .. t:upper() .. "]", bg)
      b.typ = t; procBtns[#procBtns + 1] = b
      px = b.x2 + 2
    end
    cancelBtn = button(px, "[X]", colors.gray)
    getBtn, procBtn, sortBtn = nil, nil, nil
  else
    getBtn  = button(1,  "[GET]",      colors.green)
    procBtn = button(7,  "[PROCESS]",  colors.orange)
    sortBtn = button(17, "[SORT INV]", colors.lightBlue)
    procBtns, cancelBtn = {}, nil
  end
  local hint = procPick and "pick s/c/w  x cancel" or "2x=all  x menu  q quit"
  at(1, H, status ~= "" and clip(status, W) or hint, colors.gray)
end

local function ensureVisible()
  if sel - 1 < scroll then scroll = sel - 1 end
  if sel > scroll + ROWS then scroll = sel - ROWS end
  scroll = clamp(scroll, 0, math.max(0, #items - ROWS))
end
local function doGet(amount)
  local cur = items[sel]
  if not cur then status = "nothing selected"; return end
  status = req("withdraw " .. cur.id .. " " .. (amount or amt)) or "offline"
  fetchStore()
end
local function doProcess(typ)
  local cur = items[sel]
  if not cur then status = "nothing selected"; return end
  status = req("process " .. typ .. " " .. cur.id .. " " .. amt) or "offline"
  procPick = false
  fetchStore()
end
local function doSortInv() status = req("deposit all") or "offline"; fetchStore() end
local function cycleSort()
  sortMode = sortMode % #SORTS + 1
  local keepId = items[sel] and items[sel].id
  applySort(); reselect(keepId); ensureVisible()
end

local function storeClick(x, y)
  if y == 2 and sortTagBtn and x >= sortTagBtn.x1 and x <= sortTagBtn.x2 then cycleSort()
  elseif y >= LIST_TOP and y <= LIST_BOTTOM then
    local idx = scroll + (y - LIST_TOP) + 1
    if items[idx] then
      local now = os.clock()
      if idx == lastIdx and (now - lastClick) < 0.5 then sel = idx; doGet(items[idx].n); lastIdx = nil
      else sel = idx; lastIdx, lastClick = idx, now end
    end
  elseif y == H - 2 then
    for _, r in ipairs(amtRegions) do if x >= r.x1 and x <= r.x2 then amt = r.val end end
  elseif y == H - 1 then
    if procPick then
      for _, b in ipairs(procBtns) do if x >= b.x1 and x <= b.x2 then doProcess(b.typ); return end end
      if cancelBtn and x >= cancelBtn.x1 and x <= cancelBtn.x2 then procPick = false end
    else
      if getBtn and x >= getBtn.x1 and x <= getBtn.x2 then doGet()
      elseif procBtn and x >= procBtn.x1 and x <= procBtn.x2 then procPick = true
      elseif sortBtn and x >= sortBtn.x1 and x <= sortBtn.x2 then doSortInv() end
    end
  end
end

local function storeKey(k)
  if k == keys.up then sel = clamp(sel - 1, 1, #items); ensureVisible()
  elseif k == keys.down then sel = clamp(sel + 1, 1, #items); ensureVisible()
  elseif k == keys.pageUp then sel = clamp(sel - ROWS, 1, #items); ensureVisible()
  elseif k == keys.pageDown then sel = clamp(sel + ROWS, 1, #items); ensureVisible()
  elseif k == keys.enter or k == keys.numPadEnter then status = ""; doGet()
  elseif k == keys.tab then cycleSort() end
end
local function storeChar(c)
  if procPick then
    if c == "s" then doProcess("smelt")
    elseif c == "c" then doProcess("cook")
    elseif c == "w" then doProcess("wash")
    else procPick = false; status = "" end
    return
  end
  if c == "s" then status = ""; doSortInv()
  elseif c == "m" then status = ""; procPick = true
  elseif c == "a" then status = ""; if items[sel] then doGet(items[sel].n) end
  elseif c == "r" then status = ""; fetchStore()
  elseif c:match("^[1-5]$") then amt = AMOUNTS[tonumber(c)] or amt end
end

----------------------------------------------------------------- overview mode
local fleet = {}
local qsel, qscroll = 1, 0
local QTOP, QBOT = 3, H - 6
local QROWS = QBOT - QTOP + 1
local rtbBtn, contBtn, allBtn = nil, nil, nil

local function fetchFleet()
  local keepId = fleet[qsel] and fleet[qsel].id
  local r = req("fleet")
  if not r then status = "offline / out of range"; fleet = {}; return end
  local d = textutils.unserialize(r)
  fleet = type(d) == "table" and d or {}
  if keepId then for i, t in ipairs(fleet) do if t.id == keepId then qsel = i end end end
  qsel = clamp(qsel, 1, math.max(1, #fleet))
  qscroll = clamp(qscroll, 0, math.max(0, #fleet - QROWS))
end

local function qstatus(tr)
  if tr.halted then return "HALT", colors.cyan end
  if tr.phase == "done" then return "DONE", colors.lime end
  if (tr.ago or 0) > 180 then return "STALE", colors.red end
  if tr.stuck then return "STALL", colors.orange end
  return fmtAgo(tr.ago or 0), (tr.ago or 0) < 15 and colors.lime or colors.lightGray
end

local function overviewRender()
  term.setBackgroundColor(colors.black); term.clear()
  titleBar("OVERVIEW", tostring(#fleet))
  if #fleet == 0 then at(1, 3, "no turtles checked in", colors.gray) end
  for i = 1, QROWS do
    local tr = fleet[qscroll + i]
    local y = QTOP + i - 1
    if tr then
      local on = (qscroll + i == qsel)
      if on then fillRow(y, colors.gray) end
      local nm = tr.label or ("t" .. tr.id)
      local st, sc = qstatus(tr)
      at(1, y, clip(nm, 10), on and colors.white or colors.lightGray, on and colors.gray or nil)
      if tr.pct and tr.pct > 0 then
        at(12, y, tr.pct .. "%", colors.yellow, on and colors.gray or nil)
      else
        at(12, y, clip(tr.phase or "-", 9), colors.lightGray, on and colors.gray or nil)
      end
      at(W - #st + 1, y, st, sc, on and colors.gray or nil)
    end
  end
  at(1, QBOT + 1, string.rep("-", W), colors.gray)
  local cur = fleet[qsel]
  if cur then
    if cur.kind == "tree" then
      at(1, H - 4, clip(("%s  logs %d"):format(cur.phase or "?", cur.logs or 0), W - 7), colors.lightGray)
    else
      at(1, H - 4, clip(("%s eta %s y%d"):format(cur.phase or "?", fmtEta(cur.eta), cur.pos and cur.pos.y or 0), W - 7), colors.lightGray)
    end
    if cur.dist then
      local dcol = cur.rng == "far" and colors.red or (cur.rng == "warn" and colors.orange or colors.lightGray)
      local dTxt = math.floor(cur.dist) .. "m"
      at(W - #dTxt + 1, H - 4, dTxt, dcol)
    end
    if cur.kind == "tree" then
      at(1, H - 3, clip(("cut %s  seen %s"):format(cur.mineAgo and fmtAgo(cur.mineAgo) or "-", fmtAgo(cur.ago or 0)), W), colors.lightGray)
    else
      at(1, H - 3, clip(("last %s  seen %s"):format(cur.last and short(cur.last) or "-", fmtAgo(cur.ago or 0)), W), colors.lightGray)
    end
    local ffrac = (cur.fuelMax and cur.fuelMax > 0) and (cur.fuel or 0) / cur.fuelMax or 0
    local fcol = ffrac > 0.5 and colors.lime or (ffrac > 0.2 and colors.orange or colors.red)
    at(1, H - 2, "fuel", colors.cyan)
    bar(6, H - 2, 12, ffrac, fcol)
    at(19, H - 2, math.floor(ffrac * 100) .. "%", colors.lightGray)
  end
  local function button(bx, label, bg) at(bx, H - 1, label, colors.black, bg); return { x1 = bx, x2 = bx + #label - 1 } end
  rtbBtn  = button(1,  "[RTB]",  colors.red)
  contBtn = button(7,  "[CONT]", colors.green)
  allBtn  = button(14, "[RTB ALL]", colors.orange)
  at(1, H, status ~= "" and clip(status, W) or "x menu  f refresh  q quit", colors.gray)
end

local function rtbSel()
  local cur = fleet[qsel]; if not cur then return end
  status = req("rtb " .. cur.id) or "offline"; fetchFleet()
end
local function contSel()
  local cur = fleet[qsel]; if not cur then return end
  status = req("continue " .. cur.id) or "offline"; fetchFleet()
end

local function overviewClick(x, y)
  if y >= QTOP and y <= QBOT then
    local idx = qscroll + (y - QTOP) + 1
    if fleet[idx] then qsel = idx end
  elseif y == H - 1 then
    if rtbBtn and x >= rtbBtn.x1 and x <= rtbBtn.x2 then rtbSel()
    elseif contBtn and x >= contBtn.x1 and x <= contBtn.x2 then contSel()
    elseif allBtn and x >= allBtn.x1 and x <= allBtn.x2 then status = req("rtb all") or "offline"; fetchFleet() end
  end
end
local function overviewKey(k)
  if k == keys.up then qsel = clamp(qsel - 1, 1, #fleet)
  elseif k == keys.down then qsel = clamp(qsel + 1, 1, #fleet) end
  if qsel - 1 < qscroll then qscroll = qsel - 1 end
  if qsel > qscroll + QROWS then qscroll = qsel - QROWS end
  qscroll = clamp(qscroll, 0, math.max(0, #fleet - QROWS))
end
local function overviewChar(c)
  if c == "r" then status = ""; rtbSel()
  elseif c == "c" then status = ""; contSel()
  elseif c == "f" then status = ""; fetchFleet() end
end

----------------------------------------------------------------- menu
local menuRegions = {}
local function menuRender()
  term.setBackgroundColor(colors.black); term.clear()
  titleBar("STOREPAD")
  menuRegions = {}
  local opts = { { "Store",  "store" }, { "Overview", "overview" } }
  for i, o in ipairs(opts) do
    local y = 3 + (i - 1) * 3
    fillRow(y, colors.gray); at(2, y, "[" .. i .. "] " .. o[1], colors.white, colors.gray)
    menuRegions[#menuRegions + 1] = { y = y, m = o[2] }
  end
  at(1, H, "1/2 or tap   q quit", colors.gray)
end
local function enter(m)
  mode = m; status = ""; procPick = false
  if m == "store" then fetchStore() elseif m == "overview" then fetchFleet() end
end

----------------------------------------------------------------- dispatch
local function render()
  if mode == "menu" then menuRender()
  elseif mode == "store" then storeRender()
  else overviewRender() end
end

render()
while true do
  local ev = { os.pullEvent() }
  local e = ev[1]
  if e == "mouse_click" then
    status = ""
    if mode == "menu" then
      for _, r in ipairs(menuRegions) do if ev[4] == r.y then enter(r.m) end end
    elseif mode == "store" then storeClick(ev[3], ev[4])
    else overviewClick(ev[3], ev[4]) end
    render()
  elseif e == "mouse_scroll" then
    if mode == "store" then scroll = clamp(scroll + ev[2], 0, math.max(0, #items - ROWS))
    elseif mode == "overview" then qscroll = clamp(qscroll + ev[2], 0, math.max(0, #fleet - QROWS)) end
    render()
  elseif e == "key" then
    if mode == "store" then storeKey(ev[2])
    elseif mode == "overview" then overviewKey(ev[2]) end
    render()
  elseif e == "char" then
    local c = ev[2]
    if c == "q" then break
    elseif c == "x" and mode ~= "menu" then mode = "menu"; status = ""
    elseif mode == "menu" and (c == "1" or c == "2") then enter(c == "1" and "store" or "overview")
    elseif mode == "store" then storeChar(c)
    elseif mode == "overview" then overviewChar(c) end
    render()
  end
end
term.setBackgroundColor(colors.black); term.setTextColor(colors.white)
term.clear(); term.setCursorPos(1, 1); print("storepad stopped.")
