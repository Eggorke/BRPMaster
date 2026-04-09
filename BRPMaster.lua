-------------------------------------------------------------------------------
-- BRPMaster.lua  v1.0
-- Beluga Raid Points — unified addon
-- Replaces: BRPBT (ML bid window) + BRPBidHelper (player bid window)
-- Adds:     Award button with auto 2nd-price, DKP deduction, EP award cmds
-------------------------------------------------------------------------------

-- ── Constants ──────────────────────────────────────────────────────────────
local MSG = {
  PREFIX  = "BRPBT",          -- addon msg prefix (compat w/ existing)
  DATA    = "get data",
  SET_ML  = "ML set to ",
  TIME    = "Roll time set to ",
  TABLE   = "Table set to ",
}

local FONT       = "Fonts\\FRIZQT__.TTF"
local FONT_MONO  = "Interface\\AddOns\\BRPMaster\\Fonts\\MonaspaceNeonFrozen-Regular.ttf"
local FS         = 11
local TABLE_EP_NAME = "NAXX"   -- rename here to change all EP/NAXX labels
local TABLE_GP_NAME = "KARA"   -- rename here to change all GP/KARA labels

local MIN_BID    = 10
local MAX_LOG_ENTRIES = 2000
local MAX_ROWS   = 10
local ROW_H      = 22
local HEADER_H   = 90    -- item icon + name area
local COLHDR_H   = 22    -- column header row
local FOOTER_H   = 36
local ML_W       = 482
local ML_H       = HEADER_H + COLHDR_H + (MAX_ROWS * ROW_H) + FOOTER_H + 40

-- Column X positions (relative to row left edge, left pad = 8)
local COL = { NAME=8, RANK=120, EP=204, GP=262, BID=322, AWD=380 }

local CLS = {
  Warrior="FFC79C6E", Mage="FF69CCF0", Rogue="FFFFF569",
  Druid="FFFF7D0A",  Hunter="FFABD473", Shaman="FF0070DE",
  Priest="FFFFFFFF", Warlock="FF9482C9", Paladin="FFF58CBA",
}

-- ── Saved variables / persistent state ─────────────────────────────────────
BRPMasterDB = BRPMasterDB or {}

-- ── Runtime state ───────────────────────────────────────────────────────────
local st = {
  ml          = nil,      -- master looter name (string)
  item        = nil,      -- bare item link "item:XXXX:0:0:0"
  itemFull    = nil,      -- full colored link for chat
  itemName    = nil,      -- plain item name
  bids        = {},       -- sorted array of bid entries
  bidSet      = {},       -- [name]=true for dedup
  activeTable = "EP",     -- "EP"=TABLE_EP_NAME  "GP"=TABLE_GP_NAME
  duration    = 30,
  elapsed     = 0,
  rolling     = false,
  -- pending award (used by static popup)
  awardName      = nil,
  awardCost      = nil,
  pendingDecay   = nil,
  -- settings
  announceChannel = "RAID_WARNING",
  defaultDecay    = 20,
  nextLogId       = 1,
  -- pending ML request (delayed)
  pendReq     = false,
  reqDelay    = 0,
  pendSet     = false,
  setDelay    = 0,
  setName     = "",
}

-- Guild cache: rebuilt on GUILD_ROSTER_UPDATE
-- [name] = { ep, gp, gIdx, note, rank, rankIdx, class }
local cache = {}
local logViewerFrame
local logExportFrame
local standingsExportFrame
local UpdateLogRows

local function TableDisplayName(tableKey)
  return (tableKey == "EP") and TABLE_EP_NAME or TABLE_GP_NAME
end

-- ── Utility ─────────────────────────────────────────────────────────────────
local function Pr(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cFFEDD8BB[BRP]|r " .. (msg or "nil"))
end

local function CC(name, class)
  local hex = CLS[class] or "FFFFFFFF"
  return "|c"..hex..name.."|r"
end

local function ExtractLinks(msg)
  local t = {}
  for link in string.gfind(msg, "|c.-|H(item:.-)|h.-|h|r") do
    table.insert(t, link)
  end
  return t
end

local function ExtractFullLinks(msg)
  local t = {}
  for link in string.gfind(msg, "|c.-%|Hitem:.-%|h.-%|h%|r") do
    table.insert(t, link)
  end
  return t
end

local function Announce(msg)
  local ch = st.announceChannel
  if ch == "NONE" then return end
  if (ch == "RAID_WARNING" or ch == "RAID") and GetNumRaidMembers() == 0 then
    ch = "GUILD"
  end
  SendChatMessage(msg, ch)
end

local function IsNumber(s) return tonumber(s) ~= nil end

local function EnsureDB()
  BRPMasterDB = BRPMasterDB or {}
  BRPMasterDB.logs = BRPMasterDB.logs or {}
  BRPMasterDB.logMeta = BRPMasterDB.logMeta or {}
  BRPMasterDB.raidAwardDefaults = BRPMasterDB.raidAwardDefaults or {}
  if not BRPMasterDB.raidAwardDefaults.EP then BRPMasterDB.raidAwardDefaults.EP = 10 end
  if not BRPMasterDB.raidAwardDefaults.GP then BRPMasterDB.raidAwardDefaults.GP = 10 end
  if not BRPMasterDB.logMeta.nextId or BRPMasterDB.logMeta.nextId < 1 then
    BRPMasterDB.logMeta.nextId = 1
  end
  if not BRPMasterDB.logMeta.maxEntries or BRPMasterDB.logMeta.maxEntries < 50 then
    BRPMasterDB.logMeta.maxEntries = MAX_LOG_ENTRIES
  end
  st.nextLogId = BRPMasterDB.logMeta.nextId
end

local function TrimLogs()
  local logs = BRPMasterDB.logs
  local maxEntries = BRPMasterDB.logMeta.maxEntries or MAX_LOG_ENTRIES
  while table.getn(logs) > maxEntries do
    table.remove(logs, 1)
  end
end

local function NextLogId()
  local id = st.nextLogId or 1
  st.nextLogId = id + 1
  BRPMasterDB.logMeta.nextId = st.nextLogId
  return id
end

local function NewBatchId(prefix)
  return string.format("%s_%d_%d", prefix or "batch", time(), math.random(1000, 9999))
end

local function AddLogEntry(entry)
  EnsureDB()
  entry.id = entry.id or NextLogId()
  entry.ts = entry.ts or time()
  entry.dateText = entry.dateText or date("%Y-%m-%d %H:%M:%S", entry.ts)
  table.insert(BRPMasterDB.logs, entry)
  TrimLogs()
  if logViewerFrame and logViewerFrame:IsVisible() and UpdateLogRows then
    UpdateLogRows()
  end
end

local function GetLogEntries()
  EnsureDB()
  return BRPMasterDB.logs
end

local function EscapeForJson(s)
  s = tostring(s or "")
  s = string.gsub(s, "\\", "\\\\")
  s = string.gsub(s, "\"", "\\\"")
  s = string.gsub(s, "\r", "\\r")
  s = string.gsub(s, "\n", "\\n")
  return s
end

local function SerializeLogValue(v)
  local t = type(v)
  if t == "nil" then return "null" end
  if t == "number" then return tostring(v) end
  if t == "boolean" then return v and "true" or "false" end
  return "\"" .. EscapeForJson(v) .. "\""
end

local function SerializeMeta(meta)
  if type(meta) ~= "table" then return "{}" end
  local parts = {}
  for k, v in pairs(meta) do
    table.insert(parts, string.format("\"%s\":%s", EscapeForJson(k), SerializeLogValue(v)))
  end
  return "{"..table.concat(parts, ",").."}"
end

local function GetGuildName()
  if type(GetGuildInfo) == "function" then
    local guildName = GetGuildInfo("player")
    if guildName then return guildName end
  end
  return ""
end

local function ExportLogsAsJson(pretty)
  local logs = GetLogEntries()
  local total = table.getn(logs)
  local lines = {"["}
  for i = 1, table.getn(logs) do
    local e = logs[i]
    local tableSlot = nil
    if e.tableKey == "EP" then
      tableSlot = "DKP1"
    elseif e.tableKey == "GP" then
      tableSlot = "DKP2"
    end
    local row = {
      string.format("\"id\":%d", e.id or 0),
      string.format("\"ts\":%d", e.ts or 0),
      string.format("\"dateText\":%s", SerializeLogValue(e.dateText)),
      string.format("\"kind\":%s", SerializeLogValue(e.kind)),
      string.format("\"actor\":%s", SerializeLogValue(e.actor)),
      string.format("\"target\":%s", SerializeLogValue(e.target)),
      string.format("\"scope\":%s", SerializeLogValue(e.scope)),
      string.format("\"batchId\":%s", SerializeLogValue(e.batchId)),
      string.format("\"reason\":%s", SerializeLogValue(e.reason)),
      string.format("\"tableKey\":%s", SerializeLogValue(e.tableKey)),
      string.format("\"tableName\":%s", SerializeLogValue(e.tableName)),
      string.format("\"tableSlot\":%s", SerializeLogValue(tableSlot)),
      string.format("\"delta\":%s", SerializeLogValue(e.delta)),
      string.format("\"before\":%s", SerializeLogValue(e.before)),
      string.format("\"after\":%s", SerializeLogValue(e.after)),
      string.format("\"beforeEP\":%s", SerializeLogValue(e.beforeEP)),
      string.format("\"afterEP\":%s", SerializeLogValue(e.afterEP)),
      string.format("\"deltaEP\":%s", SerializeLogValue(e.deltaEP)),
      string.format("\"beforeGP\":%s", SerializeLogValue(e.beforeGP)),
      string.format("\"afterGP\":%s", SerializeLogValue(e.afterGP)),
      string.format("\"deltaGP\":%s", SerializeLogValue(e.deltaGP)),
      string.format("\"beforeDKP1\":%s", SerializeLogValue(e.beforeEP)),
      string.format("\"afterDKP1\":%s", SerializeLogValue(e.afterEP)),
      string.format("\"deltaDKP1\":%s", SerializeLogValue(e.deltaEP)),
      string.format("\"beforeDKP2\":%s", SerializeLogValue(e.beforeGP)),
      string.format("\"afterDKP2\":%s", SerializeLogValue(e.afterGP)),
      string.format("\"deltaDKP2\":%s", SerializeLogValue(e.deltaGP)),
      string.format("\"itemLink\":%s", SerializeLogValue(e.itemLink)),
      string.format("\"itemName\":%s", SerializeLogValue(e.itemName)),
      string.format("\"meta\":%s", SerializeMeta(e.meta)),
    }
    local suffix = (i < total) and "," or ""
    if pretty then
      table.insert(lines, "  {"..table.concat(row, ",").."}"..suffix)
    else
      table.insert(lines, "{"..table.concat(row, ",").."}"..suffix)
    end
  end
  table.insert(lines, "]")
  if pretty then
    return table.concat(lines, "\n")
  end
  return table.concat(lines, "")
end

-- ── EPGP — note I/O ─────────────────────────────────────────────────────────
local function ParseNote(note)
  if not note or note == "" then return nil, nil end
  local _, _, ep, gp = string.find(note, "{(%d+):(%d+)}")
  return tonumber(ep), tonumber(gp)
end

local function WriteNote(oldNote, newEp, newGp)
  local patch = string.format("{%d:%d}", newEp, newGp)
  local result, n = string.gsub(oldNote or "", "{%d+:%d+}", patch)
  if n == 0 then result = (oldNote or "") .. patch end
  return result
end

local function SaveMemberState(m, newEp, newGp)
  m.ep = math.max(0, newEp)
  m.gp = math.max(0, newGp)
  m.note = WriteNote(m.note, m.ep, m.gp)
  GuildRosterSetOfficerNote(m.gIdx, m.note)
end

-- ── Guild cache ─────────────────────────────────────────────────────────────
local function BuildCache(includeOffline)
  if includeOffline and
     type(GetGuildRosterShowOffline) == "function" and
     type(SetGuildRosterShowOffline) == "function" then
    if not GetGuildRosterShowOffline() then
      SetGuildRosterShowOffline(1)
      -- Force roster APIs to use the full guild list even if the Guild UI hides offline members.
      GetGuildRosterInfo(0)
    end
  end

  cache = {}
  local n
  if includeOffline then
    n = GetNumGuildMembers(1) or GetNumGuildMembers()
  else
    n = GetNumGuildMembers()
  end
  if n then
    for i = 1, n do
      local name, rank, rIdx, _, class, _, _, note = GetGuildRosterInfo(i)
      if name then
        local ep, gp = ParseNote(note)
        cache[name] = {
          ep=ep or 0, gp=gp or 0, gIdx=i,
          note=note or "", rank=rank or "",
          rankIdx=rIdx or 99, class=class or "",
        }
      end
    end
  end

end

-- ── EPGP modification ───────────────────────────────────────────────────────
local function BuildStandingsList(includeOffline)
  if includeOffline then
    BuildCache(true)
  end

  local list = {}
  for name, m in pairs(cache) do
    table.insert(list, {
      name = name,
      class = m.class or "",
      rank = m.rank or "",
      rankIdx = m.rankIdx or 99,
      ep = m.ep or 0,
      gp = m.gp or 0,
    })
  end

  table.sort(list, function(a, b)
    if a.ep ~= b.ep then return a.ep > b.ep end
    if a.gp ~= b.gp then return a.gp > b.gp end
    return string.lower(a.name or "") < string.lower(b.name or "")
  end)

  return list
end

local function ExportStandingsAsJson(pretty)
  local ts = time()
  local list = BuildStandingsList(true)
  local lines
  if pretty then
    lines = {
      "{",
      string.format("  \"schemaVersion\":%d,", 1),
      string.format("  \"exportedAt\":%d,", ts),
      string.format("  \"exportedAtText\":%s,", SerializeLogValue(date("%Y-%m-%d %H:%M:%S", ts))),
      string.format("  \"exportedBy\":%s,", SerializeLogValue(UnitName("player"))),
      string.format("  \"guildName\":%s,", SerializeLogValue(GetGuildName())),
      "  \"tableNames\":{",
      string.format("    \"DKP1\":%s,", SerializeLogValue(TABLE_EP_NAME)),
      string.format("    \"DKP2\":%s", SerializeLogValue(TABLE_GP_NAME)),
      "  },",
      "  \"members\":[",
    }
  else
    lines = {
      "{",
      string.format("\"schemaVersion\":%d,", 1),
      string.format("\"exportedAt\":%d,", ts),
      string.format("\"exportedAtText\":%s,", SerializeLogValue(date("%Y-%m-%d %H:%M:%S", ts))),
      string.format("\"exportedBy\":%s,", SerializeLogValue(UnitName("player"))),
      string.format("\"guildName\":%s,", SerializeLogValue(GetGuildName())),
      "\"tableNames\":{",
      string.format("\"DKP1\":%s,", SerializeLogValue(TABLE_EP_NAME)),
      string.format("\"DKP2\":%s", SerializeLogValue(TABLE_GP_NAME)),
      "},",
      "\"members\":[",
    }
  end

  for i = 1, table.getn(list) do
    local m = list[i]
    local suffix = (i < table.getn(list)) and "," or ""
    if pretty then
      table.insert(lines,
        string.format(
          "    {\"name\":%s,\"class\":%s,\"rank\":%s,\"rankIndex\":%s,\"dkp1\":%s,\"dkp2\":%s}%s",
          SerializeLogValue(m.name),
          SerializeLogValue(m.class),
          SerializeLogValue(m.rank),
          SerializeLogValue(m.rankIdx),
          SerializeLogValue(m.ep),
          SerializeLogValue(m.gp),
          suffix
        )
      )
    else
      table.insert(lines,
        string.format(
          "{\"name\":%s,\"class\":%s,\"rank\":%s,\"rankIndex\":%s,\"dkp1\":%s,\"dkp2\":%s}%s",
          SerializeLogValue(m.name),
          SerializeLogValue(m.class),
          SerializeLogValue(m.rank),
          SerializeLogValue(m.rankIdx),
          SerializeLogValue(m.ep),
          SerializeLogValue(m.gp),
          suffix
        )
      )
    end
  end

  if pretty then
    table.insert(lines, "  ]")
  else
    table.insert(lines, "]")
  end
  table.insert(lines, "}")
  if pretty then
    return table.concat(lines, "\n")
  end
  return table.concat(lines, "")
end

local function ApplyDKPChange(name, tableKey, delta, context)
  local m = cache[name]
  if not m then
    Pr("Not found: "..name)
    return nil
  end
  local before = (tableKey == "EP") and m.ep or m.gp
  local newEp, newGp = m.ep, m.gp
  if tableKey == "EP" then
    newEp = math.max(0, before + delta)
  else
    newGp = math.max(0, before + delta)
  end
  SaveMemberState(m, newEp, newGp)
  local after = (tableKey == "EP") and newEp or newGp
  AddLogEntry({
    kind = (context and context.kind) or "player_adjust",
    actor = (context and context.actor) or UnitName("player"),
    target = name,
    scope = (context and context.scope) or "single",
    batchId = context and context.batchId or nil,
    reason = context and context.reason or nil,
    tableKey = tableKey,
    tableName = TableDisplayName(tableKey),
    delta = after - before,
    before = before,
    after = after,
    itemLink = context and context.itemLink or nil,
    itemName = context and context.itemName or nil,
    meta = context and context.meta or nil,
  })
  return { before = before, after = after, delta = after - before, class = m.class }
end

local function ApplyDecayToPlayer(name, factor, batchId, pct)
  local m = cache[name]
  if not m then return nil end
  local beforeEp, beforeGp = m.ep, m.gp
  local newEp = math.max(0, math.floor(beforeEp * factor + 0.5))
  local newGp = math.max(0, math.floor(beforeGp * factor + 0.5))
  if newEp < 5 then newEp = 0 end
  if newGp < 5 then newGp = 0 end
  if newEp == beforeEp and newGp == beforeGp then
    return nil
  end
  SaveMemberState(m, newEp, newGp)
  AddLogEntry({
    kind = "decay",
    actor = UnitName("player"),
    target = name,
    scope = "guild",
    batchId = batchId,
    reason = "Guild decay",
    beforeEP = beforeEp,
    afterEP = newEp,
    deltaEP = newEp - beforeEp,
    beforeGP = beforeGp,
    afterGP = newGp,
    deltaGP = newGp - beforeGp,
    meta = { decayPct = pct },
  })
  return true
end

local function AwardRaidEP(amount, whichTable)
  local batchId = NewBatchId("raid")
  local count = 0
  for i = 1, GetNumRaidMembers() do
    local name = GetRaidRosterInfo(i)
    if name and cache[name] then
      if ApplyDKPChange(name, whichTable, amount, {
        kind = "raid_award",
        scope = "raid",
        batchId = batchId,
        reason = "Raid award",
        meta = { raidCount = GetNumRaidMembers() },
      }) then
        count = count + 1
      end
    end
  end
  local tName = (whichTable == "EP") and TABLE_EP_NAME or TABLE_GP_NAME
  Pr(string.format("Awarded %d %s DKP to %d raid members.", amount, tName, count))
  local ch = GetNumRaidMembers() > 0 and "RAID" or "SAY"
  SendChatMessage(string.format("[BRP] %d %s DKP awarded to raid.", amount, tName), ch)
end

local function DecayAll(factor)
  -- factor = fraction to KEEP, e.g. 0.8 = 20% decay
  BuildCache(true)
  local pct = math.floor((1 - factor) * 100 + 0.5)
  local batchId = NewBatchId("decay")
  local count = 0
  for name, m in pairs(cache) do
    if m.ep > 0 or m.gp > 0 then
      if ApplyDecayToPlayer(name, factor, batchId, pct) then
        count = count + 1
      end
    end
  end
  Pr(string.format("Decay %d pct applied to %d members.", pct, count))
  SendChatMessage(string.format("[BRP] %d pct DKP decay applied to all members.", pct), "GUILD")
end

-- ── Bid management ──────────────────────────────────────────────────────────
local function ResetBids()
  st.bids  = {}
  st.bidSet = {}
end

local function AddBid(name, amount)
  local m = cache[name]; if not m then return end
  if st.bidSet[name] then
    for _, b in ipairs(st.bids) do
      if b.name == name then
        if amount > b.bid then b.bid = amount end
        return
      end
    end
  end
  st.bidSet[name] = true
  table.insert(st.bids, {
    name=name, bid=amount, class=m.class,
    rank=m.rank, rankIdx=m.rankIdx,
    ep=m.ep, gp=m.gp,
  })
end

local function SortBids()
  table.sort(st.bids, function(a, b) return a.bid > b.bid end)
end

local function WinCost()
  SortBids()
  local n = table.getn(st.bids)
  if n == 0 then return MIN_BID end
  if n == 1 then return MIN_BID end
  return st.bids[2].bid + 1
end

-- ── Master Looter detection ──────────────────────────────────────────────────
local function GetMLName()
  local method, pid = GetLootMethod()
  if method == "master" and pid then
    if pid == 0 then return UnitName("player") end
    return UnitName("party"..pid)
  end
  return nil
end

local function PlayerIsML()
  return GetMLName() == UnitName("player")
end

local function SendMLInfo(ml)
  if not ml then return end
  local ch = GetNumRaidMembers() > 0 and "RAID" or "PARTY"
  SendAddonMessage(MSG.PREFIX, MSG.SET_ML..ml, ch)
  if ml == UnitName("player") then
    SendAddonMessage(MSG.PREFIX, MSG.TIME..st.duration, ch)
    SendAddonMessage(MSG.PREFIX, MSG.TABLE..st.activeTable, ch)
  end
end

local function ReqML(delay)
  st.pendReq  = true
  st.reqDelay = delay or 2
end

-- ── Award ────────────────────────────────────────────────────────────────────
local function DoAward(winnerName, cost)
  local tableKey = st.activeTable
  local result = ApplyDKPChange(winnerName, tableKey, -cost, {
    kind = "loot",
    scope = "single",
    reason = "Loot award",
    itemLink = st.itemFull or st.item,
    itemName = st.itemName,
  })
  if not result then return end
  local tName = (st.activeTable == "EP") and TABLE_EP_NAME or TABLE_GP_NAME
  local iDisplay = st.itemFull or ("["..(st.itemName or "item").."]")
  local msg = string.format("%s wins %s for %d %s DKP",
    winnerName, iDisplay, cost, tName)
  Announce(msg)
  Pr("Note updated for "..winnerName.." (-"..cost.." "..tName..").")
  ResetBids()
  -- mlFrame is declared later, hide via upvalue
  if mlFrame then
    mlFrame:Hide()
  end
end

-- Popups for minimap menu actions
local function PopupGetText(dlg)
  -- In WoW 1.12, OnAccept fires with `this` = the button (e.g. "StaticPopup3Button1"),
  -- not the dialog frame. Strip the trailing "Button<n>" to get the base frame name.
  local base = string.gsub((dlg:GetName() or ""), "Button%d+$", "")
  local eb = getglobal(base.."EditBox")
  return eb and eb:GetText() or ""
end

local function GetRaidAwardDefault(tableKey)
  EnsureDB()
  local v = BRPMasterDB.raidAwardDefaults and BRPMasterDB.raidAwardDefaults[tableKey]
  if type(v) ~= "number" then return 10 end
  return v
end

local function SetRaidAwardDefault(tableKey, amount)
  if type(amount) ~= "number" then return end
  EnsureDB()
  BRPMasterDB.raidAwardDefaults[tableKey] = amount
end

local function SetPopupEditBoxValue(popupFrame, value)
  if not popupFrame then return end
  local eb = getglobal((popupFrame:GetName() or "").."EditBox")
  if not eb then return end
  eb:SetText(tostring(value))
  eb:SetFocus()
  eb:HighlightText()
end

-- Static popup for award confirmation
StaticPopupDialogs["BRP_CONFIRM_AWARD"] = {
  text = "Confirm award?",
  button1 = "Award",
  button2 = "Cancel",
  hasEditBox = true,
  OnAccept = function()
    if st.awardName then
      local cost = tonumber(PopupGetText(this)) or st.awardCost
      if cost and cost > 0 then
        DoAward(st.awardName, cost)
      end
      st.awardName = nil
      st.awardCost = nil
    end
  end,
  EditBoxOnEnterPressed = function()
    if st.awardName then
      local cost = tonumber(this:GetText()) or st.awardCost
      if cost and cost > 0 then
        DoAward(st.awardName, cost)
        st.awardName = nil
        st.awardCost = nil
      end
    end
    StaticPopup_Hide("BRP_CONFIRM_AWARD")
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 4,
}

StaticPopupDialogs["BRP_EP_RAID"] = {
  text = "Award "..TABLE_EP_NAME.." DKP to raid:\n(enter amount)",
  button1 = "Award", button2 = "Cancel",
  hasEditBox = true,
  OnShow = function()
    SetPopupEditBoxValue(this, GetRaidAwardDefault("EP"))
  end,
  OnAccept = function()
    local amt = tonumber(PopupGetText(this))
    if amt and amt ~= 0 then
      SetRaidAwardDefault("EP", amt)
      AwardRaidEP(amt, "EP")
    end
  end,
  EditBoxOnEnterPressed = function()
    local amt = tonumber(this:GetText())
    if amt and amt ~= 0 then
      SetRaidAwardDefault("EP", amt)
      AwardRaidEP(amt, "EP")
    end
    StaticPopup_Hide("BRP_EP_RAID")
  end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs["BRP_GP_RAID"] = {
  text = "Award "..TABLE_GP_NAME.." DKP to raid:\n(enter amount)",
  button1 = "Award", button2 = "Cancel",
  hasEditBox = true,
  OnShow = function()
    SetPopupEditBoxValue(this, GetRaidAwardDefault("GP"))
  end,
  OnAccept = function()
    local amt = tonumber(PopupGetText(this))
    if amt and amt ~= 0 then
      SetRaidAwardDefault("GP", amt)
      AwardRaidEP(amt, "GP")
    end
  end,
  EditBoxOnEnterPressed = function()
    local amt = tonumber(this:GetText())
    if amt and amt ~= 0 then
      SetRaidAwardDefault("GP", amt)
      AwardRaidEP(amt, "GP")
    end
    StaticPopup_Hide("BRP_GP_RAID")
  end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs["BRP_EP_PLAYER"] = {
  text = "Modify "..TABLE_EP_NAME.." DKP for player:\n(e.g.  Eggorkus 100  or  Eggorkus -50)",
  button1 = "Apply", button2 = "Cancel",
  hasEditBox = true,
  OnAccept = function()
    local txt = PopupGetText(this)
    local _, _, name, amt = string.find(txt, "^(%S+)%s+(-?%d+)$")
    if name and amt then
      name = string.upper(string.sub(name,1,1))..string.sub(name,2)
      if ApplyDKPChange(name, "EP", tonumber(amt), { reason = "Manual popup adjust" }) then
        Pr(name.." "..TABLE_EP_NAME.." DKP "..(tonumber(amt) >= 0 and "+" or "")..amt)
      end
    else
      Pr("Format: Name Amount  (e.g. Eggorkus 100)")
    end
  end,
  EditBoxOnEnterPressed = function()
    local txt = this:GetText()
    local _, _, name, amt = string.find(txt, "^(%S+)%s+(-?%d+)$")
    if name and amt then
      name = string.upper(string.sub(name,1,1))..string.sub(name,2)
      if ApplyDKPChange(name, "EP", tonumber(amt), { reason = "Manual popup adjust" }) then
        Pr(name.." "..TABLE_EP_NAME.." DKP "..(tonumber(amt) >= 0 and "+" or "")..amt)
      end
    else
      Pr("Format: Name Amount  (e.g. Eggorkus 100)")
    end
    StaticPopup_Hide("BRP_EP_PLAYER")
  end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs["BRP_GP_PLAYER"] = {
  text = "Modify "..TABLE_GP_NAME.." DKP for player:\n(e.g.  Eggorkus 100  or  Eggorkus -50)",
  button1 = "Apply", button2 = "Cancel",
  hasEditBox = true,
  OnAccept = function()
    local txt = PopupGetText(this)
    local _, _, name, amt = string.find(txt, "^(%S+)%s+(-?%d+)$")
    if name and amt then
      name = string.upper(string.sub(name,1,1))..string.sub(name,2)
      if ApplyDKPChange(name, "GP", tonumber(amt), { reason = "Manual popup adjust" }) then
        Pr(name.." "..TABLE_GP_NAME.." DKP "..(tonumber(amt) >= 0 and "+" or "")..amt)
      end
    else
      Pr("Format: Name Amount  (e.g. Eggorkus 100)")
    end
  end,
  EditBoxOnEnterPressed = function()
    local txt = this:GetText()
    local _, _, name, amt = string.find(txt, "^(%S+)%s+(-?%d+)$")
    if name and amt then
      name = string.upper(string.sub(name,1,1))..string.sub(name,2)
      if ApplyDKPChange(name, "GP", tonumber(amt), { reason = "Manual popup adjust" }) then
        Pr(name.." "..TABLE_GP_NAME.." DKP "..(tonumber(amt) >= 0 and "+" or "")..amt)
      end
    else
      Pr("Format: Name Amount  (e.g. Eggorkus 100)")
    end
    StaticPopup_Hide("BRP_GP_PLAYER")
  end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs["BRP_CONFIRM_DECAY"] = {
  text = "Confirm decay?",
  button1 = "Apply", button2 = "Cancel",
  enterClicksFirstButton = 1,
  OnAccept = function()
    if st.pendingDecay then
      DecayAll(1 - (st.pendingDecay / 100))
      st.pendingDecay = nil
    end
  end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- ── UI helpers ───────────────────────────────────────────────────────────────
local function MakeBackdrop(frame, r, g, b, a)
  frame:SetBackdrop({
    bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    tile=true, tileSize=16, edgeSize=16,
    insets={ left=4, right=4, top=4, bottom=4 },
  })
  frame:SetBackdropColor(r or 0, g or 0, b or 0, a or 0.92)
end

local function MakeCloseBtn(frame, onClose)
  local btn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  btn:SetWidth(24); btn:SetHeight(24)
  btn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
  btn:SetNormalTexture("Interface/Buttons/UI-Panel-MinimizeButton-Up")
  btn:SetPushedTexture("Interface/Buttons/UI-Panel-MinimizeButton-Down")
  btn:SetHighlightTexture("Interface/Buttons/UI-Panel-MinimizeButton-Highlight")
  btn:SetScript("OnClick", function()
    frame:Hide()
    if onClose then onClose() end
  end)
end

local function MakeLabel(parent, text, x, y, w, justify, fsize, r, g, b)
  local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  fs:SetFont(FONT, fsize or FS, "")
  fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
  if w then fs:SetWidth(w) end
  fs:SetJustifyH(justify or "LEFT")
  if r then fs:SetTextColor(r, g, b, 1) end
  if text then fs:SetText(text) end
  return fs
end

local function MakeBtn(parent, label, w, h, template)
  local btn = CreateFrame("Button", nil, parent, template or "GameMenuButtonTemplate")
  btn:SetWidth(w); btn:SetHeight(h)
  btn:SetText(label)
  btn:GetFontString():SetFont(FONT, FS, "OUTLINE")
  return btn
end

-- ── ML Window ────────────────────────────────────────────────────────────────
local mlFrame         -- the ML loot window
local mlRows = {}     -- pool of row frames
local mlItemIcon      -- Texture
local mlItemIconBtn   -- Button (for tooltip / shift-click)
local mlTimerText     -- FontString
local mlItemNameText  -- FontString
local mlCostText      -- FontString
local mlNAXXBtn       -- table toggle button
local mlKARABtn       -- table toggle button
local mlCostInput     -- editable cost override EditBox

local function UpdateTableButtons()
  if not mlNAXXBtn then return end
  if st.activeTable == "EP" then
    mlNAXXBtn:GetFontString():SetTextColor(1, 0.84, 0, 1)
    mlKARABtn:GetFontString():SetTextColor(0.6, 0.6, 0.6, 1)
  else
    mlNAXXBtn:GetFontString():SetTextColor(0.6, 0.6, 0.6, 1)
    mlKARABtn:GetFontString():SetTextColor(1, 0.84, 0, 1)
  end
end

local function UpdateMLRows()
  SortBids()
  local cost = WinCost()
  local tName = (st.activeTable == "EP") and TABLE_EP_NAME or TABLE_GP_NAME

  -- Cost label + input sync
  if mlCostText then
    local n = table.getn(st.bids)
    if n == 0 then
      mlCostText:SetText("|cFF888888No bids yet.|r")
    elseif n == 1 then
      mlCostText:SetText(string.format(
        "Cost (%s DKP):", tName))
    else
      mlCostText:SetText(string.format(
        "Cost (%s DKP):", tName))
    end
    if mlCostInput then mlCostInput:SetText(tostring(cost)) end
  end

  for i, row in ipairs(mlRows) do
    local bid = st.bids[i]
    if bid then
      row.nameText:SetText(CC(bid.name, bid.class))
      row.rankText:SetText("|cFFAAAAAA"..bid.rank.."|r")
      -- highlight the active DKP column
      if st.activeTable == "EP" then
        row.epText:SetText("|cFFFFD100"..bid.ep.."|r")
        row.gpText:SetText("|cFF888888"..bid.gp.."|r")
      else
        row.epText:SetText("|cFF888888"..bid.ep.."|r")
        row.gpText:SetText("|cFFFFD100"..bid.gp.."|r")
      end
      local available = (st.activeTable == "EP") and bid.ep or bid.gp
      local bidColor = (bid.bid > available) and "|cFFFF4444" or "|cFF00FF00"
      row.bidText:SetText(bidColor..bid.bid.."|r")
      row.awardBtn._playerName = bid.name
      row:Show()
    else
      row:Hide()
    end
  end
end

local function CreateMLRowPool(parent)
  local topY = HEADER_H + COLHDR_H + 16  -- offset from frame top
  for i = 1, MAX_ROWS do
    local row = CreateFrame("Frame", nil, parent)
    row:SetWidth(ML_W - 16)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -(topY + (i-1)*ROW_H))

    -- alternating background
    if math.mod(i, 2) == 0 then
      local bg = row:CreateTexture(nil, "BACKGROUND")
      bg:SetAllPoints(row)
      bg:SetTexture(0.08, 0.08, 0.08, 0.5)
    end

    local function FS(x, w, justify)
      local f = row:CreateFontString(nil, "OVERLAY")
      f:SetFont(FONT, 11, "")
      f:SetPoint("LEFT", row, "LEFT", x, 0)
      f:SetWidth(w)
      f:SetJustifyH(justify or "LEFT")
      f:SetJustifyV("MIDDLE")
      return f
    end

    row.nameText = FS(COL.NAME, 110, "LEFT")
    row.rankText = FS(COL.RANK, 78, "LEFT")
    row.epText   = FS(COL.EP,   55, "RIGHT")
    row.gpText   = FS(COL.GP,   55, "RIGHT")
    row.bidText  = FS(COL.BID,  50, "RIGHT")

    local btn = MakeBtn(row, "Award", 88, ROW_H - 4)
    btn:SetPoint("LEFT", row, "LEFT", COL.AWD, 0)
    btn._playerName = ""
    btn:SetScript("OnClick", function()
      if this._playerName and this._playerName ~= "" then
        st.awardName = this._playerName
        st.awardCost = (mlCostInput and tonumber(mlCostInput:GetText())) or WinCost()
        local tName = (st.activeTable == "EP") and TABLE_EP_NAME or TABLE_GP_NAME
        StaticPopupDialogs["BRP_CONFIRM_AWARD"].text =
          "Award to |cFFFFD100"..st.awardName.."|r\nCost ("..tName.." DKP):"
        local popup = StaticPopup_Show("BRP_CONFIRM_AWARD")
        if popup then
          local eb = getglobal(popup:GetName().."EditBox")
          if eb then
            eb:SetNumeric(true)
            eb:SetText(tostring(st.awardCost))
            eb:SetFocus()
          end
        end
      end
    end)
    row.awardBtn = btn

    row:Hide()
    table.insert(mlRows, row)
  end
end

local function CreateMLFrame()
  local f = CreateFrame("Frame", "BRPMasterMLFrame", UIParent)
  f:SetWidth(ML_W)
  f:SetHeight(ML_H)
  f:SetPoint("CENTER", UIParent, "CENTER", 200, 50)
  f:SetFrameStrata("DIALOG")
  MakeBackdrop(f, 0, 0, 0, 0.92)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function() f:StartMoving() end)
  f:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

  MakeCloseBtn(f, function() ResetBids() end)

  -- Title
  local title = f:CreateFontString(nil, "OVERLAY")
  title:SetFont(FONT, 13, "OUTLINE")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -8)
  title:SetTextColor(1, 0.84, 0, 1)
  title:SetText("BRP Loot Master")

  -- Table toggle buttons
  mlNAXXBtn = MakeBtn(f, TABLE_EP_NAME, 60, 22)
  mlNAXXBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -36, -6)
  mlNAXXBtn:SetScript("OnClick", function()
    st.activeTable = "EP"
    BRPMasterDB.activeTable = "EP"
    UpdateTableButtons()
    UpdateMLRows()
    local ch = GetNumRaidMembers() > 0 and "RAID" or "PARTY"
    SendAddonMessage(MSG.PREFIX, MSG.TABLE.."EP", ch)
  end)

  mlKARABtn = MakeBtn(f, TABLE_GP_NAME, 60, 22)
  mlKARABtn:SetPoint("RIGHT", mlNAXXBtn, "LEFT", -4, 0)
  mlKARABtn:SetScript("OnClick", function()
    st.activeTable = "GP"
    BRPMasterDB.activeTable = "GP"
    UpdateTableButtons()
    UpdateMLRows()
    local ch = GetNumRaidMembers() > 0 and "RAID" or "PARTY"
    SendAddonMessage(MSG.PREFIX, MSG.TABLE.."GP", ch)
  end)
  UpdateTableButtons()

  -- Item icon
  mlItemIcon = f:CreateTexture(nil, "ARTWORK")
  mlItemIcon:SetWidth(44); mlItemIcon:SetHeight(44)
  mlItemIcon:SetPoint("TOP", f, "TOP", 0, -28)
  mlItemIcon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")

  -- Icon button for tooltip
  mlItemIconBtn = CreateFrame("Button", nil, f)
  mlItemIconBtn:SetWidth(44); mlItemIconBtn:SetHeight(44)
  mlItemIconBtn:SetPoint("TOP", f, "TOP", 0, -28)
  local mlTT = CreateFrame("GameTooltip", "BRPMasterMLTooltip", UIParent, "GameTooltipTemplate")
  mlItemIconBtn:SetScript("OnEnter", function()
    if st.item then
      mlTT:SetOwner(mlItemIconBtn, "ANCHOR_RIGHT")
      mlTT:SetHyperlink(st.item)
      mlTT:Show()
    end
  end)
  mlItemIconBtn:SetScript("OnLeave", function() mlTT:Hide() end)

  -- Timer
  mlTimerText = f:CreateFontString(nil, "OVERLAY")
  mlTimerText:SetFont(FONT, 20, "OUTLINE")
  mlTimerText:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -24)
  mlTimerText:SetTextColor(1, 0.84, 0, 1)

  -- Item name
  mlItemNameText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  mlItemNameText:SetPoint("TOP", mlItemIcon, "BOTTOM", 0, -3)
  mlItemNameText:SetWidth(ML_W - 20)
  mlItemNameText:SetJustifyH("CENTER")

  -- Separator line after header
  local sep1 = f:CreateTexture(nil, "ARTWORK")
  sep1:SetHeight(1); sep1:SetWidth(ML_W - 16)
  sep1:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -(HEADER_H + 4))
  sep1:SetTexture(0.5, 0.42, 0.1, 0.8)

  -- Column headers
  local function CHdr(text, x, w, justify)
    local fs = f:CreateFontString(nil, "OVERLAY")
    fs:SetFont(FONT, FS, "OUTLINE")
    fs:SetTextColor(0.9, 0.75, 0.1, 1)
    fs:SetPoint("TOPLEFT", f, "TOPLEFT", x, -(HEADER_H + 10))
    fs:SetWidth(w); fs:SetJustifyH(justify or "LEFT")
    fs:SetText(text)
    return fs
  end
  CHdr("Name",  COL.NAME, 110, "LEFT")
  CHdr("Rank",  COL.RANK,  78, "LEFT")
  CHdr(TABLE_EP_NAME,  COL.EP,    55, "RIGHT")
  CHdr(TABLE_GP_NAME,  COL.GP,    55, "RIGHT")
  CHdr("Bid",   COL.BID,   50, "RIGHT")

  -- Separator after column headers
  local sep2 = f:CreateTexture(nil, "ARTWORK")
  sep2:SetHeight(1); sep2:SetWidth(ML_W - 16)
  sep2:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -(HEADER_H + COLHDR_H + 8))
  sep2:SetTexture(0.3, 0.3, 0.3, 0.6)

  -- Bid rows
  CreateMLRowPool(f)

  -- Footer separator
  local sep3 = f:CreateTexture(nil, "ARTWORK")
  sep3:SetHeight(1); sep3:SetWidth(ML_W - 16)
  sep3:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 8, FOOTER_H)
  sep3:SetTexture(0.3, 0.3, 0.3, 0.6)

  -- Cost label
  mlCostText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  mlCostText:SetFont(FONT, FS, "")
  mlCostText:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, FOOTER_H - 18)
  mlCostText:SetWidth(120)
  mlCostText:SetJustifyH("LEFT")
  mlCostText:SetText("|cFF888888No bids yet.|r")

  -- Editable cost input
  mlCostInput = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
  mlCostInput:SetWidth(58)
  mlCostInput:SetHeight(20)
  mlCostInput:SetPoint("LEFT", mlCostText, "RIGHT", 4, 0)
  mlCostInput:SetAutoFocus(false)
  mlCostInput:SetMaxLetters(6)
  mlCostInput:SetNumeric(true)
  mlCostInput:SetText(tostring(MIN_BID))

  -- Clear button
  local clearBtn = MakeBtn(f, "Clear Bids", 95, 26)
  clearBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, FOOTER_H - 22)
  clearBtn:SetScript("OnClick", function()
    ResetBids()
    UpdateMLRows()
  end)

  -- OnUpdate for countdown timer
  f:SetScript("OnUpdate", function()
    if not st.rolling then return end
    local dt = arg1
    st.elapsed = st.elapsed + dt
    local remain = st.duration - st.elapsed
    if mlTimerText then
      mlTimerText:SetText(string.format("%.1f", remain > 0 and remain or 0))
    end
    if remain <= 0 then
      st.rolling = false
      st.elapsed = 0
      if mlTimerText then mlTimerText:SetText("0.0") end
    end
  end)

  f:Hide()
  return f
end

-- ── Player DKP Manager Window ─────────────────────────────────────────────────
local playerMgrFrame
local pmgrRows         = {}
local pmgrScrollOffset = 0
local pmgrClassFilter  = nil
local pmgrSelectedName = nil
local pmgrList         = {}
local pmgrSelLabel
local pmgrAmtInput
local pmgrScrollUp
local pmgrScrollDown
local pmgrRaidOnly  = false
local pmgrRaidBtn

local PMGR_W        = 390
local PMGR_ROW_H    = 22
local PMGR_MAX_ROWS = 14
local PMGR_HDR_H    = 56
local PMGR_COLHDR_H = 20
local PMGR_FOOTER_H = 122
local PMGR_H = PMGR_HDR_H + PMGR_COLHDR_H + (PMGR_MAX_ROWS * PMGR_ROW_H) + PMGR_FOOTER_H

local function BuildPMGRList()
  pmgrList = {}
  local raidSet = nil
  if pmgrRaidOnly then
    raidSet = {}
    for i = 1, GetNumRaidMembers() do
      local name = GetRaidRosterInfo(i)
      if name then raidSet[name] = true end
    end
  end
  for name, m in pairs(cache) do
    if (pmgrClassFilter == nil or m.class == pmgrClassFilter)
    and (raidSet == nil or raidSet[name]) then
      table.insert(pmgrList, {name=name, ep=m.ep, gp=m.gp, class=m.class})
    end
  end
  table.sort(pmgrList, function(a, b) return a.name < b.name end)
end

local function UpdatePMGRRows()
  BuildPMGRList()
  local total     = table.getn(pmgrList)
  local maxScroll = math.max(0, total - PMGR_MAX_ROWS)
  if pmgrScrollOffset > maxScroll then pmgrScrollOffset = maxScroll end
  if pmgrScrollOffset < 0         then pmgrScrollOffset = 0         end

  for i = 1, PMGR_MAX_ROWS do
    local row   = pmgrRows[i]
    local entry = pmgrList[pmgrScrollOffset + i]
    if entry then
      row.nameText:SetText(CC(entry.name, entry.class))
      row.epText:SetText("|cFFFFD100"..entry.ep.."|r")
      row.gpText:SetText("|cFF88CCFF"..entry.gp.."|r")
      row._name = entry.name
      if entry.name == pmgrSelectedName then
        row.hlBg:SetTexture(0.25, 0.20, 0.04, 0.9)
      elseif math.mod(i, 2) == 0 then
        row.hlBg:SetTexture(0.08, 0.08, 0.08, 0.5)
      else
        row.hlBg:SetTexture(0, 0, 0, 0)
      end
      row:Show()
    else
      row:Hide()
    end
  end

  if pmgrScrollUp then
    if pmgrScrollOffset > 0         then pmgrScrollUp:Enable()   else pmgrScrollUp:Disable()   end
  end
  if pmgrScrollDown then
    if pmgrScrollOffset < maxScroll then pmgrScrollDown:Enable() else pmgrScrollDown:Disable() end
  end

  if pmgrSelLabel then
    if pmgrSelectedName and cache[pmgrSelectedName] then
      local m = cache[pmgrSelectedName]
      pmgrSelLabel:SetText(CC(pmgrSelectedName, m.class)..
        "   "..TABLE_EP_NAME..": |cFFFFD100"..m.ep.."|r   "..TABLE_GP_NAME..": |cFF88CCFF"..m.gp.."|r")
    else
      pmgrSelLabel:SetText("|cFF888888Click a player to select|r")
    end
  end
end

local function CreatePlayerMgrFrame()
  local f = CreateFrame("Frame", "BRPMasterPMGRFrame", UIParent)
  f:SetWidth(PMGR_W)
  f:SetHeight(PMGR_H)
  f:SetPoint("CENTER", UIParent, "CENTER", -230, 0)
  f:SetFrameStrata("DIALOG")
  MakeBackdrop(f, 0, 0, 0, 0.92)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:EnableMouseWheel(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function() f:StartMoving() end)
  f:SetScript("OnDragStop",  function() f:StopMovingOrSizing() end)
  f:SetScript("OnMouseWheel", function()
    if arg1 > 0 then pmgrScrollOffset = pmgrScrollOffset - 1
    else              pmgrScrollOffset = pmgrScrollOffset + 1 end
    UpdatePMGRRows()
  end)

  MakeCloseBtn(f, nil)

  local title = f:CreateFontString(nil, "OVERLAY")
  title:SetFont(FONT, 13, "OUTLINE")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -8)
  title:SetTextColor(1, 0.84, 0, 1)
  title:SetText("Player DKP Manager")

  -- Raid / All toggle
  local function UpdateRaidBtn()
    if pmgrRaidOnly then
      pmgrRaidBtn:GetFontString():SetTextColor(0.2, 1, 0.4, 1)
      pmgrRaidBtn:SetText("Raid Only")
    else
      pmgrRaidBtn:GetFontString():SetTextColor(0.6, 0.6, 0.6, 1)
      pmgrRaidBtn:SetText("All Guild")
    end
  end
  pmgrRaidBtn = MakeBtn(f, "All Guild", 76, 18)
  pmgrRaidBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -30, -6)
  pmgrRaidBtn:GetFontString():SetFont(FONT, 10, "OUTLINE")
  pmgrRaidBtn:SetScript("OnClick", function()
    pmgrRaidOnly     = not pmgrRaidOnly
    pmgrScrollOffset = 0
    pmgrSelectedName = nil
    UpdateRaidBtn()
    UpdatePMGRRows()
  end)
  UpdateRaidBtn()

  -- Class filter buttons
  local clsDefs = {
    {key=nil,       lbl="All", r=1,    g=0.84, b=0   },
    {key="Warrior", lbl="WAR", r=0.78, g=0.61, b=0.43},
    {key="Paladin", lbl="PAL", r=0.96, g=0.55, b=0.73},
    {key="Hunter",  lbl="HUN", r=0.67, g=0.83, b=0.45},
    {key="Rogue",   lbl="ROG", r=1,    g=0.96, b=0.41},
    {key="Priest",  lbl="PRI", r=1,    g=1,    b=1   },
    {key="Shaman",  lbl="SHA", r=0,    g=0.44, b=0.87},
    {key="Mage",    lbl="MAG", r=0.41, g=0.80, b=0.94},
    {key="Warlock", lbl="WRL", r=0.58, g=0.51, b=0.79},
    {key="Druid",   lbl="DRU", r=1,    g=0.49, b=0.04},
  }
  local btnW = 35
  for i = 1, table.getn(clsDefs) do
    local cd  = clsDefs[i]
    local btn = MakeBtn(f, cd.lbl, btnW, 18)
    btn:SetPoint("TOPLEFT", f, "TOPLEFT", 6 + (i-1)*(btnW+1), -28)
    btn:GetFontString():SetFont(FONT, 9, "OUTLINE")
    btn:GetFontString():SetTextColor(cd.r, cd.g, cd.b, 1)
    local clsKey = cd.key
    btn:SetScript("OnClick", function()
      pmgrClassFilter  = clsKey
      pmgrScrollOffset = 0
      UpdatePMGRRows()
    end)
  end

  local sep1 = f:CreateTexture(nil, "ARTWORK")
  sep1:SetHeight(1); sep1:SetWidth(PMGR_W - 16)
  sep1:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -(PMGR_HDR_H - 2))
  sep1:SetTexture(0.5, 0.42, 0.1, 0.8)

  local function CHdr(text, x, w, justify)
    local fs = f:CreateFontString(nil, "OVERLAY")
    fs:SetFont(FONT, FS, "OUTLINE")
    fs:SetTextColor(0.9, 0.75, 0.1, 1)
    fs:SetPoint("TOPLEFT", f, "TOPLEFT", x, -(PMGR_HDR_H + 4))
    fs:SetWidth(w); fs:SetJustifyH(justify or "LEFT")
    fs:SetText(text)
  end
  CHdr("Name", 8,   180, "LEFT")
  CHdr(TABLE_EP_NAME, 192, 82,  "RIGHT")
  CHdr(TABLE_GP_NAME, 278, 82,  "RIGHT")

  local sep2 = f:CreateTexture(nil, "ARTWORK")
  sep2:SetHeight(1); sep2:SetWidth(PMGR_W - 16)
  sep2:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -(PMGR_HDR_H + PMGR_COLHDR_H + 2))
  sep2:SetTexture(0.3, 0.3, 0.3, 0.6)

  -- Row pool
  local listW = PMGR_W - 16 - 18
  local topY  = PMGR_HDR_H + PMGR_COLHDR_H + 4
  for i = 1, PMGR_MAX_ROWS do
    local row = CreateFrame("Button", nil, f)
    row:SetWidth(listW)
    row:SetHeight(PMGR_ROW_H)
    row:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -(topY + (i-1)*PMGR_ROW_H))
    row:RegisterForClicks("LeftButtonUp")

    local hlBg = row:CreateTexture(nil, "BACKGROUND")
    hlBg:SetAllPoints(row)
    if math.mod(i, 2) == 0 then hlBg:SetTexture(0.08, 0.08, 0.08, 0.5)
    else                        hlBg:SetTexture(0, 0, 0, 0) end
    row.hlBg = hlBg

    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

    local nameText = row:CreateFontString(nil, "OVERLAY")
    nameText:SetFont(FONT, FS, ""); nameText:SetWidth(180)
    nameText:SetPoint("LEFT", row, "LEFT", 2, 0)
    nameText:SetJustifyH("LEFT")
    row.nameText = nameText

    local epText = row:CreateFontString(nil, "OVERLAY")
    epText:SetFont(FONT, FS, ""); epText:SetWidth(82)
    epText:SetPoint("LEFT", row, "LEFT", 184, 0)
    epText:SetJustifyH("RIGHT")
    row.epText = epText

    local gpText = row:CreateFontString(nil, "OVERLAY")
    gpText:SetFont(FONT, FS, ""); gpText:SetWidth(82)
    gpText:SetPoint("LEFT", row, "LEFT", 270, 0)
    gpText:SetJustifyH("RIGHT")
    row.gpText = gpText

    row._name = nil
    row:SetScript("OnClick", function()
      pmgrSelectedName = this._name
      UpdatePMGRRows()
    end)
    row:Hide()
    table.insert(pmgrRows, row)
  end

  -- Scroll buttons
  pmgrScrollUp = MakeBtn(f, "^", 16, 20)
  pmgrScrollUp:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -topY)
  pmgrScrollUp:GetFontString():SetFont(FONT, 9, "")
  pmgrScrollUp:SetScript("OnClick", function()
    pmgrScrollOffset = pmgrScrollOffset - 1; UpdatePMGRRows()
  end)

  pmgrScrollDown = MakeBtn(f, "v", 16, 20)
  pmgrScrollDown:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -(topY + PMGR_MAX_ROWS * PMGR_ROW_H - 20))
  pmgrScrollDown:GetFontString():SetFont(FONT, 9, "")
  pmgrScrollDown:SetScript("OnClick", function()
    pmgrScrollOffset = pmgrScrollOffset + 1; UpdatePMGRRows()
  end)

  -- Footer
  local sep3 = f:CreateTexture(nil, "ARTWORK")
  sep3:SetHeight(1); sep3:SetWidth(PMGR_W - 16)
  sep3:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 8, PMGR_FOOTER_H)
  sep3:SetTexture(0.3, 0.3, 0.3, 0.6)

  -- Row 1: selected player label + Refresh button
  pmgrSelLabel = f:CreateFontString(nil, "OVERLAY")
  pmgrSelLabel:SetFont(FONT, FS, "")
  pmgrSelLabel:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, PMGR_FOOTER_H - 20)
  pmgrSelLabel:SetWidth(PMGR_W - 110)
  pmgrSelLabel:SetJustifyH("LEFT")
  pmgrSelLabel:SetText("|cFF888888Click a player to select|r")

  local refreshBtn = MakeBtn(f, "Refresh", 76, 20)
  refreshBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, PMGR_FOOTER_H - 20)
  refreshBtn:SetScript("OnClick", function()
    GuildRoster()
    Pr("Refreshing guild cache...")
  end)

  -- Row 2: amount label + input
  local amtLabel = f:CreateFontString(nil, "OVERLAY")
  amtLabel:SetFont(FONT, FS, "")
  amtLabel:SetTextColor(0.9, 0.75, 0.1, 1)
  amtLabel:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, PMGR_FOOTER_H - 48)
  amtLabel:SetText("Amount:")

  pmgrAmtInput = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
  pmgrAmtInput:SetWidth(58); pmgrAmtInput:SetHeight(20)
  pmgrAmtInput:SetPoint("LEFT", amtLabel, "RIGHT", 4, 0)
  pmgrAmtInput:SetAutoFocus(false)
  pmgrAmtInput:SetMaxLetters(6)
  pmgrAmtInput:SetNumeric(true)
  pmgrAmtInput:SetText("0")
  pmgrAmtInput:SetScript("OnEnterPressed", function() pmgrAmtInput:ClearFocus() end)

  local function ApplyDKP(isEP, sign)
    if not pmgrSelectedName then Pr("No player selected."); return end
    local amt = (tonumber(pmgrAmtInput:GetText()) or 0) * sign
    if amt == 0 then Pr("Amount is 0."); return end
    local tName = isEP and TABLE_EP_NAME or TABLE_GP_NAME
    local sign_s = amt >= 0 and "+" or ""
    local tableKey = isEP and "EP" or "GP"
    if ApplyDKPChange(pmgrSelectedName, tableKey, amt, { reason = "Manager adjust" }) then
      Pr(pmgrSelectedName.." "..tName.." "..sign_s..amt)
      Announce(string.format("[BRP] %s %s DKP %s%d", pmgrSelectedName, tName, sign_s, amt))
      UpdatePMGRRows()
    end
  end

  -- Row 3: +/- buttons
  local bY = PMGR_FOOTER_H - 74
  local b1 = MakeBtn(f, "+"..TABLE_EP_NAME, 76, 22)
  b1:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, bY)
  b1:GetFontString():SetTextColor(0.2, 1, 0.2, 1)
  b1:SetScript("OnClick", function() ApplyDKP(true, 1) end)

  local b2 = MakeBtn(f, "-"..TABLE_EP_NAME, 76, 22)
  b2:SetPoint("LEFT", b1, "RIGHT", 4, 0)
  b2:GetFontString():SetTextColor(1, 0.4, 0.4, 1)
  b2:SetScript("OnClick", function() ApplyDKP(true, -1) end)

  local b3 = MakeBtn(f, "+"..TABLE_GP_NAME, 76, 22)
  b3:SetPoint("LEFT", b2, "RIGHT", 8, 0)
  b3:GetFontString():SetTextColor(0.4, 0.8, 1, 1)
  b3:SetScript("OnClick", function() ApplyDKP(false, 1) end)

  local b4 = MakeBtn(f, "-"..TABLE_GP_NAME, 76, 22)
  b4:SetPoint("LEFT", b3, "RIGHT", 4, 0)
  b4:GetFontString():SetTextColor(1, 0.65, 0.1, 1)
  b4:SetScript("OnClick", function() ApplyDKP(false, -1) end)

  local logBtn = MakeBtn(f, "Logs", 76, 20)
  logBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 10)
  logBtn:SetScript("OnClick", function()
    if logViewerFrame then
      if logViewerFrame:IsVisible() then logViewerFrame:Hide()
      else
        if UpdateLogRows then UpdateLogRows() end
        logViewerFrame:Show()
      end
    end
  end)

  f:Hide()
  return f
end

-- ── Item display ──────────────────────────────────────────────────────────────
-- Log viewer
local logRows = {}
local logScrollOffset = 0
local logSelectedIndex = nil
local logDetailText
local logScrollUp
local logScrollDown
local exportEditBox
local standingsExportEditBox
local logExportPartText
local standingsExportPartText

local EXPORT_CHUNK_CHARS = 25000
local logExportState = { fullText = "", chunks = {""}, index = 1 }
local standingsExportState = { fullText = "", chunks = {""}, index = 1 }

local LOG_W = 760
local LOG_H = 420
local LOG_ROW_H = 22
local LOG_MAX_ROWS = 10

local function GetLogEntrySummary(entry)
  if entry.kind == "decay" then
    return string.format("Decay  %s %d>%d  %s %d>%d",
      TABLE_EP_NAME, entry.beforeEP or 0, entry.afterEP or 0,
      TABLE_GP_NAME, entry.beforeGP or 0, entry.afterGP or 0)
  end
  local tName = entry.tableName or TableDisplayName(entry.tableKey)
  return string.format("%s %d>%d (%+d)", tName, entry.before or 0, entry.after or 0, entry.delta or 0)
end

local function GetLogEntryTypeLabel(entry)
  if entry.kind == "raid_award" then return "RAID" end
  if entry.kind == "player_adjust" then return "MANUAL" end
  if entry.kind == "loot" then return "LOOT" end
  if entry.kind == "decay" then return "DECAY" end
  return string.upper(entry.kind or "LOG")
end

local function BuildLogDetail(entry)
  if not entry then
    return "|cFF888888Select a log entry to inspect details.|r"
  end
  local lines = {}
  table.insert(lines, string.format("|cFFFFD100%s|r  %s", GetLogEntryTypeLabel(entry), entry.dateText or "-"))
  table.insert(lines, "Player: "..(entry.target or "-"))
  table.insert(lines, "Actor: "..(entry.actor or "-"))
  if entry.kind == "decay" then
    table.insert(lines, string.format("%s: %d -> %d (%+d)", TABLE_EP_NAME, entry.beforeEP or 0, entry.afterEP or 0, entry.deltaEP or 0))
    table.insert(lines, string.format("%s: %d -> %d (%+d)", TABLE_GP_NAME, entry.beforeGP or 0, entry.afterGP or 0, entry.deltaGP or 0))
  else
    table.insert(lines, string.format("Table: %s", entry.tableName or "-"))
    table.insert(lines, string.format("Change: %d -> %d (%+d)", entry.before or 0, entry.after or 0, entry.delta or 0))
  end
  if entry.reason then table.insert(lines, "Reason: "..entry.reason) end
  if entry.meta and entry.meta.decayPct then table.insert(lines, "Decay: "..entry.meta.decayPct.."%") end
  if entry.itemName then
    table.insert(lines, "Item: "..entry.itemName)
  elseif entry.itemLink then
    table.insert(lines, "Item: "..entry.itemLink)
  end
  if entry.batchId then table.insert(lines, "Batch: "..entry.batchId) end
  return table.concat(lines, "\n")
end

UpdateLogRows = function()
  if not logViewerFrame then return end
  local logs = GetLogEntries()
  local total = table.getn(logs)
  local maxScroll = math.max(0, total - LOG_MAX_ROWS)
  if logScrollOffset > maxScroll then logScrollOffset = maxScroll end
  if logScrollOffset < 0 then logScrollOffset = 0 end

  for i = 1, LOG_MAX_ROWS do
    local row = logRows[i]
    local dataIndex = total - (logScrollOffset + i) + 1
    local entry = logs[dataIndex]
    if entry then
      row._index = dataIndex
      row.timeText:SetText(entry.dateText or "")
      row.typeText:SetText(GetLogEntryTypeLabel(entry))
      row.targetText:SetText(entry.target or "-")
      row.changeText:SetText(GetLogEntrySummary(entry))
      if dataIndex == logSelectedIndex then
        row.bg:SetTexture(0.25, 0.20, 0.04, 0.9)
      elseif math.mod(i, 2) == 0 then
        row.bg:SetTexture(0.08, 0.08, 0.08, 0.5)
      else
        row.bg:SetTexture(0, 0, 0, 0)
      end
      row:Show()
    else
      row._index = nil
      row:Hide()
    end
  end

  if logDetailText then
    logDetailText:SetText(BuildLogDetail(logs[logSelectedIndex]))
  end
  if logScrollUp then
    if logScrollOffset > 0 then logScrollUp:Enable() else logScrollUp:Disable() end
  end
  if logScrollDown then
    if logScrollOffset < maxScroll then logScrollDown:Enable() else logScrollDown:Disable() end
  end
end

local function BuildExportChunks(text, maxChars)
  text = text or ""
  if text == "" then
    return {""}
  end
  if not maxChars or maxChars < 1000 then
    maxChars = EXPORT_CHUNK_CHARS
  end

  local chunks = {}
  local textLen = string.len(text)
  local i = 1
  while i <= textLen do
    local j = i + maxChars - 1
    if j > textLen then j = textLen end
    table.insert(chunks, string.sub(text, i, j))
    i = j + 1
  end

  if table.getn(chunks) == 0 then
    table.insert(chunks, "")
  end
  return chunks
end

local function PrepareExportState(state, text)
  state.fullText = text or ""
  state.chunks = BuildExportChunks(state.fullText, EXPORT_CHUNK_CHARS)
  state.index = 1
end

local function ClampExportStateIndex(state)
  local total = table.getn(state.chunks or {})
  if total < 1 then
    state.chunks = {""}
    total = 1
  end
  if state.index < 1 then state.index = 1 end
  if state.index > total then state.index = total end
  return total
end

local function RefreshExportEditBox(state, eb, partText)
  local total = ClampExportStateIndex(state)
  local chunk = state.chunks[state.index] or ""
  eb:SetText(chunk)
  local parent = eb:GetParent()
  if parent and parent.UpdateScrollChildRect then
    parent:UpdateScrollChildRect()
  end
  eb:SetCursorPosition(0)
  eb:SetFocus()
  if partText then
    partText:SetText(string.format("|cFFAAAAAAPart %d/%d|r  |cFF777777(chunk %d chars, total %d)|r",
      state.index, total, string.len(chunk), string.len(state.fullText or "")))
  end
end

local function ShiftStep()
  if IsShiftKeyDown and IsShiftKeyDown() then
    return 5
  end
  return 1
end

local function StepExportPart(state, delta, eb, partText)
  state.index = state.index + delta
  RefreshExportEditBox(state, eb, partText)
end

local function ShowExportWindow()
  if not logExportFrame or not exportEditBox then return end
  PrepareExportState(logExportState, ExportLogsAsJson())
  logExportFrame:Show()
  RefreshExportEditBox(logExportState, exportEditBox, logExportPartText)
  if table.getn(logExportState.chunks) > 1 then
    Pr(string.format("Large export split into %d parts. Copy parts in order and concatenate as one JSON.", table.getn(logExportState.chunks)))
  end
end

local function ShowStandingsExportWindow()
  if not standingsExportFrame or not standingsExportEditBox then return end
  PrepareExportState(standingsExportState, ExportStandingsAsJson())
  standingsExportFrame:Show()
  RefreshExportEditBox(standingsExportState, standingsExportEditBox, standingsExportPartText)
  if table.getn(standingsExportState.chunks) > 1 then
    Pr(string.format("Large export split into %d parts. Copy parts in order and concatenate as one JSON.", table.getn(standingsExportState.chunks)))
  end
end

local function SaveExportSnapshot(key, payload, entryCount)
  EnsureDB()
  if type(BRPMasterExportDB) ~= "table" then
    BRPMasterExportDB = {}
  end
  BRPMasterExportDB[key] = {
    schemaVersion = 1,
    exportedAt = time(),
    exportedAtText = date("%Y-%m-%d %H:%M:%S"),
    exportedBy = UnitName("player"),
    guildName = GetGuildName(),
    entries = entryCount or 0,
    payload = payload or "",
  }
end

local function SaveLogsExportToSavedVariables()
  local logs = GetLogEntries()
  local payload = ExportLogsAsJson()
  SaveExportSnapshot("logs", payload, table.getn(logs))
  Pr("Log export snapshot saved to separate file.")
  Pr("Type /reload or relog, then open: WTF\\Account\\<ACCOUNT>\\SavedVariables\\BRPMasterExport.lua")
  Pr("Use BRPMasterExportDB.logs.payload as the JSON for your site upload.")
end

local function SaveStandingsExportToSavedVariables()
  local list = BuildStandingsList(true)
  local payload = ExportStandingsAsJson()
  SaveExportSnapshot("standings", payload, table.getn(list))
  Pr("Standings export snapshot saved to separate file.")
  Pr("Type /reload or relog, then open: WTF\\Account\\<ACCOUNT>\\SavedVariables\\BRPMasterExport.lua")
  Pr("Use BRPMasterExportDB.standings.payload as the JSON for your site upload.")
end

local function CreateLogExportFrame()
  local f = CreateFrame("Frame", "BRPMasterLogExportFrame", UIParent)
  f:SetWidth(680)
  f:SetHeight(440)
  f:SetPoint("CENTER", UIParent, "CENTER", 60, 0)
  f:SetFrameStrata("DIALOG")
  MakeBackdrop(f, 0, 0, 0, 0.95)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function() f:StartMoving() end)
  f:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
  MakeCloseBtn(f, nil)

  local title = f:CreateFontString(nil, "OVERLAY")
  title:SetFont(FONT, 13, "OUTLINE")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -8)
  title:SetTextColor(1, 0.84, 0, 1)
  title:SetText("DKP Log Export")

  local hint = f:CreateFontString(nil, "OVERLAY")
  hint:SetFont(FONT, FS, "")
  hint:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -28)
  hint:SetWidth(620)
  hint:SetJustifyH("LEFT")
  hint:SetText("|cFFAAAAAAExport log JSON in safe parts. Use Ctrl+A, then Ctrl+C for each part.|r")

  local part = f:CreateFontString(nil, "OVERLAY")
  part:SetFont(FONT, FS, "")
  part:SetPoint("TOPRIGHT", f, "TOPRIGHT", -28, -28)
  part:SetJustifyH("RIGHT")
  part:SetText("|cFF777777Part 1/1|r")
  logExportPartText = part

  local scroll = CreateFrame("ScrollFrame", "BRPMasterLogExportScroll", f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -48)
  scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 40)

  local eb = CreateFrame("EditBox", "BRPMasterLogExportEditBox", scroll)
  eb:SetFont(FONT_MONO, FS, "")
  eb:SetWidth(620)
  eb:SetHeight(4000)
  eb:SetMultiLine(true)
  eb:SetAutoFocus(false)
  eb:SetJustifyH("LEFT")
  eb:SetScript("OnEscapePressed", function() eb:ClearFocus() end)
  scroll:SetScrollChild(eb)
  exportEditBox = eb

  local prevBtn = MakeBtn(f, "<", 28, 20)
  prevBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 42, 10)
  prevBtn:SetScript("OnClick", function()
    StepExportPart(logExportState, -ShiftStep(), exportEditBox, logExportPartText)
  end)

  local nextBtn = MakeBtn(f, ">", 28, 20)
  nextBtn:SetPoint("LEFT", prevBtn, "RIGHT", 4, 0)
  nextBtn:SetScript("OnClick", function()
    StepExportPart(logExportState, ShiftStep(), exportEditBox, logExportPartText)
  end)

  local firstBtn = MakeBtn(f, "<<", 28, 20)
  firstBtn:SetPoint("RIGHT", prevBtn, "LEFT", -4, 0)
  firstBtn:SetScript("OnClick", function()
    logExportState.index = 1
    RefreshExportEditBox(logExportState, exportEditBox, logExportPartText)
  end)

  local lastBtn = MakeBtn(f, ">>", 28, 20)
  lastBtn:SetPoint("LEFT", nextBtn, "RIGHT", 4, 0)
  lastBtn:SetScript("OnClick", function()
    logExportState.index = table.getn(logExportState.chunks)
    RefreshExportEditBox(logExportState, exportEditBox, logExportPartText)
  end)

  local refreshBtn = MakeBtn(f, "Refresh", 80, 20)
  refreshBtn:SetPoint("LEFT", lastBtn, "RIGHT", 8, 0)
  refreshBtn:SetScript("OnClick", function()
    PrepareExportState(logExportState, ExportLogsAsJson())
    RefreshExportEditBox(logExportState, exportEditBox, logExportPartText)
  end)

  local saveBtn = MakeBtn(f, "Save to File", 110, 20)
  saveBtn:SetPoint("LEFT", refreshBtn, "RIGHT", 6, 0)
  saveBtn:SetScript("OnClick", function()
    SaveLogsExportToSavedVariables()
  end)

  f:Hide()
  return f
end

local function CreateStandingsExportFrame()
  local f = CreateFrame("Frame", "BRPMasterStandingsExportFrame", UIParent)
  f:SetWidth(680)
  f:SetHeight(440)
  f:SetPoint("CENTER", UIParent, "CENTER", -60, 0)
  f:SetFrameStrata("DIALOG")
  MakeBackdrop(f, 0, 0, 0, 0.95)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function() f:StartMoving() end)
  f:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
  MakeCloseBtn(f, nil)

  local title = f:CreateFontString(nil, "OVERLAY")
  title:SetFont(FONT, 13, "OUTLINE")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -8)
  title:SetTextColor(1, 0.84, 0, 1)
  title:SetText("DKP Standings Export")

  local hint = f:CreateFontString(nil, "OVERLAY")
  hint:SetFont(FONT, FS, "")
  hint:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -28)
  hint:SetWidth(620)
  hint:SetJustifyH("LEFT")
  hint:SetText("|cFFAAAAAAExport standings JSON in safe parts. Use Ctrl+A, then Ctrl+C for each part.|r")

  local part = f:CreateFontString(nil, "OVERLAY")
  part:SetFont(FONT, FS, "")
  part:SetPoint("TOPRIGHT", f, "TOPRIGHT", -28, -28)
  part:SetJustifyH("RIGHT")
  part:SetText("|cFF777777Part 1/1|r")
  standingsExportPartText = part

  local scroll = CreateFrame("ScrollFrame", "BRPMasterStandingsExportScroll", f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -48)
  scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 40)

  local eb = CreateFrame("EditBox", "BRPMasterStandingsExportEditBox", scroll)
  eb:SetFont(FONT_MONO, FS, "")
  eb:SetWidth(620)
  eb:SetHeight(4000)
  eb:SetMultiLine(true)
  eb:SetAutoFocus(false)
  eb:SetJustifyH("LEFT")
  eb:SetScript("OnEscapePressed", function() eb:ClearFocus() end)
  scroll:SetScrollChild(eb)
  standingsExportEditBox = eb

  local prevBtn = MakeBtn(f, "<", 28, 20)
  prevBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 42, 10)
  prevBtn:SetScript("OnClick", function()
    StepExportPart(standingsExportState, -ShiftStep(), standingsExportEditBox, standingsExportPartText)
  end)

  local nextBtn = MakeBtn(f, ">", 28, 20)
  nextBtn:SetPoint("LEFT", prevBtn, "RIGHT", 4, 0)
  nextBtn:SetScript("OnClick", function()
    StepExportPart(standingsExportState, ShiftStep(), standingsExportEditBox, standingsExportPartText)
  end)

  local firstBtn = MakeBtn(f, "<<", 28, 20)
  firstBtn:SetPoint("RIGHT", prevBtn, "LEFT", -4, 0)
  firstBtn:SetScript("OnClick", function()
    standingsExportState.index = 1
    RefreshExportEditBox(standingsExportState, standingsExportEditBox, standingsExportPartText)
  end)

  local lastBtn = MakeBtn(f, ">>", 28, 20)
  lastBtn:SetPoint("LEFT", nextBtn, "RIGHT", 4, 0)
  lastBtn:SetScript("OnClick", function()
    standingsExportState.index = table.getn(standingsExportState.chunks)
    RefreshExportEditBox(standingsExportState, standingsExportEditBox, standingsExportPartText)
  end)

  local refreshBtn = MakeBtn(f, "Refresh", 80, 20)
  refreshBtn:SetPoint("LEFT", lastBtn, "RIGHT", 8, 0)
  refreshBtn:SetScript("OnClick", function()
    PrepareExportState(standingsExportState, ExportStandingsAsJson())
    RefreshExportEditBox(standingsExportState, standingsExportEditBox, standingsExportPartText)
  end)

  local saveBtn = MakeBtn(f, "Save to File", 110, 20)
  saveBtn:SetPoint("LEFT", refreshBtn, "RIGHT", 6, 0)
  saveBtn:SetScript("OnClick", function()
    SaveStandingsExportToSavedVariables()
  end)

  f:Hide()
  return f
end

StaticPopupDialogs["BRP_CONFIRM_CLEAR_LOGS"] = {
  text = "Delete all DKP log entries?",
  button1 = "Clear",
  button2 = "Cancel",
  OnAccept = function()
    EnsureDB()
    BRPMasterDB.logs = {}
    logSelectedIndex = nil
    logExportState = { fullText = "", chunks = {""}, index = 1 }
    if logExportFrame and logExportFrame:IsVisible() and exportEditBox then
      RefreshExportEditBox(logExportState, exportEditBox, logExportPartText)
    end
    if UpdateLogRows then UpdateLogRows() end
    Pr("DKP log cleared.")
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

local function CreateLogViewerFrame()
  local f = CreateFrame("Frame", "BRPMasterLogViewerFrame", UIParent)
  f:SetWidth(LOG_W)
  f:SetHeight(LOG_H)
  f:SetPoint("CENTER", UIParent, "CENTER", 120, 0)
  f:SetFrameStrata("DIALOG")
  MakeBackdrop(f, 0, 0, 0, 0.94)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:EnableMouseWheel(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function() f:StartMoving() end)
  f:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
  f:SetScript("OnMouseWheel", function()
    if arg1 > 0 then logScrollOffset = logScrollOffset - 1
    else              logScrollOffset = logScrollOffset + 1 end
    UpdateLogRows()
  end)
  MakeCloseBtn(f, nil)

  local title = f:CreateFontString(nil, "OVERLAY")
  title:SetFont(FONT, 13, "OUTLINE")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -8)
  title:SetTextColor(1, 0.84, 0, 1)
  title:SetText("DKP Log")

  local countText = f:CreateFontString(nil, "OVERLAY")
  countText:SetFont(FONT, FS, "")
  countText:SetPoint("TOPRIGHT", f, "TOPRIGHT", -120, -10)
  countText:SetTextColor(0.8, 0.8, 0.8, 1)

  local function RefreshCount()
    countText:SetText("Entries: "..table.getn(GetLogEntries()))
  end

  local headers = {
    {"Time", 10, 142},
    {"Type", 156, 78},
    {"Player", 238, 130},
    {"Change", 372, 324},
  }
  for i = 1, table.getn(headers) do
    local h = headers[i]
    local fs = f:CreateFontString(nil, "OVERLAY")
    fs:SetFont(FONT, FS, "OUTLINE")
    fs:SetTextColor(0.9, 0.75, 0.1, 1)
    fs:SetPoint("TOPLEFT", f, "TOPLEFT", h[2], -34)
    fs:SetWidth(h[3])
    fs:SetJustifyH("LEFT")
    fs:SetText(h[1])
  end

  local sep = f:CreateTexture(nil, "ARTWORK")
  sep:SetHeight(1)
  sep:SetWidth(LOG_W - 20)
  sep:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -52)
  sep:SetTexture(0.5, 0.42, 0.1, 0.8)

  for i = 1, LOG_MAX_ROWS do
    local row = CreateFrame("Button", nil, f)
    row:SetWidth(LOG_W - 38)
    row:SetHeight(LOG_ROW_H)
    row:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -(56 + (i-1) * LOG_ROW_H))
    row:RegisterForClicks("LeftButtonUp")

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(row)
    if math.mod(i, 2) == 0 then bg:SetTexture(0.08, 0.08, 0.08, 0.5)
    else                        bg:SetTexture(0, 0, 0, 0) end
    row.bg = bg

    row.timeText = row:CreateFontString(nil, "OVERLAY")
    row.timeText:SetFont(FONT, FS, "")
    row.timeText:SetWidth(142)
    row.timeText:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.timeText:SetJustifyH("LEFT")

    row.typeText = row:CreateFontString(nil, "OVERLAY")
    row.typeText:SetFont(FONT, FS, "")
    row.typeText:SetWidth(78)
    row.typeText:SetPoint("LEFT", row, "LEFT", 146, 0)
    row.typeText:SetJustifyH("LEFT")

    row.targetText = row:CreateFontString(nil, "OVERLAY")
    row.targetText:SetFont(FONT, FS, "")
    row.targetText:SetWidth(130)
    row.targetText:SetPoint("LEFT", row, "LEFT", 228, 0)
    row.targetText:SetJustifyH("LEFT")

    row.changeText = row:CreateFontString(nil, "OVERLAY")
    row.changeText:SetFont(FONT, FS, "")
    row.changeText:SetWidth(324)
    row.changeText:SetPoint("LEFT", row, "LEFT", 362, 0)
    row.changeText:SetJustifyH("LEFT")

    row:SetScript("OnClick", function()
      logSelectedIndex = this._index
      UpdateLogRows()
    end)
    row:Hide()
    table.insert(logRows, row)
  end

  logScrollUp = MakeBtn(f, "^", 16, 20)
  logScrollUp:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -56)
  logScrollUp:SetScript("OnClick", function()
    logScrollOffset = logScrollOffset - 1
    UpdateLogRows()
  end)

  logScrollDown = MakeBtn(f, "v", 16, 20)
  logScrollDown:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -(56 + LOG_MAX_ROWS * LOG_ROW_H - 20))
  logScrollDown:SetScript("OnClick", function()
    logScrollOffset = logScrollOffset + 1
    UpdateLogRows()
  end)

  local detailBg = CreateFrame("Frame", nil, f)
  detailBg:SetWidth(LOG_W - 20)
  detailBg:SetHeight(120)
  detailBg:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 34)
  MakeBackdrop(detailBg, 0.04, 0.04, 0.04, 0.75)

  local detailTitle = detailBg:CreateFontString(nil, "OVERLAY")
  detailTitle:SetFont(FONT, FS, "OUTLINE")
  detailTitle:SetPoint("TOPLEFT", detailBg, "TOPLEFT", 8, -6)
  detailTitle:SetTextColor(0.9, 0.75, 0.1, 1)
  detailTitle:SetText("Details")

  logDetailText = detailBg:CreateFontString(nil, "OVERLAY")
  logDetailText:SetFont(FONT, FS, "")
  logDetailText:SetPoint("TOPLEFT", detailBg, "TOPLEFT", 8, -24)
  logDetailText:SetWidth(LOG_W - 36)
  logDetailText:SetJustifyH("LEFT")
  logDetailText:SetJustifyV("TOP")
  logDetailText:SetText("|cFF888888Select a log entry to inspect details.|r")

  local exportBtn = MakeBtn(f, "Export", 80, 20)
  exportBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 10)
  exportBtn:SetScript("OnClick", function() ShowExportWindow() end)

  local clearBtn = MakeBtn(f, "Clear", 80, 20)
  clearBtn:SetPoint("LEFT", exportBtn, "RIGHT", 6, 0)
  clearBtn:SetScript("OnClick", function() StaticPopup_Show("BRP_CONFIRM_CLEAR_LOGS") end)

  local refreshBtn = MakeBtn(f, "Refresh", 80, 20)
  refreshBtn:SetPoint("LEFT", clearBtn, "RIGHT", 6, 0)
  refreshBtn:SetScript("OnClick", function() UpdateLogRows() end)

  local oldUpdate = UpdateLogRows
  UpdateLogRows = function()
    oldUpdate()
    RefreshCount()
  end

  f:Hide()
  return f
end

local function ApplyItemToFrames()
  if not st.item then return end
  local itemName, _, itemQuality, _, _, _, _, _, itemIcon = GetItemInfo(st.item)
  if not itemName then return end

  local r, g, b, hex = GetItemQualityColor(itemQuality or 1)
  local colored = string.format("%s%s|r", hex, itemName)
  st.itemName = itemName

  if mlItemIcon     then mlItemIcon:SetTexture(itemIcon) end
  if mlItemIconBtn  then mlItemIconBtn:SetNormalTexture(itemIcon) end
  if mlItemNameText then mlItemNameText:SetText(colored) end
end

local itemQueryTimer  = 0
local itemQueryTries  = 0
local MAX_QUERY_TRIES = 8

local function StartItemQuery()
  itemQueryTimer = 0
  itemQueryTries = 0
end

-- ── Open loot windows on /rw ──────────────────────────────────────────────────
local function OpenLootWindows(itemLink, fullLink)
  st.item     = itemLink
  st.itemFull = fullLink
  st.itemName = nil
  st.elapsed  = 0
  st.rolling  = true
  ResetBids()
  StartItemQuery()
  ApplyItemToFrames()

  if PlayerIsML() then
    if mlFrame then
      UpdateTableButtons()
      UpdateMLRows()
      mlFrame:Show()
    end
  end
end

-- ── Delay frame (ML request + item query) ────────────────────────────────────
local delayFrame = CreateFrame("Frame")
delayFrame:SetScript("OnUpdate", function()
  local dt = arg1

  -- ML request delay
  if st.pendReq then
    st.reqDelay = st.reqDelay - dt
    if st.reqDelay <= 0 then
      st.pendReq = false
      local ch = GetNumRaidMembers() > 0 and "RAID" or "PARTY"
      SendAddonMessage(MSG.PREFIX, MSG.DATA, ch)
    end
  end

  -- ML set delay (debounce)
  if st.pendSet then
    st.setDelay = st.setDelay - dt
    if st.setDelay <= 0 then
      st.pendSet = false
      if not st.ml or st.ml ~= st.setName then
        Pr("Master Looter: |cFF00FF00"..st.setName.."|r")
      end
      st.ml = st.setName
    end
  end

  -- Item info retry
  if st.item and st.itemName == nil then
    itemQueryTimer = itemQueryTimer - dt
    if itemQueryTimer <= 0 and itemQueryTries < MAX_QUERY_TRIES then
      itemQueryTimer = 0.5
      itemQueryTries = itemQueryTries + 1
      ApplyItemToFrames()
    end
  end
end)

-- ── Event handlers ────────────────────────────────────────────────────────────
local evFrame = CreateFrame("Frame")

evFrame:RegisterEvent("ADDON_LOADED")
evFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
evFrame:RegisterEvent("CHAT_MSG_RAID_WARNING")
evFrame:RegisterEvent("CHAT_MSG_WHISPER")
evFrame:RegisterEvent("CHAT_MSG_SYSTEM")
evFrame:RegisterEvent("CHAT_MSG_ADDON")
evFrame:RegisterEvent("CHAT_MSG_LOOT")
evFrame:RegisterEvent("RAID_ROSTER_UPDATE")
evFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
evFrame:RegisterEvent("PARTY_LOOT_METHOD_CHANGED")
evFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

evFrame:SetScript("OnEvent", function()
  local e = event

  if e == "ADDON_LOADED" then
    if arg1 ~= "BRPMaster" then return end
    EnsureDB()
    -- Restore saved settings
    if not BRPMasterDB then BRPMasterDB = {} end
    if BRPMasterDB.activeTable     then st.activeTable      = BRPMasterDB.activeTable     end
    if BRPMasterDB.duration        then st.duration         = BRPMasterDB.duration        end
    if BRPMasterDB.announceChannel then st.announceChannel  = BRPMasterDB.announceChannel end
    if BRPMasterDB.defaultDecay    then st.defaultDecay     = BRPMasterDB.defaultDecay    end
    -- Build UI
    mlFrame        = CreateMLFrame()
    playerMgrFrame = CreatePlayerMgrFrame()
    logViewerFrame = CreateLogViewerFrame()
    logExportFrame = CreateLogExportFrame()
    standingsExportFrame = CreateStandingsExportFrame()
    tinsert(UISpecialFrames, "BRPMasterMLFrame")
    tinsert(UISpecialFrames, "BRPMasterPMGRFrame")
    tinsert(UISpecialFrames, "BRPMasterLogViewerFrame")
    tinsert(UISpecialFrames, "BRPMasterLogExportFrame")
    tinsert(UISpecialFrames, "BRPMasterStandingsExportFrame")
    CreateMinimapButton()
    -- Refresh cache after UI is built
    GuildRoster()
    Pr("Loaded. |cFFFFD100/brp help|r for commands.")

  elseif e == "GUILD_ROSTER_UPDATE" then
    BuildCache()
    if mlFrame        and mlFrame:IsVisible()        then UpdateMLRows()   end
    if playerMgrFrame and playerMgrFrame:IsVisible() then UpdatePMGRRows() end

  elseif e == "CHAT_MSG_RAID_WARNING" then
    local msg, sender = arg1, arg2
    if sender ~= st.ml then return end
    -- Ignore award announcements
    if string.find(msg, "wins ") or string.find(msg, "received ") then return end
    local bare = ExtractLinks(msg)
    local full = ExtractFullLinks(msg)
    if bare and table.getn(bare) == 1 then
      OpenLootWindows(bare[1], full[1])
    end

  elseif e == "CHAT_MSG_WHISPER" then
    -- Only ML collects bids
    if not PlayerIsML() then return end
    local msg, sender = arg1, arg2
    local _, _, numStr = string.find(msg, "^%s*(%d+)")
    local bidAmt = numStr and tonumber(numStr)
    if bidAmt then
      AddBid(sender, bidAmt)
      if mlFrame and mlFrame:IsVisible() then UpdateMLRows() end
    end

  elseif e == "CHAT_MSG_SYSTEM" then
    local _, _, newML = string.find(arg1, "(.+) is now the loot master")
    if newML then SendMLInfo(newML) end

  elseif e == "CHAT_MSG_LOOT" then
    -- Hide ML frame when item is looted
    if not mlFrame or not mlFrame:IsVisible() then return end
    if st.ml ~= UnitName("player") then return end
    local bare = ExtractLinks(arg1)
    if bare and table.getn(bare) == 1 and bare[1] == st.item then
      ResetBids()
      mlFrame:Hide()
    end

  elseif e == "CHAT_MSG_ADDON" then
    local prefix, msg, _, sender = arg1, arg2, arg3, arg4
    if prefix ~= MSG.PREFIX then return end
    local me = UnitName("player")

    if msg == MSG.DATA then
      SendMLInfo(GetMLName())

    elseif string.find(msg, MSG.SET_ML) then
      if GetLootMethod() ~= "master" then return end
      local _, _, name = string.find(msg, "ML set to (%S+)")
      if name then
        st.pendSet  = true
        st.setDelay = 0.5
        st.setName  = name
      end

    elseif string.find(msg, MSG.TIME) then
      local _, _, dur = string.find(msg, "Roll time set to (%d+)")
      if dur then st.duration = tonumber(dur) end

    elseif string.find(msg, MSG.TABLE) then
      local _, _, tbl = string.find(msg, "Table set to (%a+)")
      if tbl == "EP" or tbl == "GP" then
        st.activeTable = tbl
      end
    end

  elseif e == "RAID_ROSTER_UPDATE"        then ReqML(0.5)
  elseif e == "PARTY_MEMBERS_CHANGED"     then ReqML(0.5)
  elseif e == "PARTY_LOOT_METHOD_CHANGED" then ReqML(0.5)
  elseif e == "PLAYER_ENTERING_WORLD"     then ReqML(8)
  end
end)

-- ── Slash commands ────────────────────────────────────────────────────────────
local function HandleSlash(msg)
  msg = string.lower(string.gsub(msg or "", "^%s*(.-)%s*$", "%1"))

  -- /brp (no args) — toggle ML window if ML, else player window
  if msg == "" then
    if PlayerIsML() then
      if mlFrame then
        if mlFrame:IsVisible() then mlFrame:Hide() else mlFrame:Show() end
      end
    end
    return
  end

  -- /brp ep <amount>  or  /brp ep <name> <amount>
  if string.find(msg, "^ep ") then
    local rest = string.sub(msg, 4)
    local num = tonumber(rest)
    if num then
      -- award to raid
      AwardRaidEP(num, "EP")
    else
      local _, _, name, amt = string.find(rest, "^(%S+)%s+(-?%d+)$")
      if name and amt then
        -- capitalize name
        name = string.upper(string.sub(name,1,1))..string.sub(name,2)
        if ApplyDKPChange(name, "EP", tonumber(amt), { reason = "Manual slash adjust" }) then
          local sign = tonumber(amt) >= 0 and "+" or ""
          Pr(name.." "..TABLE_EP_NAME.." DKP "..sign..amt)
        end
      else
        Pr("Usage: /brp ep <amount>  or  /brp ep <name> <amount>")
      end
    end
    return
  end

  -- /brp gp <amount>  or  /brp gp <name> <amount>
  if string.find(msg, "^gp ") then
    local rest = string.sub(msg, 4)
    local num = tonumber(rest)
    if num then
      AwardRaidEP(num, "GP")
    else
      local _, _, name, amt = string.find(rest, "^(%S+)%s+(-?%d+)$")
      if name and amt then
        name = string.upper(string.sub(name,1,1))..string.sub(name,2)
        if ApplyDKPChange(name, "GP", tonumber(amt), { reason = "Manual slash adjust" }) then
          local sign = tonumber(amt) >= 0 and "+" or ""
          Pr(name.." "..TABLE_GP_NAME.." DKP "..sign..amt)
        end
      else
        Pr("Usage: /brp gp <amount>  or  /brp gp <name> <amount>")
      end
    end
    return
  end

  -- /brp decay <percent>   e.g. /brp decay 10  (10% decay = keep 90%)
  if string.find(msg, "^decay") then
    local _, _, pctStr = string.find(msg, "decay%s+(%d+)")
    local pct = tonumber(pctStr)
    if not pct or pct < 1 or pct > 99 then
      Pr("Usage: /brp decay <percent>  (e.g. /brp decay 10 = 10% decay)")
      return
    end
    DecayAll(1 - (pct / 100))
    return
  end

  -- /brp table naxx|kara
  if string.find(msg, "^table ") then
    local _, _, tbl = string.find(msg, "table (%a+)")
    if tbl == "naxx" then
      st.activeTable = "EP"
      BRPMasterDB.activeTable = "EP"
      UpdateTableButtons()
      if mlFrame and mlFrame:IsVisible() then UpdateMLRows() end
      Pr("Active table: "..TABLE_EP_NAME.." (EP)")
    elseif tbl == "kara" then
      st.activeTable = "GP"
      BRPMasterDB.activeTable = "GP"
      UpdateTableButtons()
      if mlFrame and mlFrame:IsVisible() then UpdateMLRows() end
      Pr("Active table: "..TABLE_GP_NAME.." (GP)")
    else
      Pr("Usage: /brp table naxx  or  /brp table kara")
    end
    return
  end

  -- /brp time <seconds>
  if string.find(msg, "^time ") then
    local _, _, sec = string.find(msg, "time (%d+)")
    if sec then
      st.duration = tonumber(sec)
      BRPMasterDB.duration = st.duration
      Pr("Roll duration set to "..sec.."s.")
      if PlayerIsML() then
        local ch = GetNumRaidMembers() > 0 and "RAID" or "PARTY"
        SendAddonMessage(MSG.PREFIX, MSG.TIME..sec, ch)
      end
    end
    return
  end

  -- /brp dkp <name>  — show a player's current DKP
  if string.find(msg, "^dkp ") then
    local _, _, name = string.find(msg, "dkp (%S+)")
    if name then
      name = string.upper(string.sub(name,1,1))..string.sub(name,2)
      local m = cache[name]
      if m then
        Pr(string.format("%s [%s]  "..TABLE_EP_NAME..": %d  "..TABLE_GP_NAME..": %d",
          CC(name, m.class), m.rank, m.ep, m.gp))
      else
        Pr(name.." not found in guild cache. Try /brp refresh first.")
      end
    end
    return
  end

  -- /brp refresh — rebuild guild cache
  if msg == "refresh" then
    GuildRoster()
    Pr("Refreshing guild roster...")
    return
  end

  if msg == "log" then
    if logViewerFrame then
      if logViewerFrame:IsVisible() then logViewerFrame:Hide()
      else
        UpdateLogRows()
        logViewerFrame:Show()
      end
    end
    return
  end

  if msg == "log export" then
    ShowExportWindow()
    return
  end

  if msg == "log save" then
    SaveLogsExportToSavedVariables()
    return
  end

  if msg == "standings export" then
    ShowStandingsExportWindow()
    return
  end

  if msg == "standings save" then
    SaveStandingsExportToSavedVariables()
    return
  end

  if msg == "log clear" then
    StaticPopup_Show("BRP_CONFIRM_CLEAR_LOGS")
    return
  end

  -- /brp standings — dump DKP to chat
  if msg == "standings" then
    local list = BuildStandingsList()
    Pr("=== DKP Standings (by "..TABLE_EP_NAME.." DKP) ===")
    for _, m in ipairs(list) do
      if m.ep > 0 or m.gp > 0 then
        DEFAULT_CHAT_FRAME:AddMessage(string.format(
          "  %s [%s]  "..TABLE_EP_NAME..": %d  "..TABLE_GP_NAME..": %d",
          CC(m.name, m.class), m.rank, m.ep, m.gp))
      end
    end
    return
  end

  -- Help
  Pr("BRP Master commands:")
  DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFD100/brp log|r                  - open DKP log viewer")
  DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFD100/brp log export|r           - export DKP log")
  DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFD100/brp log save|r             - save full log JSON to SavedVariables")
  DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFD100/brp log clear|r            - clear DKP log")
  DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFD100/brp standings export|r     - export standings JSON")
  DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFD100/brp standings save|r       - save standings JSON to SavedVariables")
  DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFD100/brp|r                      — toggle loot window")
  DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFD100/brp table naxx|kara|r      — set active DKP table")
  DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFD100/brp ep <amt>|r             — award "..TABLE_EP_NAME.." DKP to raid")
  DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFD100/brp ep <name> <amt>|r      — award "..TABLE_EP_NAME.." DKP to player")
  DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFD100/brp gp <amt>|r             — award "..TABLE_GP_NAME.." DKP to raid")
  DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFD100/brp gp <name> <amt>|r      — award "..TABLE_GP_NAME.." DKP to player")
  DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFD100/brp decay <pct>|r          — apply % decay to all")
  DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFD100/brp dkp <name>|r           — show player DKP")
  DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFD100/brp standings|r            — dump standings to chat")
  DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFD100/brp time <sec>|r           — set roll window duration")
  DEFAULT_CHAT_FRAME:AddMessage("  |cFFFFD100/brp refresh|r              — rebuild guild cache")
end

-- ── Minimap button ────────────────────────────────────────────────────────────
function CreateMinimapButton()
  local radius = 78
  local angle  = BRPMasterDB.minimapAngle or 220

  local btn = CreateFrame("Button", "BRPMasterMinimapBtn", Minimap)
  btn:SetWidth(33)
  btn:SetHeight(33)
  btn:SetFrameStrata("MEDIUM")

  local icon = btn:CreateTexture(nil, "OVERLAY")
  icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
  icon:SetWidth(24)
  icon:SetHeight(24)
  icon:SetPoint("CENTER", 0, 0)

  local hl = btn:CreateTexture(nil, "HIGHLIGHT")
  hl:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  hl:SetAllPoints(btn)
  hl:SetBlendMode("ADD")

  local border = btn:CreateTexture(nil, "BACKGROUND")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetWidth(56)
  border:SetHeight(56)
  border:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)

  local function UpdatePos()
    btn:SetPoint("CENTER", Minimap, "CENTER",
      radius * math.cos(math.rad(angle)),
      radius * math.sin(math.rad(angle)))
  end
  UpdatePos()

  -- Dragging (left button)
  btn:RegisterForDrag("LeftButton")
  btn:SetScript("OnDragStart", function()
    btn:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local cx, cy = GetCursorPosition()
      local s = UIParent:GetScale()
      cx, cy = cx / s, cy / s
      angle = math.deg(math.atan2(cy - my, cx - mx))
      BRPMasterDB.minimapAngle = angle
      UpdatePos()
    end)
  end)
  btn:SetScript("OnDragStop", function()
    btn:SetScript("OnUpdate", nil)
  end)

  -- Dropdown menu (right-click)
  local ddMenu = CreateFrame("Frame", "BRPMasterDropDown", UIParent, "UIDropDownMenuTemplate")

  local function InitMenu()
    if UIDROPDOWNMENU_MENU_LEVEL == 2 then
      if UIDROPDOWNMENU_MENU_VALUE == "DECAY" then
        local pcts = {20, 15, 10, 5}
        for i = 1, table.getn(pcts) do
          local pct = pcts[i]
          UIDropDownMenu_AddButton({
            text = pct.."% decay" .. (pct == st.defaultDecay and " (default)" or ""),
            checked = (pct == st.defaultDecay),
            func = function()
              st.pendingDecay = pct
              StaticPopupDialogs["BRP_CONFIRM_DECAY"].text =
                "Apply "..pct.." percent decay to all members?"
              StaticPopup_Show("BRP_CONFIRM_DECAY")
            end,
          }, UIDROPDOWNMENU_MENU_LEVEL)
        end
      elseif UIDROPDOWNMENU_MENU_VALUE == "TABLE" then
        UIDropDownMenu_AddButton({
          text = TABLE_EP_NAME,
          checked = (st.activeTable == "EP"),
          func = function()
            st.activeTable = "EP"
            BRPMasterDB.activeTable = "EP"
            UpdateTableButtons()
            if mlFrame and mlFrame:IsVisible() then UpdateMLRows() end
          end,
        }, UIDROPDOWNMENU_MENU_LEVEL)
        UIDropDownMenu_AddButton({
          text = TABLE_GP_NAME,
          checked = (st.activeTable == "GP"),
          func = function()
            st.activeTable = "GP"
            BRPMasterDB.activeTable = "GP"
            UpdateTableButtons()
            if mlFrame and mlFrame:IsVisible() then UpdateMLRows() end
          end,
        }, UIDROPDOWNMENU_MENU_LEVEL)
      elseif UIDROPDOWNMENU_MENU_VALUE == "CHANNEL" then
        local channels = {"RAID_WARNING", "RAID", "GUILD", "PARTY", "SAY", "NONE"}
        local labels   = {"Raid Warning", "Raid", "Guild", "Party", "Say", "None (silent)"}
        for i = 1, table.getn(channels) do
          local ch = channels[i]
          local lbl = labels[i]
          UIDropDownMenu_AddButton({
            text = lbl,
            checked = (st.announceChannel == ch),
            func = function()
              st.announceChannel = ch
              BRPMasterDB.announceChannel = ch
              Pr("Announce channel: "..lbl)
            end,
          }, UIDROPDOWNMENU_MENU_LEVEL)
        end
      end
      return
    end

    UIDropDownMenu_AddButton({text="BRP Master", isTitle=true, notCheckable=1}, 1)
    UIDropDownMenu_AddButton({
      text="Award "..TABLE_EP_NAME.." DKP to Raid", notCheckable=1,
      func=function() StaticPopup_Show("BRP_EP_RAID") end,
    }, 1)
    UIDropDownMenu_AddButton({
      text="Award "..TABLE_GP_NAME.." DKP to Raid", notCheckable=1,
      func=function() StaticPopup_Show("BRP_GP_RAID") end,
    }, 1)
    UIDropDownMenu_AddButton({
      text="Manage Player DKP", notCheckable=1,
      func=function()
        if playerMgrFrame then
          if playerMgrFrame:IsVisible() then
            playerMgrFrame:Hide()
          else
            UpdatePMGRRows()
            playerMgrFrame:Show()
          end
        end
      end,
    }, 1)
    UIDropDownMenu_AddButton({
      text="View DKP Log", notCheckable=1,
      func=function()
        if logViewerFrame then
          if logViewerFrame:IsVisible() then logViewerFrame:Hide()
          else
            UpdateLogRows()
            logViewerFrame:Show()
          end
        end
      end,
    }, 1)
    UIDropDownMenu_AddButton({
      text="Decay DKP", hasArrow=true, value="DECAY", notCheckable=1,
    }, 1)
    UIDropDownMenu_AddButton({
      text="Active Table", hasArrow=true, value="TABLE", notCheckable=1,
    }, 1)
    UIDropDownMenu_AddButton({
      text="Announce Channel", hasArrow=true, value="CHANNEL", notCheckable=1,
    }, 1)
    UIDropDownMenu_AddButton({
      text="Export Standings", notCheckable=1,
      func=function() HandleSlash("standings export") end,
    }, 1)
    UIDropDownMenu_AddButton({
      text="Refresh Cache", notCheckable=1,
      func=function() GuildRoster() Pr("Refreshing...") end,
    }, 1)
    UIDropDownMenu_AddButton({
      text="Close", notCheckable=1,
      func=function() CloseDropDownMenus() end,
    }, 1)
  end

  UIDropDownMenu_Initialize(ddMenu, InitMenu, "MENU")

  -- Left click: toggle window; Right click: menu
  btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  btn:SetScript("OnClick", function()
    if arg1 == "RightButton" then
      ToggleDropDownMenu(1, nil, ddMenu, btn, 0, 0)
    else
      if playerMgrFrame:IsVisible() then
        playerMgrFrame:Hide()
      else
        UpdatePMGRRows()
        playerMgrFrame:Show()
      end
    end
  end)

  btn:SetScript("OnEnter", function()
    GameTooltip:SetOwner(btn, "ANCHOR_LEFT")
    GameTooltip:SetText("|cFFFFD100BRP Master|r")
    GameTooltip:AddLine("Left-click: toggle DKP window", 1, 1, 1)
    GameTooltip:AddLine("Right-click: management menu", 1, 1, 1)
    GameTooltip:AddLine("Left-drag: reposition button", 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)

  return btn
end

SLASH_BRPMASTER1 = "/brp"
SLASH_BRPMASTER2 = "/brpmaster"
SlashCmdList["BRPMASTER"] = HandleSlash
