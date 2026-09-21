--[[
  Minimal fake ReaScript API so lua/bridge.lua can be driven headlessly.

  Written in Lua, not driven from Python, because ReaScript relies on multiple
  return values and lupa does not unpack Python tuples into those.

  Globals exposed for the harness: calls, ticks, tracks, now, ppq, pump().
]]

local PPQ = 960.0
ppq = PPQ
calls = {}
ticks = {}
now = 1000.0
tracks = {}
master = { name = "Master", master = true }

local function hit(k) calls[k] = (calls[k] or 0) + 1 end

local function track(i)
  if i == -1 then return master end
  local t = tracks[i + 1]
  if not t then error("no track at index " .. tostring(i)) end
  return t
end

local function item_at(t, i)
  local it = t.items[i + 1]
  if not it then error("no item at index " .. tostring(i)) end
  return it
end

function pump(n, dt)
  for _ = 1, (n or 1) do
    now = now + (dt or (1 / 60))
    local fn = ticks[#ticks]
    if not fn then break end
    fn()
  end
end

function new_track(name)
  return { name = name or "", items = {}, sends = {}, envelopes = {} }
end

function new_item(pos, len)
  return { position = pos, length = len, notes = {}, ccs = {}, loop = true }
end

reaper = {}

reaper.GetOS = function() return "OSX64" end
reaper.GetAppVersion = function() return "7.99/fake" end
reaper.time_precise = function() return now end
reaper.ShowConsoleMsg = function() hit("ShowConsoleMsg") end
reaper.RecursiveCreateDirectory = function() hit("RecursiveCreateDirectory") end
reaper.defer = function(f) hit("defer") ticks[#ticks + 1] = f end

-- project
reaper.CountTracks = function() return #tracks end
reaper.GetTrack = function(_, i) return track(i) end
reaper.GetMasterTrack = function() return master end
reaper.GetTrackName = function(t) return true, t.name end
reaper.GetMediaTrackInfo_Value = function(t, key)
  hit("GetMediaTrackInfo_Value")
  if key == "D_VOL" then return t.vol or 1.0 end
  if key == "B_MUTE" then return t.mute and 1 or 0 end
  if key == "I_SOLO" then return t.solo and 1 or 0 end
  if key == "IP_TRACKNUMBER" then
    for i, x in ipairs(tracks) do if x == t then return i end end
    return 0
  end
  return 0.0
end
reaper.SetMediaTrackInfo_Value = function(t, key, v)
  hit("SetMediaTrackInfo_Value")
  if key == "D_VOL" then t.vol = v end
  if key == "B_MUTE" then t.mute = (v == 1) end
  if key == "I_SOLO" then t.solo = (v ~= 0) end
end
reaper.GetSetMediaTrackInfo_String = function(t, key, v)
  if key == "P_NAME" then t.name = v end
  return true, t.name
end
reaper.InsertTrackAtIndex = function(i) table.insert(tracks, i + 1, new_track()) end
reaper.DeleteTrack = function(t)
  for i, x in ipairs(tracks) do
    if x == t then table.remove(tracks, i) return end
  end
end
reaper.TrackList_AdjustWindows = function() hit("TrackList_AdjustWindows") end
reaper.UpdateArrange = function() hit("UpdateArrange") end
reaper.UpdateTimeline = function() hit("UpdateTimeline") end
reaper.Main_GetTempo = function() return 120.0 end
reaper.GetPlayState = function() return 0 end
reaper.GetCursorPosition = function() return 0.0 end
reaper.EnumProjects = function() return 0, "" end
reaper.TimeMap2_QNToTime = function(_, qn) return qn * 0.5 end
reaper.TimeMap2_timeToQN = function(_, t) return t / 0.5 end

-- undo
reaper.Undo_BeginBlock = function() hit("Undo_BeginBlock") end
reaper.Undo_EndBlock = function() hit("Undo_EndBlock") end
reaper.Undo_OnStateChange_Item = function() hit("Undo_OnStateChange_Item") end

-- items
reaper.CountTrackMediaItems = function(t) return #t.items end
reaper.GetTrackMediaItem = function(t, i)
  hit("GetTrackMediaItem")
  return t.items[i + 1]
end
reaper.GetMediaItemInfo_Value = function(it, key)
  hit("item." .. tostring(key))
  if key == "D_POSITION" then return it.position end
  if key == "D_LENGTH" then return it.length end
  if key == "D_VOL" then return it.vol or 1.0 end
  if key == "D_FADEINLEN" or key == "D_FADEOUTLEN" then return 0.0 end
  if key == "B_LOOPSRC" then return it.loop and 1 or 0 end
  if key == "B_MUTE" then return it.mute and 1 or 0 end
  if key == "IP_ITEMNUMBER" then
    for _, t in ipairs(tracks) do
      for i, x in ipairs(t.items) do if x == it then return i - 1 end end
    end
    return 0
  end
  return 0.0
end
reaper.SetMediaItemInfo_Value = function(it, key, v)
  hit("SetMediaItemInfo_Value")
  if key == "B_LOOPSRC" then it.loop = (v == 1) end
  if key == "D_LENGTH" then it.length = v end
  if key == "D_POSITION" then it.position = v end
end
reaper.SetMediaItemLength = function(it, v) it.length = v end
reaper.CreateNewMIDIItemInProj = function(t, s, e)
  local it = new_item(s, e - s)
  t.items[#t.items + 1] = it
  return it
end
reaper.GetActiveTake = function(it) return it end
reaper.TakeIsMIDI = function() return true end
reaper.GetMediaItemTake_Item = function(take) return take end

-- MIDI
reaper.MIDI_CountEvts = function(take) return #take.notes, #take.notes, 0, 0 end
reaper.MIDI_GetNote = function(take, i)
  local n = take.notes[i + 1]
  return true, n.sel, n.muted, n.sppq, n.eppq, n.chan, n.pitch, n.vel
end
reaper.MIDI_SetNote = function(take, i, sel, muted, sppq, eppq, chan, pitch, vel, no_sort)
  hit("MIDI_SetNote")
  hit(no_sort and "MIDI_SetNote.noSort" or "MIDI_SetNote.sorted")
  local n = take.notes[i + 1]
  if sel ~= nil then n.sel = sel end
  n.muted, n.sppq, n.eppq = muted, sppq, eppq
  n.chan, n.pitch, n.vel = chan, pitch, vel
end
reaper.MIDI_InsertNote = function(take, sel, muted, sppq, eppq, chan, pitch, vel)
  hit("MIDI_InsertNote")
  take.notes[#take.notes + 1] = { sel = sel, muted = muted, sppq = sppq,
    eppq = eppq, chan = chan, pitch = pitch, vel = vel }
end
reaper.MIDI_DeleteNote = function(take, i)
  hit("MIDI_DeleteNote")
  table.remove(take.notes, i + 1)
end
reaper.MIDI_Sort = function(take)
  hit("MIDI_Sort")
  table.sort(take.notes, function(a, b) return a.sppq < b.sppq end)
end
reaper.MIDI_GetPPQPosFromProjQN = function(_, qn) return qn * PPQ end
reaper.MIDI_GetProjQNFromPPQPos = function(_, ppq) return ppq / PPQ end
reaper.MIDI_InsertCC = function(take, sel, muted, ppq, chanmsg, chan, msg2, msg3)
  hit("MIDI_InsertCC")
  take.ccs = take.ccs or {}
  take.ccs[#take.ccs + 1] = {
    sel = sel, muted = muted, ppq = ppq, chanmsg = chanmsg,
    chan = chan, msg2 = msg2, msg3 = msg3,
  }
end
reaper.SetEditCurPos = function(pos)
  hit("SetEditCurPos")
  cursor = pos
end
reaper.SetTrackSelected = function(t, sel)
  t.selected = sel and true or false
end
reaper.Main_OnCommand = function(id)
  hit("Main_OnCommand")
  if id == 40297 then
    for _, t in ipairs(tracks) do t.selected = false end
  end
end
reaper.InsertMedia = function(path, mode)
  hit("InsertMedia")
  if mode == 1 then
    local t = new_track("imported")
    t.items[1] = new_item(0, 4)
    tracks[#tracks + 1] = t
  else
    local t = tracks[#tracks]
    for _, x in ipairs(tracks) do
      if x.selected then t = x break end
    end
    t.items[#t.items + 1] = new_item(0, 4)
  end
  return true
end
reaper.Main_SaveProject = function(_, force)
  hit("Main_SaveProject")
  saved = { force = force }
end
reaper.Main_SaveProjectEx = function(_, path, flags)
  hit("Main_SaveProjectEx")
  saved = { path = path, flags = flags }
end

-- sends / envelopes / fx
reaper.GetTrackNumSends = function(t) return #t.sends end
reaper.GetTrackSendInfo_Value = function(t, _, i, key)
  local s = t.sends[i + 1]
  if key == "D_VOL" then return s.vol or 1.0 end
  if key == "D_PAN" then return s.pan or 0.0 end
  if key == "B_MUTE" then return s.mute and 1 or 0 end
  if key == "P_DESTTRACK" then return s.dest end
  return 0
end
reaper.CountTrackEnvelopes = function(t) return #t.envelopes end
reaper.GetTrackEnvelope = function(t, i) return t.envelopes[i + 1] end
reaper.GetEnvelopeName = function() return true, "Volume" end
reaper.CountEnvelopePoints = function(env) return #env.points end
reaper.GetEnvelopePoint = function(env, i)
  local p = env.points[i + 1]
  return true, p[1], p[2], 0, 0, false
end
reaper.TrackFX_GetCount = function() return 0 end

-- Count heartbeat writes without touching the real API.
local real_open = io.open
io.open = function(p, mode)
  if mode == "wb" and p:match("heartbeat$") then hit("heartbeat_writes") end
  return real_open(p, mode)
end
