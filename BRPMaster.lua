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

-- ── Guild cache ─────────────────────────────────────────────────────────────
local function BuildCache()
  cache = {}
  local n = GetNumGuildMembers()
  if not n then return end
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

-- ── EPGP modification ───────────────────────────────────────────────────────
local function DeductDKP(name, amount)
  local m = cache[name]
  if not m then Pr("Cannot find "..name.." in guild."); return false end
  if st.activeTable == "EP" then
    m.ep = math.max(0, m.ep - amount)
  else
    m.gp = math.max(0, m.gp - amount)
  end
  m.note = WriteNote(m.note, m.ep, m.gp)
  GuildRosterSetOfficerNote(m.gIdx, m.note)
  return true
end

local function ModifyEP(name, delta)
  local m = cache[name]; if not m then Pr("Not found: "..name); return end
  m.ep = math.max(0, m.ep + delta)
  m.note = WriteNote(m.note, m.ep, m.gp)
  GuildRosterSetOfficerNote(m.gIdx, m.note)
end

local function ModifyGP(name, delta)
  local m = cache[name]; if not m then Pr("Not found: "..name); return end
  m.gp = math.max(0, m.gp + delta)
  m.note = WriteNote(m.note, m.ep, m.gp)
  GuildRosterSetOfficerNote(m.gIdx, m.note)
end

local function AwardRaidEP(amount, whichTable)
  local count = 0
  for i = 1, GetNumRaidMembers() do
    local name = GetRaidRosterInfo(i)
    if name and cache[name] then
      if whichTable == "EP" then ModifyEP(name, amount)
      else ModifyGP(name, amount) end
      count = count + 1
    end
  end
  local tName = (whichTable == "EP") and TABLE_EP_NAME or TABLE_GP_NAME
  Pr(string.format("Awarded %d %s DKP to %d raid members.", amount, tName, count))
  local ch = GetNumRaidMembers() > 0 and "RAID" or "SAY"
  SendChatMessage(string.format("[BRP] %d %s DKP awarded to raid.", amount, tName), ch)
end

local function DecayAll(factor)
  -- factor = fraction to KEEP, e.g. 0.8 = 20% decay
  local count = 0
  for name, m in pairs(cache) do
    if m.ep > 0 or m.gp > 0 then
      local newEp = math.max(0, math.floor(m.ep * factor + 0.5))
      local newGp = math.max(0, math.floor(m.gp * factor + 0.5))
      -- Values below 5 after decay are eliminated to 0
      if newEp < 5 then newEp = 0 end
      if newGp < 5 then newGp = 0 end
      local newNote = WriteNote(m.note, newEp, newGp)
      GuildRosterSetOfficerNote(m.gIdx, newNote)
      m.ep   = newEp
      m.gp   = newGp
      m.note = newNote
      count  = count + 1
    end
  end
  local pct = math.floor((1 - factor) * 100 + 0.5)
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
  if not DeductDKP(winnerName, cost) then return end
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
  OnAccept = function()
    local amt = tonumber(PopupGetText(this))
    if amt and amt ~= 0 then AwardRaidEP(amt, "EP") end
  end,
  EditBoxOnEnterPressed = function()
    local amt = tonumber(this:GetText())
    if amt and amt ~= 0 then AwardRaidEP(amt, "EP") end
    StaticPopup_Hide("BRP_EP_RAID")
  end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs["BRP_GP_RAID"] = {
  text = "Award "..TABLE_GP_NAME.." DKP to raid:\n(enter amount)",
  button1 = "Award", button2 = "Cancel",
  hasEditBox = true,
  OnAccept = function()
    local amt = tonumber(PopupGetText(this))
    if amt and amt ~= 0 then AwardRaidEP(amt, "GP") end
  end,
  EditBoxOnEnterPressed = function()
    local amt = tonumber(this:GetText())
    if amt and amt ~= 0 then AwardRaidEP(amt, "GP") end
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
      ModifyEP(name, tonumber(amt))
      Pr(name.." "..TABLE_EP_NAME.." DKP "..(tonumber(amt) >= 0 and "+" or "")..amt)
    else
      Pr("Format: Name Amount  (e.g. Eggorkus 100)")
    end
  end,
  EditBoxOnEnterPressed = function()
    local txt = this:GetText()
    local _, _, name, amt = string.find(txt, "^(%S+)%s+(-?%d+)$")
    if name and amt then
      name = string.upper(string.sub(name,1,1))..string.sub(name,2)
      ModifyEP(name, tonumber(amt))
      Pr(name.." "..TABLE_EP_NAME.." DKP "..(tonumber(amt) >= 0 and "+" or "")..amt)
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
      ModifyGP(name, tonumber(amt))
      Pr(name.." "..TABLE_GP_NAME.." DKP "..(tonumber(amt) >= 0 and "+" or "")..amt)
    else
      Pr("Format: Name Amount  (e.g. Eggorkus 100)")
    end
  end,
  EditBoxOnEnterPressed = function()
    local txt = this:GetText()
    local _, _, name, amt = string.find(txt, "^(%S+)%s+(-?%d+)$")
    if name and amt then
      name = string.upper(string.sub(name,1,1))..string.sub(name,2)
      ModifyGP(name, tonumber(amt))
      Pr(name.." "..TABLE_GP_NAME.." DKP "..(tonumber(amt) >= 0 and "+" or "")..amt)
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
local PMGR_FOOTER_H = 96
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
    if isEP then ModifyEP(pmgrSelectedName, amt)
    else         ModifyGP(pmgrSelectedName, amt) end
    Pr(pmgrSelectedName.." "..tName.." "..sign_s..amt)
    Announce(string.format("[BRP] %s %s DKP %s%d", pmgrSelectedName, tName, sign_s, amt))
    UpdatePMGRRows()
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

  f:Hide()
  return f
end

-- ── Item display ──────────────────────────────────────────────────────────────
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
    -- Restore saved settings
    if not BRPMasterDB then BRPMasterDB = {} end
    if BRPMasterDB.activeTable     then st.activeTable      = BRPMasterDB.activeTable     end
    if BRPMasterDB.duration        then st.duration         = BRPMasterDB.duration        end
    if BRPMasterDB.announceChannel then st.announceChannel  = BRPMasterDB.announceChannel end
    if BRPMasterDB.defaultDecay    then st.defaultDecay     = BRPMasterDB.defaultDecay    end
    -- Build UI
    mlFrame        = CreateMLFrame()
    playerMgrFrame = CreatePlayerMgrFrame()
    tinsert(UISpecialFrames, "BRPMasterMLFrame")
    tinsert(UISpecialFrames, "BRPMasterPMGRFrame")
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
        ModifyEP(name, tonumber(amt))
        local sign = tonumber(amt) >= 0 and "+" or ""
        Pr(name.." "..TABLE_EP_NAME.." DKP "..sign..amt)
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
        ModifyGP(name, tonumber(amt))
        local sign = tonumber(amt) >= 0 and "+" or ""
        Pr(name.." "..TABLE_GP_NAME.." DKP "..sign..amt)
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

  -- /brp standings — dump DKP to chat
  if msg == "standings" then
    local list = {}
    for name, m in pairs(cache) do
      table.insert(list, m)
      list[table.getn(list)].name = name
    end
    table.sort(list, function(a,b) return a.ep > b.ep end)
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
      text="Decay DKP", hasArrow=true, value="DECAY", notCheckable=1,
    }, 1)
    UIDropDownMenu_AddButton({
      text="Active Table", hasArrow=true, value="TABLE", notCheckable=1,
    }, 1)
    UIDropDownMenu_AddButton({
      text="Announce Channel", hasArrow=true, value="CHANNEL", notCheckable=1,
    }, 1)
    UIDropDownMenu_AddButton({
      text="Standings to Chat", notCheckable=1,
      func=function() HandleSlash("standings") end,
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
