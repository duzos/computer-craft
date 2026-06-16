-- update.lua  --  pull the latest fleet code from GitHub, safely, before launch.
-- Run by `startup` on every device. Mirrors every top-level .lua file in the repo:
--   1. resolve the branch HEAD commit, so we fetch one immutable snapshot and dodge the
--      raw.githubusercontent CDN's stale-for-minutes cache (a moving branch ref does not),
--   2. fetch each file at that commit and confirm it parses as Lua,
--   3. only once ALL files verify, swap them in (live -> .bak, verified -> live).
-- Any http/parse failure leaves the existing files untouched: a bad pull never bricks a
-- device, it just runs the code already on disk. update.lua mirrors itself too; the new
-- copy takes effect next boot. `startup` restores any file from its .bak if a swap was
-- interrupted. A logically broken but still-parseable update.lua (e.g. a wrong REPO) would
-- persist across reboots; recover it by hand (wget) since only a working updater can pull
-- its own replacement.

local REPO   = "duzos/computer-craft"
local BRANCH = "main"
local UA     = "cc-fleet-updater"            -- the github api rejects requests with no user-agent

local API = "https://api.github.com/repos/" .. REPO
local RAW = "https://raw.githubusercontent.com/" .. REPO

-- returns body, http status code, response headers; accepts extra request headers
-- (e.g. If-None-Match for a conditional GET). a non-2xx still yields its response
-- handle in CC, so we read the code/headers off that too (304/403 carry no body).
local function httpGet(url, extra)
  if not http then return nil end
  local headers = { ["User-Agent"] = UA }
  if extra then for k, v in pairs(extra) do headers[k] = v end end
  local h, _, errH = http.get(url, headers)
  local resp = h or errH
  if not resp then return nil end
  local code = (resp.getResponseCode and resp.getResponseCode()) or 200
  local hdrs = (resp.getResponseHeaders and resp.getResponseHeaders()) or {}
  local body = resp.readAll()
  resp.close()
  return body, code, hdrs
end

local function getJson(url)
  local body = httpGet(url)
  if not body then return nil end
  local ok, t = pcall(textutils.unserialiseJSON, body)
  if ok and type(t) == "table" then return t end
  return nil
end

local ETAG_FILE = "update.etag"   -- cached {etag, sha} of the last resolved HEAD (gitignored)

local function loadEtag()
  if not fs.exists(ETAG_FILE) then return nil end
  local f = fs.open(ETAG_FILE, "r"); local t = textutils.unserialize(f.readAll()); f.close()
  if type(t) == "table" and type(t.etag) == "string" and type(t.sha) == "string" then return t end
  return nil
end

local function saveEtag(etag, sha)
  local f = fs.open(ETAG_FILE, "w"); f.write(textutils.serialize({ etag = etag, sha = sha })); f.close()
end

local function listLua(sha)
  local t = getJson(API .. "/git/trees/" .. sha .. "?recursive=1")
  if not t or type(t.tree) ~= "table" then return nil end
  local files = {}
  for _, e in ipairs(t.tree) do
    if e.type == "blob" and type(e.path) == "string"
       and e.path:match("%.lua$") and not e.path:find("/") then   -- top-level files only
      files[#files + 1] = e.path
    end
  end
  return files
end

-- non-empty AND parses as Lua. fetching at an immutable commit makes truncation unlikely,
-- and a parse check catches a syntax break before it can overwrite working code.
local function parses(data)
  if type(data) ~= "string" or #data < 1 then return false end
  local loader = loadstring or load
  return loader(data) ~= nil
end

local function readAll(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r"); if not f then return nil end
  local d = f.readAll(); f.close(); return d
end

local function writeAll(path, data)
  local f = fs.open(path, "w"); if not f then return false end
  f.write(data); f.close(); return true
end

local function run()
  if not http then print("update: http disabled; running current code"); return end

  -- resolve HEAD with a conditional GET: an unchanged HEAD answers 304, which is FREE
  -- (does not count against the 60/hr unauthenticated API limit) and lets us skip the
  -- tree + raw fetches entirely. only a moved HEAD (200) costs a real request.
  local cached = loadEtag()
  local body, code, hdrs = httpGet(API .. "/commits/" .. BRANCH,
    cached and { ["If-None-Match"] = cached.etag } or nil)
  if code == 304 and cached then
    print("update: up to date (" .. cached.sha:sub(1, 7) .. ")"); return
  end
  if code == 403 or code == 429 then
    print("update: github rate-limited; running current code"); return
  end
  if not body or code ~= 200 then
    print("update: github unreachable; running current code"); return
  end
  local ok, commit = pcall(textutils.unserialiseJSON, body)
  if not (ok and type(commit) == "table" and type(commit.sha) == "string") then
    print("update: github unreachable; running current code"); return
  end
  local sha  = commit.sha
  local etag = hdrs["ETag"] or hdrs["etag"]

  local files = listLua(sha)
  if not files or #files == 0 then print("update: no file list; running current code"); return end

  -- fetch + verify everything to .new before touching any live file
  local staged = {}
  for _, path in ipairs(files) do
    local data = httpGet(RAW .. "/" .. sha .. "/" .. path)
    if not parses(data) then
      print("update: bad/incomplete " .. path .. "; aborting, running current code")
      for _, p in ipairs(staged) do fs.delete(p .. ".new") end
      return                                 -- abort without caching the etag, so next boot retries
    end
    if data ~= readAll(path) then            -- only stage files that actually changed
      writeAll(path .. ".new", data)
      staged[#staged + 1] = path
    end
  end

  -- commit: back up the old file, move the verified copy into place
  for _, path in ipairs(staged) do
    if fs.exists(path .. ".bak") then fs.delete(path .. ".bak") end
    if fs.exists(path) then fs.move(path, path .. ".bak") end
    fs.move(path .. ".new", path)
  end

  if etag then saveEtag(etag, sha) end       -- record HEAD so the next unchanged boot is a free 304
  if #staged == 0 then print("update: up to date (" .. sha:sub(1, 7) .. ")")
  else print(("update: %d file(s) -> %s"):format(#staged, sha:sub(1, 7))) end
end

run()
