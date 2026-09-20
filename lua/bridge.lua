--[[
  reaper-mcp bridge — runs inside REAPER as a deferred ReaScript.

  Python writes  <ipc>/request.json   {id, func, args|code}
  Lua writes     <ipc>/response.json  {id, ok, ret|error}
  Lua touches    <ipc>/heartbeat      every defer tick
  Lua writes     <ipc>/busy           while dispatch is running (defer cannot tick)

  Load via Actions > Load ReaScript and keep it running.
]]

local VERSION = "0.1.0"
local DEBUG = (os.getenv and os.getenv("REAPER_MCP_DEBUG") == "1") or false

local function log(s)
  if DEBUG then reaper.ShowConsoleMsg(s .. "\n") end
end

local function ipc_dir()
  local env = os.getenv("REAPER_MCP_IPC_DIR")
  if env and env ~= "" then
    local sep = env:find("\\") and "\\" or "/"
    if env:sub(-1) ~= "/" and env:sub(-1) ~= "\\" then env = env .. sep end
    return env
  end
  local appdata = os.getenv("APPDATA")
  if appdata and appdata ~= "" then
    return appdata .. "\\reaper-mcp\\ipc\\"
  end
  local home = os.getenv("HOME") or ""
  local osname = reaper.GetOS()
  if osname:match("OSX") or osname:match("macOS") or osname:match("darwin") then
    return home .. "/Library/Application Support/reaper-mcp/ipc/"
  end
  local xdg = os.getenv("XDG_DATA_HOME")
  if xdg and xdg ~= "" then
    return xdg .. "/reaper-mcp/ipc/"
  end
  return home .. "/.local/share/reaper-mcp/ipc/"
end

local DIR = ipc_dir()
local REQ = DIR .. "request.json"
local RESP = DIR .. "response.json"
local TMP = DIR .. "response.tmp"
local HEART = DIR .. "heartbeat"
local BUSY = DIR .. "busy"

----------------------------------------------------------------------
-- JSON
----------------------------------------------------------------------
local json = {}
do
  local esc = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
  }
  local function esc_str(s)
    return '"' .. s:gsub('[%z\1-\31\\"]', function(c)
      return esc[c] or string.format('\\u%04x', string.byte(c))
    end) .. '"'
  end
  local encode
  local function is_array(t)
    local n = 0
    for k in pairs(t) do
      if type(k) ~= "number" then return false end
      n = n + 1
    end
    return n == #t
  end
  local function forced_object(t)
    local mt = getmetatable(t)
    return mt ~= nil and mt.__jsontype == "object"
  end
  json.userdata_hook = function(_) return nil end
  encode = function(v, seen)
    local tv = type(v)
    if v == nil then return "null"
    elseif tv == "boolean" then return tostring(v)
    elseif tv == "number" then
      if v ~= v or v == math.huge or v == -math.huge then return "null" end
      if v == math.floor(v) and math.abs(v) < 1e15 then
        return string.format("%d", v)
      end
      return string.format("%.10g", v)
    elseif tv == "string" then return esc_str(v)
    elseif tv == "userdata" then return encode(json.userdata_hook(v), seen)
    elseif tv == "table" then
      seen = seen or {}
      if seen[v] then return "null" end
      seen[v] = true
      local out
      if is_array(v) and not forced_object(v) then
        local parts = {}
        for i = 1, #v do parts[i] = encode(v[i], seen) end
        out = "[" .. table.concat(parts, ",") .. "]"
      else
        local parts = {}
        for k, val in pairs(v) do
          parts[#parts + 1] = esc_str(tostring(k)) .. ":" .. encode(val, seen)
        end
        out = "{" .. table.concat(parts, ",") .. "}"
      end
      seen[v] = nil
      return out
    else
      return "null"
    end
  end
  json.encode = function(v) return encode(v, nil) end
  json.object = function(t) return setmetatable(t or {}, { __jsontype = "object" }) end

  local function decode(s, i)
    local function ws(j) return s:find("[^ \t\r\n]", j) or (#s + 1) end
    i = ws(i)
    local c = s:sub(i, i)
    if c == "{" then
      local obj = {}
      i = ws(i + 1)
      if s:sub(i, i) == "}" then return obj, i + 1 end
      while true do
        local key, val
        key, i = decode(s, i)
        i = ws(i)
        assert(s:sub(i, i) == ":", "expected :")
        val, i = decode(s, i + 1)
        obj[key] = val
        i = ws(i)
        local ch = s:sub(i, i)
        if ch == "," then i = i + 1
        elseif ch == "}" then return obj, i + 1
        else error("expected , or }") end
      end
    elseif c == "[" then
      local arr = {}
      i = ws(i + 1)
      if s:sub(i, i) == "]" then return arr, i + 1 end
      while true do
        local val
        val, i = decode(s, i)
        arr[#arr + 1] = val
        i = ws(i)
        local ch = s:sub(i, i)
        if ch == "," then i = i + 1
        elseif ch == "]" then return arr, i + 1
        else error("expected , or ]") end
      end
    elseif c == '"' then
      local buf, j = {}, i + 1
      while true do
        local ch = s:sub(j, j)
        if ch == "" then error("unterminated string") end
        if ch == '"' then return table.concat(buf), j + 1 end
        if ch == "\\" then
          local e = s:sub(j + 1, j + 1)
          local map = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f",
                        ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
          if e == "u" then
            local cp = tonumber(s:sub(j + 2, j + 5), 16) or 0
            if cp < 0x80 then buf[#buf + 1] = string.char(cp)
            elseif cp < 0x800 then
              buf[#buf + 1] = string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
            else
              buf[#buf + 1] = string.char(
                0xE0 + math.floor(cp / 0x1000),
                0x80 + math.floor(cp / 0x40) % 0x40,
                0x80 + cp % 0x40)
            end
            j = j + 6
          else
            buf[#buf + 1] = map[e] or e
            j = j + 2
          end
        else
          buf[#buf + 1] = ch
          j = j + 1
        end
      end
    elseif c:match("[%d%-]") then
      local num = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
      return tonumber(num), i + #num
    elseif s:sub(i, i + 3) == "true" then return true, i + 4
    elseif s:sub(i, i + 4) == "false" then return false, i + 5
    elseif s:sub(i, i + 3) == "null" then return nil, i + 4
    else error("unexpected char at " .. i) end
  end
  json.decode = function(s)
    if not s or s == "" then return nil end
    local ok, v = pcall(function() return decode(s, 1) end)
    if ok then return v else return nil, v end
  end
end

----------------------------------------------------------------------
-- files
----------------------------------------------------------------------
local function read_file(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local c = f:read("*a")
  f:close()
  return c
end

local function write_atomic(final, content, tmp)
  tmp = tmp or (final .. ".tmp")
  local f = io.open(tmp, "wb")
  if not f then return false end
  f:write(content)
  f:close()
  os.remove(final)
  if not os.rename(tmp, final) then
    local g = io.open(final, "wb")
    if g then g:write(content) g:close() end
    os.remove(tmp)
  end
  return true
end

-- Python treats a heartbeat older than REAPER_MCP_HEARTBEAT_STALE (5s) as a dead
-- bridge, so 0.5s is plenty. Rewriting it every defer tick was pure idle I/O.
local HEARTBEAT_INTERVAL = 0.5
local last_heartbeat = -math.huge
local function touch_heartbeat(force)
  local now = reaper.time_precise()
  if not force and (now - last_heartbeat) < HEARTBEAT_INTERVAL then return end
  last_heartbeat = now
  local f = io.open(HEART, "wb")
  if f then f:write(tostring(now)) f:close() end
end

----------------------------------------------------------------------
-- handle registry (userdata round-trip)
----------------------------------------------------------------------
local handles, handle_rev, handle_seq = {}, {}, 0
local function to_handle(ud)
  local key = tostring(ud)
  if handle_rev[key] then return handle_rev[key] end
  handle_seq = handle_seq + 1
  local id = "h" .. handle_seq
  handles[id] = ud
  handle_rev[key] = id
  return id
end
json.userdata_hook = function(ud) return { __handle = to_handle(ud) } end

local function unmarshal(v)
  if type(v) == "table" then
    if v.__handle ~= nil then
      local ud = handles[v.__handle]
      if ud == nil then error("unknown handle: " .. tostring(v.__handle)) end
      return ud
    end
    for k, val in pairs(v) do v[k] = unmarshal(val) end
    return v
  end
  return v
end

----------------------------------------------------------------------
-- DSL
----------------------------------------------------------------------
local function track_at(i)
  if i == -1 then return reaper.GetMasterTrack(0) end
  local t = reaper.GetTrack(0, i)
  if not t then error("no track at index " .. tostring(i)) end
  return t
end

-- Absolute project quarter notes.
local function beats_to_time(b) return reaper.TimeMap2_QNToTime(0, b or 0) end
local function time_to_beats(t) return reaper.TimeMap2_timeToQN(0, t or 0) end

local dispatch
local DSL = {}
local MIDI_FUNCS = {
  add_midi_notes = true, replace_midi_notes = true,
  update_midi_note = true, delete_midi_notes = true,
}

-- A batch used to pay one arrange/timeline/layout refresh per sub-call. Coalesce
-- them: while a batch is running the requests are only recorded, and one real
-- refresh of each kind happens when the outermost batch finishes.
local batch_depth = 0
local pending_arrange, pending_tracks, pending_timeline = false, false, false

local function refresh_arrange()
  if batch_depth > 0 then pending_arrange = true else reaper.UpdateArrange() end
end

local function refresh_tracks()
  if batch_depth > 0 then pending_tracks = true else reaper.TrackList_AdjustWindows(false) end
end

local function refresh_timeline()
  if batch_depth > 0 then pending_timeline = true else reaper.UpdateTimeline() end
end

local function flush_refresh()
  if batch_depth > 0 then return end
  if pending_arrange then pending_arrange = false reaper.UpdateArrange() end
  if pending_tracks then pending_tracks = false reaper.TrackList_AdjustWindows(false) end
  if pending_timeline then pending_timeline = false reaper.UpdateTimeline() end
end

local function vol_db(t)
  local vol = reaper.GetMediaTrackInfo_Value(t, "D_VOL")
  if vol <= 0 then return -150 end
  return 20 * math.log(vol) / math.log(10)
end

function DSL.ping()
  return { ret = { pong = true, version = VERSION, reaper = reaper.GetAppVersion() } }
end

function DSL.get_project_summary()
  local n = reaper.CountTracks(0)
  local tracks = {}
  for i = 0, n - 1 do
    local t = reaper.GetTrack(0, i)
    local _, name = reaper.GetTrackName(t)
    tracks[#tracks + 1] = {
      index = i, name = name, volume_db = vol_db(t),
      mute = reaper.GetMediaTrackInfo_Value(t, "B_MUTE") == 1,
      solo = reaper.GetMediaTrackInfo_Value(t, "I_SOLO") ~= 0,
      item_count = reaper.CountTrackMediaItems(t),
      fx_count = reaper.TrackFX_GetCount(t),
    }
  end
  local _, proj = reaper.EnumProjects(-1, "")
  return { ret = {
    project = proj ~= "" and proj or "(unsaved)",
    tempo_bpm = reaper.Master_GetTempo(),
    play_state = reaper.GetPlayState(),
    cursor_seconds = reaper.GetCursorPosition(),
    track_count = n,
    tracks = tracks,
    ipc = DIR,
  } }
end

function DSL.list_tracks()
  return { ret = DSL.get_project_summary().ret.tracks }
end

function DSL.add_track(name, index)
  index = index or reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(index, true)
  refresh_tracks()
  local t = reaper.GetTrack(0, index)
  if name and name ~= "" then
    reaper.GetSetMediaTrackInfo_String(t, "P_NAME", name, true)
  end
  refresh_arrange()
  return { ret = { index = index, name = name or "" } }
end

function DSL.delete_track(index)
  if index == -1 then error("cannot delete the master track") end
  reaper.DeleteTrack(track_at(index))
  refresh_arrange()
  return { ret = true }
end

function DSL.update_track(index, props)
  local t = track_at(index)
  props = props or {}
  if props.name ~= nil then
    reaper.GetSetMediaTrackInfo_String(t, "P_NAME", tostring(props.name), true)
  end
  if props.volume_db ~= nil then
    reaper.SetMediaTrackInfo_Value(t, "D_VOL", 10 ^ (props.volume_db / 20))
  end
  if props.pan ~= nil then
    reaper.SetMediaTrackInfo_Value(t, "D_PAN", props.pan)
  end
  if props.mute ~= nil then
    reaper.SetMediaTrackInfo_Value(t, "B_MUTE", props.mute and 1 or 0)
  end
  if props.solo ~= nil then
    reaper.SetMediaTrackInfo_Value(t, "I_SOLO", props.solo and 1 or 0)
  end
  refresh_arrange()
  return { ret = true }
end

function DSL.set_tempo(bpm)
  reaper.SetCurrentBPM(0, bpm, true)
  return { ret = bpm }
end

function DSL.set_time_signature(num, denom)
  reaper.SetTempoTimeSigMarker(0, -1, 0, -1, -1, reaper.Master_GetTempo(),
    num, denom, false)
  refresh_timeline()
  return { ret = { num = num, denom = denom } }
end

function DSL.transport(action)
  local cmds = {
    play = 1007, stop = 1016, pause = 1008, record = 1013,
    toggle_repeat = 1068, goto_start = 40042,
  }
  local cmd = cmds[action]
  if not cmd then error("unknown transport action: " .. tostring(action)) end
  reaper.Main_OnCommand(cmd, 0)
  return { ret = { play_state = reaper.GetPlayState(), position = reaper.GetPlayPosition() } }
end

function DSL.action(command_id)
  reaper.Main_OnCommand(tonumber(command_id), 0)
  return { ret = true }
end

function DSL.create_midi_item(ti, start_beats, length_beats)
  local t = track_at(ti)
  local s = beats_to_time(start_beats or 0)
  local e = beats_to_time((start_beats or 0) + (length_beats or 4))
  local item = reaper.CreateNewMIDIItemInProj(t, s, e, false)
  reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", 0)
  -- IP_ITEMNUMBER is the item's index inside its track, so this replaces a scan
  -- of every item on the track. Verify it, since the property is a fallback 0 on
  -- builds that do not know it.
  local idx = math.floor(reaper.GetMediaItemInfo_Value(item, "IP_ITEMNUMBER"))
  if not (idx >= 0 and reaper.GetTrackMediaItem(t, idx) == item) then
    idx = -1
    for i = 0, reaper.CountTrackMediaItems(t) - 1 do
      if reaper.GetTrackMediaItem(t, i) == item then idx = i break end
    end
  end
  refresh_arrange()
  return { ret = {
    item_index = idx, handle = to_handle(item),
    start_beats = start_beats or 0, length_beats = length_beats or 4,
  } }
end

local function midi_take_at(ti, ii)
  local item = reaper.GetTrackMediaItem(track_at(ti), ii)
  if not item then error("no item at index " .. tostring(ii)) end
  local take = reaper.GetActiveTake(item)
  if not take or not reaper.TakeIsMIDI(take) then error("item take is not MIDI") end
  return take
end

local function validate_notes(notes)
  if not notes or #notes == 0 then error("notes array is empty") end
  if #notes > 10000 then error("refusing more than 10000 notes in one call") end
  for i, nt in ipairs(notes) do
    if type(nt) ~= "table" or type(nt.pitch) ~= "number" or type(nt.start_beats) ~= "number" then
      error("note #" .. i .. " needs numeric pitch and start_beats")
    end
  end
end

local function insert_notes(take, notes)
  local count = 0
  for _, nt in ipairs(notes) do
    local sppq = reaper.MIDI_GetPPQPosFromProjQN(take, nt.start_beats)
    local eppq = reaper.MIDI_GetPPQPosFromProjQN(take, nt.start_beats + (nt.length_beats or 1))
    reaper.MIDI_InsertNote(take, false, nt.muted == true, sppq, eppq,
      nt.channel or 0, nt.pitch, nt.velocity or 96, true)
    count = count + 1
  end
  return count
end

local function extend_item_to_notes(take, notes)
  local max_qn
  for _, nt in ipairs(notes or {}) do
    -- Same 1-beat default as insert_notes, so a note without length_beats is
    -- covered by the item extension instead of hanging past its end.
    local e = (nt.start_beats or 0) + (nt.length_beats or 1)
    if not max_qn or e > max_qn then max_qn = e end
  end
  if not max_qn then return false end
  local item = reaper.GetMediaItemTake_Item(take)
  local want_end = reaper.TimeMap2_QNToTime(0, max_qn)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  if want_end > pos + len + 1e-9 then
    reaper.SetMediaItemInfo_Value(item, "D_LENGTH", want_end - pos)
    return true
  end
  return false
end

local function record_item_undo(take, desc)
  -- Begin/EndBlock does not see pure MIDI edits.
  reaper.Undo_OnStateChange_Item(0, desc, reaper.GetMediaItemTake_Item(take))
end

function DSL.add_midi_notes(ti, ii, notes)
  local take = midi_take_at(ti, ii)
  validate_notes(notes)
  local count = insert_notes(take, notes)
  reaper.MIDI_Sort(take)
  local extended = extend_item_to_notes(take, notes)
  record_item_undo(take, "MCP: add MIDI notes")
  refresh_arrange()
  return { ret = { inserted = count, item_extended = extended } }
end

function DSL.get_midi_notes(ti, ii)
  local take = midi_take_at(ti, ii)
  local _, noteCount = reaper.MIDI_CountEvts(take)
  local notes = {}
  for i = 0, noteCount - 1 do
    local _, sel, muted, sppq, eppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
    local sqn = reaper.MIDI_GetProjQNFromPPQPos(take, sppq)
    local eqn = reaper.MIDI_GetProjQNFromPPQPos(take, eppq)
    notes[#notes + 1] = {
      index = i, pitch = pitch, velocity = vel, channel = chan,
      selected = sel, muted = muted,
      start_beats = sqn, length_beats = eqn - sqn,
    }
  end
  return { ret = notes }
end

function DSL.replace_midi_notes(ti, ii, notes)
  local take = midi_take_at(ti, ii)
  validate_notes(notes)
  local _, noteCount = reaper.MIDI_CountEvts(take)
  for i = noteCount - 1, 0, -1 do reaper.MIDI_DeleteNote(take, i) end
  local count = insert_notes(take, notes)
  reaper.MIDI_Sort(take)
  local extended = extend_item_to_notes(take, notes)
  record_item_undo(take, "MCP: replace MIDI notes")
  refresh_arrange()
  return { ret = { inserted = count, item_extended = extended } }
end

function DSL.update_midi_note(ti, ii, note_index, changes)
  local take = midi_take_at(ti, ii)
  local _, noteCount = reaper.MIDI_CountEvts(take)
  if type(note_index) ~= "number" or note_index < 0 or note_index >= noteCount then
    error("no note at index " .. tostring(note_index))
  end
  local _, _, muted, sppq, eppq, chan, pitch, vel = reaper.MIDI_GetNote(take, note_index)
  local ch = changes or {}
  local orig_start_qn = reaper.MIDI_GetProjQNFromPPQPos(take, sppq)
  local start_qn = ch.start_beats or orig_start_qn
  local end_qn = start_qn + (ch.length_beats or (
    reaper.MIDI_GetProjQNFromPPQPos(take, eppq) - orig_start_qn))
  local new_muted = muted
  if ch.muted ~= nil then new_muted = ch.muted and true or false end
  -- noSort here, then one explicit sort below: MIDI_SetNote used to sort as well,
  -- which sorted the whole event list twice per note.
  reaper.MIDI_SetNote(take, note_index, nil, new_muted,
    reaper.MIDI_GetPPQPosFromProjQN(take, start_qn),
    reaper.MIDI_GetPPQPosFromProjQN(take, end_qn),
    ch.channel or chan, ch.pitch or pitch, ch.velocity or vel, true)
  reaper.MIDI_Sort(take)
  record_item_undo(take, "MCP: update MIDI note")
  refresh_arrange()
  return { ret = true }
end

function DSL.delete_midi_notes(ti, ii, indices)
  local take = midi_take_at(ti, ii)
  table.sort(indices, function(a, b) return a > b end)
  for _, i in ipairs(indices) do reaper.MIDI_DeleteNote(take, i) end
  reaper.MIDI_Sort(take)
  record_item_undo(take, "MCP: delete MIDI notes")
  refresh_arrange()
  return { ret = { deleted = #indices } }
end

function DSL.add_track_fx(ti, fx_name)
  local t = track_at(ti)
  local fx = reaper.TrackFX_AddByName(t, fx_name, false, -1)
  if fx < 0 then error("could not add FX: " .. tostring(fx_name)) end
  local _, got = reaper.TrackFX_GetFXName(t, fx, "")
  return { ret = { fx_index = fx, name = got } }
end

function DSL.list_track_fx(ti)
  local t = track_at(ti)
  local out = {}
  for i = 0, reaper.TrackFX_GetCount(t) - 1 do
    local _, name = reaper.TrackFX_GetFXName(t, i, "")
    out[#out + 1] = {
      index = i, name = name,
      enabled = reaper.TrackFX_GetEnabled(t, i),
    }
  end
  return { ret = out }
end

function DSL.get_fx_params(ti, fxi)
  local t = track_at(ti)
  local out = {}
  for i = 0, reaper.TrackFX_GetNumParams(t, fxi) - 1 do
    local _, pn = reaper.TrackFX_GetParamName(t, fxi, i, "")
    local val, mn, mx = reaper.TrackFX_GetParam(t, fxi, i)
    local _, fmt = reaper.TrackFX_GetFormattedParamValue(t, fxi, i, "")
    out[#out + 1] = { index = i, name = pn, value = val, min = mn, max = mx, formatted = fmt }
  end
  return { ret = out }
end

function DSL.set_fx_param(ti, fxi, param, value)
  local t = track_at(ti)
  local pidx = param
  if type(param) == "string" then
    pidx = -1
    for i = 0, reaper.TrackFX_GetNumParams(t, fxi) - 1 do
      local _, pn = reaper.TrackFX_GetParamName(t, fxi, i, "")
      if pn:lower() == param:lower() then pidx = i break end
    end
    if pidx < 0 then error("no param named " .. param) end
  end
  reaper.TrackFX_SetParam(t, fxi, pidx, value)
  local v = reaper.TrackFX_GetParam(t, fxi, pidx)
  return { ret = { param_index = pidx, value = v } }
end

function DSL.delete_track_fx(ti, fxi)
  local t = track_at(ti)
  if not reaper.TrackFX_Delete(t, fxi) then error("could not delete FX " .. tostring(fxi)) end
  return { ret = true }
end

function DSL.set_fx_enabled(ti, fxi, enabled)
  reaper.TrackFX_SetEnabled(track_at(ti), fxi, enabled and true or false)
  return { ret = { enabled = reaper.TrackFX_GetEnabled(track_at(ti), fxi) } }
end

function DSL.move_track_fx(ti, fxi, dest_index)
  local t = track_at(ti)
  if not reaper.TrackFX_CopyToTrack(t, fxi, t, dest_index, true) then
    error("could not move FX")
  end
  return { ret = { fx_index = dest_index } }
end

function DSL.set_fx_preset(ti, fxi, preset)
  local t = track_at(ti)
  if preset and preset ~= "" then
    if not reaper.TrackFX_SetPreset(t, fxi, preset) then
      error("could not set preset: " .. tostring(preset))
    end
  end
  local _, name = reaper.TrackFX_GetPreset(t, fxi, "")
  return { ret = { preset = name } }
end

function DSL.list_sends(ti)
  local t = track_at(ti)
  local out = {}
  local n = reaper.GetTrackNumSends(t, 0)
  for i = 0, n - 1 do
    local dest = reaper.GetTrackSendInfo_Value(t, 0, i, "P_DESTTRACK")
    local dest_index = -1
    if dest then
      if dest == reaper.GetMasterTrack(0) then
        dest_index = -1
      else
        dest_index = math.floor(reaper.GetMediaTrackInfo_Value(dest, "IP_TRACKNUMBER") - 1)
      end
    end
    local vol = reaper.GetTrackSendInfo_Value(t, 0, i, "D_VOL")
    local db = (vol <= 0) and -150 or (20 * math.log(vol) / math.log(10))
    out[#out + 1] = {
      send_index = i,
      dest_index = dest_index,
      volume_db = db,
      pan = reaper.GetTrackSendInfo_Value(t, 0, i, "D_PAN"),
      mute = reaper.GetTrackSendInfo_Value(t, 0, i, "B_MUTE") == 1,
    }
  end
  return { ret = out }
end

function DSL.add_send(ti, dest_index)
  local src = track_at(ti)
  local dest = track_at(dest_index)
  local idx = reaper.CreateTrackSend(src, dest)
  if idx < 0 then error("could not create send") end
  return { ret = { send_index = idx, dest_index = dest_index } }
end

function DSL.delete_send(ti, send_index)
  if not reaper.RemoveTrackSend(track_at(ti), 0, send_index) then
    error("could not delete send")
  end
  return { ret = true }
end

function DSL.update_send(ti, send_index, props)
  local t = track_at(ti)
  props = props or {}
  if props.volume_db ~= nil then
    reaper.SetTrackSendInfo_Value(t, 0, send_index, "D_VOL", 10 ^ (props.volume_db / 20))
  end
  if props.pan ~= nil then
    reaper.SetTrackSendInfo_Value(t, 0, send_index, "D_PAN", props.pan)
  end
  if props.mute ~= nil then
    reaper.SetTrackSendInfo_Value(t, 0, send_index, "B_MUTE", props.mute and 1 or 0)
  end
  return { ret = true }
end

function DSL.list_items(ti)
  local t = track_at(ti)
  local out = {}
  for i = 0, reaper.CountTrackMediaItems(t) - 1 do
    local item = reaper.GetTrackMediaItem(t, i)
    local vol = reaper.GetMediaItemInfo_Value(item, "D_VOL")
    local db = (vol <= 0) and -150 or (20 * math.log(vol) / math.log(10))
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local pos_beats = time_to_beats(pos)
    out[#out + 1] = {
      item_index = i,
      position_beats = pos_beats,
      length_beats = time_to_beats(pos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH"))
        - pos_beats,
      gain_db = db,
      fade_in = reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN"),
      fade_out = reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN"),
      loop = reaper.GetMediaItemInfo_Value(item, "B_LOOPSRC") == 1,
      mute = reaper.GetMediaItemInfo_Value(item, "B_MUTE") == 1,
    }
  end
  return { ret = out }
end

function DSL.update_item(ti, ii, props)
  local item = reaper.GetTrackMediaItem(track_at(ti), ii)
  if not item then error("no item at index " .. tostring(ii)) end
  props = props or {}
  if props.gain_db ~= nil then
    reaper.SetMediaItemInfo_Value(item, "D_VOL", 10 ^ (props.gain_db / 20))
  end
  if props.fade_in ~= nil then
    reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", props.fade_in)
  end
  if props.fade_out ~= nil then
    reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", props.fade_out)
  end
  if props.loop ~= nil then
    reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", props.loop and 1 or 0)
  end
  if props.mute ~= nil then
    reaper.SetMediaItemInfo_Value(item, "B_MUTE", props.mute and 1 or 0)
  end
  if props.position_beats ~= nil then
    reaper.SetMediaItemPosition(item, beats_to_time(props.position_beats), false)
  end
  if props.length_beats ~= nil then
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local pos_b = time_to_beats(pos)
    reaper.SetMediaItemLength(item, beats_to_time(pos_b + props.length_beats) - pos, false)
  end
  refresh_arrange()
  return { ret = true }
end

function DSL.list_envelopes(ti)
  local t = track_at(ti)
  local out = {}
  for i = 0, reaper.CountTrackEnvelopes(t) - 1 do
    local env = reaper.GetTrackEnvelope(t, i)
    local _, name = reaper.GetEnvelopeName(env, "")
    local vis = reaper.GetEnvelopeInfo_Value and reaper.GetEnvelopeInfo_Value(env, "VISIBLE") or 1
    out[#out + 1] = { index = i, name = name, n_points = reaper.CountEnvelopePoints(env) }
  end
  return { ret = out }
end

local function envelope_at(ti, name_or_index)
  local t = track_at(ti)
  if type(name_or_index) == "number" then
    local env = reaper.GetTrackEnvelope(t, name_or_index)
    if not env then error("no envelope at index " .. tostring(name_or_index)) end
    return env
  end
  local env = reaper.GetTrackEnvelopeByName(t, tostring(name_or_index))
  if not env then error("no envelope named " .. tostring(name_or_index)) end
  return env
end

function DSL.get_envelope(ti, name_or_index)
  local env = envelope_at(ti, name_or_index)
  local _, name = reaper.GetEnvelopeName(env, "")
  local pts = {}
  for i = 0, reaper.CountEnvelopePoints(env) - 1 do
    local ok, time, value, shape, tension, selected = reaper.GetEnvelopePoint(env, i)
    if ok then
      pts[#pts + 1] = {
        beats = time_to_beats(time),
        value = value,
        shape = shape,
        tension = tension,
        selected = selected,
      }
    end
  end
  return { ret = { name = name, points = pts } }
end

function DSL.set_envelope(ti, name_or_index, points)
  local env = envelope_at(ti, name_or_index)
  points = points or {}
  reaper.DeleteEnvelopePointRange(env, -math.huge, math.huge)
  for _, p in ipairs(points) do
    reaper.InsertEnvelopePoint(env, beats_to_time(p.beats or p.time or 0),
      p.value or 0, p.shape or 0, p.tension or 0, p.selected and true or false, true)
  end
  reaper.Envelope_SortPoints(env)
  refresh_arrange()
  return { ret = { n_points = reaper.CountEnvelopePoints(env) } }
end

function DSL.set_time_selection(sb, eb)
  reaper.GetSet_LoopTimeRange(true, false, beats_to_time(sb), beats_to_time(eb), false)
  return { ret = { start_beats = sb, end_beats = eb } }
end

function DSL.add_marker(pos_beats, name, is_region, end_beats)
  local idx = reaper.AddProjectMarker2(0, is_region and true or false,
    beats_to_time(pos_beats),
    is_region and beats_to_time(end_beats or pos_beats) or 0,
    name or "", -1, 0)
  refresh_timeline()
  return { ret = { marker_index = idx } }
end

function DSL.render_project(path, opts)
  opts = opts or {}
  if path and path ~= "" then
    reaper.GetSetProjectInfo_String(0, "RENDER_FILE", path, true)
  end
  local bounds = opts.bounds or "project"
  local flag = 1
  if bounds == "custom" then flag = 0
  elseif bounds == "time_selection" then flag = 2
  elseif bounds == "items" then flag = 3
  end
  reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", flag, true)
  if bounds == "custom" then
    reaper.GetSetProjectInfo(0, "RENDER_STARTPOS", beats_to_time(opts.start_beats or 0), true)
    reaper.GetSetProjectInfo(0, "RENDER_ENDPOS", beats_to_time(opts.end_beats or 0), true)
  end
  if opts.sample_rate then
    reaper.GetSetProjectInfo(0, "RENDER_SRATE", opts.sample_rate, true)
  end
  if opts.channels then
    reaper.GetSetProjectInfo(0, "RENDER_CHANNELS", opts.channels, true)
  end
  local settings = 1
  if opts.stems then
    settings = 8
    if opts.track_indices then
      reaper.Main_OnCommand(40297, 0)
      for _, i in ipairs(opts.track_indices) do
        local tr = track_at(i)
        reaper.SetTrackSelected(tr, true)
      end
    end
  end
  reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", settings, true)
  if opts.pattern and opts.pattern ~= "" then
    reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", opts.pattern, true)
  end
  reaper.Main_OnCommand(42230, 0)
  return { ret = { rendered_to = path or "(project render path)", bounds = bounds, stems = opts.stems and true or false } }
end

function DSL.create_bus(name, source_indices)
  local bus_index = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(bus_index, true)
  local bus = reaper.GetTrack(0, bus_index)
  reaper.GetSetMediaTrackInfo_String(bus, "P_NAME", name or "Bus", true)
  reaper.SetMediaTrackInfo_Value(bus, "I_FOLDERCOMPACT", 0)
  for _, i in ipairs(source_indices or {}) do
    local src = track_at(i)
    reaper.CreateTrackSend(src, bus)
  end
  refresh_tracks()
  refresh_arrange()
  return { ret = { index = bus_index, name = name or "Bus" } }
end

function DSL.batch(calls)
  local results = {}
  batch_depth = batch_depth + 1
  local ok, err = pcall(function()
    for i = 1, #(calls or {}) do
      local cok, r = pcall(dispatch, calls[i])
      if cok then results[i] = r
      else results[i] = { ok = false, error = tostring(r) } end
    end
  end)
  batch_depth = batch_depth - 1
  -- Always release the refresh lock, even when the batch blew up halfway.
  flush_refresh()
  if not ok then error(err) end
  return { ret = results }
end

----------------------------------------------------------------------
-- Dispatch
----------------------------------------------------------------------
dispatch = function(req)
  local func = req.func
  if func == "run_lua" then
    local chunk, cerr = load(req.code, "mcp_run_lua", "t",
      setmetatable({ reaper = reaper, json = json, to_handle = to_handle,
                     handles = handles }, { __index = _G }))
    if not chunk then return { ok = false, error = "compile error: " .. tostring(cerr) } end
    local ok, ret = pcall(chunk)
    if not ok then return { ok = false, error = "runtime error: " .. tostring(ret) } end
    return { ok = true, ret = ret }
  end

  local args = req.args or {}
  for i = 1, #args do args[i] = unmarshal(args[i]) end

  if DSL[func] then
    local run = function()
      local res = DSL[func](table.unpack(args))
      res = res or {}
      if res.ok == nil then res.ok = true end
      return res
    end
    if MIDI_FUNCS[func] or func == "batch" or func == "ping"
        or func == "get_project_summary" or func == "list_tracks"
        or func == "get_midi_notes" or func == "list_track_fx"
        or func == "get_fx_params" or func == "list_sends"
        or func == "list_items" or func == "list_envelopes"
        or func == "get_envelope" then
      return run()
    end
    reaper.Undo_BeginBlock()
    local ok, res = pcall(run)
    reaper.Undo_EndBlock("MCP: " .. tostring(func), -1)
    if not ok then error(res) end
    return res
  end

  local fn = reaper[func]
  if type(fn) == "function" then
    local packed = table.pack(pcall(fn, table.unpack(args)))
    if not packed[1] then
      return { ok = false, error = "error calling " .. func .. ": " .. tostring(packed[2]) }
    end
    local rets = {}
    for i = 2, packed.n do rets[#rets + 1] = packed[i] end
    if #rets <= 1 then return { ok = true, ret = rets[1] }
    else return { ok = true, ret = rets } end
  end

  return { ok = false, error = "unknown function: " .. tostring(func) }
end

----------------------------------------------------------------------
-- Main loop
----------------------------------------------------------------------
reaper.RecursiveCreateDirectory(DIR, 0)
os.remove(REQ)
os.remove(RESP)
os.remove(TMP)
os.remove(BUSY)
touch_heartbeat()
reaper.ShowConsoleMsg("reaper-mcp bridge " .. VERSION .. " ready\n  " .. DIR .. "\n")

local function tick()
  touch_heartbeat()
  local raw = read_file(REQ)
  if raw then
    os.remove(REQ)
    local bf = io.open(BUSY, "wb")
    if bf then bf:write("1") bf:close() end
    touch_heartbeat(true)
    if DEBUG then log("REQ: " .. raw) end
    local req, derr = json.decode(raw)
    local resp
    if not req then
      resp = { ok = false, error = "bad request json: " .. tostring(derr) }
    else
      local ok, r = pcall(dispatch, req)
      if ok then resp = r
      else resp = { ok = false, error = "bridge error: " .. tostring(r) } end
      resp.id = req.id
    end
    local out = json.encode(resp)
    if DEBUG then log("RESP: " .. out) end
    write_atomic(RESP, out, TMP)
    os.remove(BUSY)
    touch_heartbeat(true)
  end
  reaper.defer(tick)
end

reaper.defer(tick)
