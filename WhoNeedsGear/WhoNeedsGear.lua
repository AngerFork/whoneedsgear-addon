-- Who Needs Gear? exporter. Produces: !WNG:1:{json}
local ADDON = ...
local PREFIX = "|cffffd100Who Needs Gear?|r "

local SLOTS = {
  { 1, "HEAD" }, { 2, "NECK" }, { 3, "SHOULDER" }, { 15, "BACK" }, { 5, "CHEST" },
  { 9, "WRIST" }, { 10, "HANDS" }, { 6, "WAIST" }, { 7, "LEGS" }, { 8, "FEET" },
  { 11, "FINGER_1" }, { 12, "FINGER_2" }, { 13, "TRINKET_1" }, { 14, "TRINKET_2" },
  { 16, "MAIN_HAND" }, { 17, "OFF_HAND" },
}
local SLOT_KEY = {}
for _, s in ipairs(SLOTS) do SLOT_KEY[s[1]] = s[2] end

-- Enum.InventoryType -> equipment slot ids it can go into
local INVTYPE_SLOTS = {
  [1] = { 1 }, [2] = { 2 }, [3] = { 3 }, [5] = { 5 }, [20] = { 5 }, [6] = { 6 }, [7] = { 7 },
  [8] = { 8 }, [9] = { 9 }, [10] = { 10 }, [11] = { 11, 12 }, [12] = { 13, 14 }, [16] = { 15 },
  [13] = { 16, 17 }, [21] = { 16 }, [17] = { 16 }, [15] = { 16 }, [26] = { 16 },
  [22] = { 17 }, [14] = { 17 }, [23] = { 17 },
}

local DB
local gearChanged = false

---------------------------------------------------------------- helpers
local function jsonString(s)
  s = tostring(s or "")
  s = s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', ' '):gsub('\r', ''):gsub('\t', ' ')
  s = s:gsub('[%z\1-\31]', '')
  return '"' .. s .. '"'
end

local function stripColors(t)
  if not t then return nil end
  return (t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|A.-|a", ""):gsub("|T.-|t", ""))
end

local function itemName(link)
  if not link then return nil end
  local name = C_Item.GetItemInfo(link)
  return name or link:match("%[(.-)%]")
end

local function charKey() return (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?") end

local ENCHANT_PREFIX = (ENCHANTED_TOOLTIP_LINE or "Enchanted: %s"):match("^(.-)%%s") or "Enchanted: "
local UPGRADE_PREFIX = (ITEM_UPGRADE_TOOLTIP_FORMAT_STRING or "Upgrade Level: %s %d/%d"):match("^(.-)%%") or "Upgrade Level: "

local function startsWith(s, p) return s and p ~= "" and s:sub(1, #p) == p end

-- Reads enchant + upgrade track from the item tooltip
local function tooltipDetails(slot)
  local enchant, track, upgrade
  local data = C_TooltipInfo and C_TooltipInfo.GetInventoryItem("player", slot)
  if data and data.lines then
    for _, line in ipairs(data.lines) do
      local text = stripColors(line.leftText)
      if text then
        if not enchant and startsWith(text, ENCHANT_PREFIX) then
          enchant = text:sub(#ENCHANT_PREFIX + 1)
        elseif not track and startsWith(text, UPGRADE_PREFIX) then
          local rest = text:sub(#UPGRADE_PREFIX + 1)
          local t, a, b = rest:match("^(.-)%s+(%d+)/(%d+)")
          if t then track, upgrade = t, a .. "/" .. b end
        end
      end
    end
  end
  return enchant, track, upgrade
end

local function gemsAndSockets(link)
  local gems = {}
  for i = 1, 4 do
    local g = C_Item.GetItemGem(link, i)
    if g then gems[#gems + 1] = g end
  end
  local sockets = 0
  local stats = C_Item.GetItemStats(link)
  if stats then
    for k, v in pairs(stats) do
      if type(k) == "string" and k:find("^EMPTY_SOCKET_") then sockets = sockets + (tonumber(v) or 0) end
    end
  end
  if sockets < #gems then sockets = #gems end
  return gems, sockets
end

local function equippedIlvl(slot)
  local loc = ItemLocation:CreateFromEquipmentSlot(slot)
  if loc and C_Item.DoesItemExist(loc) then return C_Item.GetCurrentItemLevel(loc) or 0 end
  return 0
end

---------------------------------------------------------------- bag upgrades
local function playerArmorSubclass()
  local link = GetInventoryItemLink("player", 5)
  if not link then return nil end
  local _, _, _, _, _, classID, subclassID = C_Item.GetItemInfoInstant(link)
  if classID == 4 and subclassID and subclassID >= 1 and subclassID <= 4 then return subclassID end
end

-- True when a two-handed (or ranged) weapon fills both hands, so off-hands and
-- one-handers can't be used alongside it. Titan's Grip (2H in the off-hand slot) is excluded.
local OFFHAND_ONLY = { [22] = true, [14] = true, [23] = true, [13] = true }
local function usingTwoHander()
  local loc = ItemLocation:CreateFromEquipmentSlot(16)
  if not (loc and C_Item.DoesItemExist(loc)) then return false end
  local t = C_Item.GetItemInventoryType(loc)
  if not (t == 17 or t == 15 or t == 26) then return false end
  return not GetInventoryItemLink("player", 17)
end

local function scanBagUpgrades()
  local out = {}
  local armorSub = playerArmorSubclass()
  local twoHander = usingTwoHander()
  for bag = 0, 4 do
    for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
      local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
      if C_Item.DoesItemExist(loc) then
        local invType = C_Item.GetItemInventoryType(loc)
        local targets = invType and INVTYPE_SLOTS[invType]
        local itemID = C_Item.GetItemID(loc)
        if twoHander and invType and OFFHAND_ONLY[invType] then targets = nil end
        if targets and itemID and C_PlayerInfo.CanUseItem(itemID) then
          local _, _, _, _, _, classID, subclassID = C_Item.GetItemInfoInstant(itemID)
          local armorOk = not (classID == 4 and subclassID and subclassID >= 1 and subclassID <= 4 and armorSub and subclassID ~= armorSub)
          if armorOk then
            local ilvl = C_Item.GetCurrentItemLevel(loc) or 0
            local weakest, weakestIlvl
            for _, t in ipairs(targets) do
              local e = equippedIlvl(t)
              if not weakestIlvl or e < weakestIlvl then weakest, weakestIlvl = t, e end
            end
            if weakest and ilvl > weakestIlvl then
              local link = C_Item.GetItemLink(loc)
              out[#out + 1] = {
                slot = SLOT_KEY[weakest], name = itemName(link) or "Unknown", ilvl = ilvl,
                quality = C_Item.GetItemQuality(loc) or 1, equipped = weakestIlvl, gain = ilvl - weakestIlvl,
              }
            end
          end
        end
      end
    end
  end
  table.sort(out, function(a, b) return a.gain > b.gain end)
  while #out > 30 do table.remove(out) end
  return out
end

---------------------------------------------------------------- export
local function buildExport()
  local _, equipped = GetAverageItemLevel()
  local gear, setCounts = {}, {}

  for _, s in ipairs(SLOTS) do
    local id, key = s[1], s[2]
    local link = GetInventoryItemLink("player", id)
    if link then
      local quality = GetInventoryItemQuality("player", id) or 1
      local enchant, track, upgrade = tooltipDetails(id)
      local gems, sockets = gemsAndSockets(link)
      local gemParts = {}
      for i, g in ipairs(gems) do gemParts[i] = jsonString(g) end
      local fields = {
        '"slot":' .. jsonString(key),
        '"name":' .. jsonString(itemName(link) or "Unknown"),
        '"ilvl":' .. equippedIlvl(id),
        '"quality":' .. quality,
        '"sockets":' .. sockets,
        '"gems":[' .. table.concat(gemParts, ",") .. ']',
      }
      if enchant then fields[#fields + 1] = '"enchant":' .. jsonString(enchant) end
      if track then
        fields[#fields + 1] = '"track":' .. jsonString(track)
        fields[#fields + 1] = '"upgrade":' .. jsonString(upgrade)
      end
      gear[#gear + 1] = "{" .. table.concat(fields, ",") .. "}"
      local setID = select(16, C_Item.GetItemInfo(link))
      if setID and setID > 0 then setCounts[setID] = (setCounts[setID] or 0) + 1 end
    end
  end
  if #gear == 0 then return nil end

  local bestSet, bestCount = nil, 0
  for setID, c in pairs(setCounts) do
    if c > bestCount then bestSet, bestCount = setID, c end
  end
  local tierName = bestSet and C_Item.GetItemSetInfo and C_Item.GetItemSetInfo(bestSet) or nil

  local bags = {}
  for i, b in ipairs(scanBagUpgrades()) do
    bags[i] = string.format('{"slot":%s,"name":%s,"ilvl":%d,"quality":%d,"equipped":%d}',
      jsonString(b.slot), jsonString(b.name), b.ilvl, b.quality, b.equipped)
  end

  local parts = {
    '"name":' .. jsonString(UnitName("player")),
    '"realm":' .. jsonString(GetRealmName()),
    '"exportedAt":' .. tostring(GetServerTime()),
    '"ilvl":' .. string.format("%.2f", equipped or 0),
    '"tierPieces":' .. tostring(math.min(bestCount, 5)),
  }
  if tierName then parts[#parts + 1] = '"tierName":' .. jsonString(tierName) end
  parts[#parts + 1] = '"gear":[' .. table.concat(gear, ",") .. ']'
  parts[#parts + 1] = '"bagUpgrades":[' .. table.concat(bags, ",") .. ']'
  return "!WNG:1:{" .. table.concat(parts, ",") .. "}"
end

---------------------------------------------------------------- copy window
local frame
local function showExport(text, title)
  if not frame then
    frame = CreateFrame("Frame", "WhoNeedsGearExportFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(520, 260)
    frame:SetPoint("CENTER")
    frame:SetMovable(true); frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetFrameStrata("DIALOG")
    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.title:SetPoint("TOP", 0, -5)
    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -32); scroll:SetPoint("BOTTOMRIGHT", -32, 12)
    local eb = CreateFrame("EditBox", nil, scroll)
    eb:SetMultiLine(true); eb:SetAutoFocus(true); eb:SetFontObject(ChatFontNormal)
    eb:SetWidth(460)
    eb:SetScript("OnEscapePressed", function() frame:Hide() end)
    eb:SetScript("OnTextChanged", function(self, user) if user then self:SetText(frame.text); self:HighlightText() end end)
    eb:SetScript("OnKeyUp", function(_, key)
      if key == "C" and IsControlKeyDown() then frame:Hide(); print(PREFIX .. "Copied! Paste it into Addon Import on whoneedsgear.info") end
    end)
    scroll:SetScrollChild(eb)
    frame.eb = eb
    tinsert(UISpecialFrames, "WhoNeedsGearExportFrame")
  end
  frame.title:SetText(title or "Who Needs Gear? - press Ctrl+C to copy")
  frame.text = text
  frame:Show()
  frame.eb:SetText(text)
  frame.eb:HighlightText()
  frame.eb:SetFocus()
end

local function charRecord()
  DB.chars[charKey()] = DB.chars[charKey()] or {}
  return DB.chars[charKey()]
end

local function doExport()
  local text = buildExport()
  if not text then print(PREFIX .. "No equipped gear found.") return end
  local rec = charRecord()
  rec.last, rec.lastAt, rec.exportedAt = text, GetServerTime(), GetServerTime()
  gearChanged = false
  showExport(text)
end

local function exportSoon()
  for _, s in ipairs(SLOTS) do
    local link = GetInventoryItemLink("player", s[1])
    if link then C_Item.RequestLoadItemDataByID(link) end
  end
  C_Timer.After(0.3, doExport)
end

local function ago(ts)
  local d = GetServerTime() - ts
  if d < 3600 then return math.floor(d / 60) .. "m ago" end
  if d < 86400 then return math.floor(d / 3600) .. "h ago" end
  return math.floor(d / 86400) .. "d ago"
end

---------------------------------------------------------------- minimap button
local mm
local function placeMinimap()
  local a = math.rad(DB.minimapAngle or 220)
  mm:ClearAllPoints()
  mm:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * 105, math.sin(a) * 105)
end

local function createMinimap()
  mm = CreateFrame("Button", "WhoNeedsGearMinimapButton", Minimap)
  mm:SetSize(31, 31); mm:SetFrameStrata("MEDIUM"); mm:SetFrameLevel(8)
  mm:RegisterForClicks("LeftButtonUp", "RightButtonUp"); mm:RegisterForDrag("LeftButton")
  mm:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  local icon = mm:CreateTexture(nil, "BACKGROUND")
  icon:SetTexture("Interface\\Icons\\INV_Chest_Chain_15"); icon:SetSize(20, 20); icon:SetPoint("CENTER")
  local border = mm:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder"); border:SetSize(53, 53); border:SetPoint("TOPLEFT")
  mm:SetScript("OnClick", function(_, btn)
    if btn == "RightButton" then
      local rec = charRecord()
      if rec.last then showExport(rec.last, "Last export (" .. ago(rec.lastAt) .. ") - Ctrl+C to copy")
      else print(PREFIX .. "No saved export for this character yet.") end
    else
      exportSoon()
    end
  end)
  mm:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local cx, cy = GetCursorPosition()
      local s = Minimap:GetEffectiveScale()
      DB.minimapAngle = math.deg(math.atan2(cy / s - my, cx / s - mx))
      placeMinimap()
    end)
  end)
  mm:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  mm:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Who Needs Gear?")
    local rec = charRecord()
    GameTooltip:AddLine(rec.exportedAt and ("Last export: " .. ago(rec.exportedAt)) or "Not exported yet", 1, 1, 1)
    if gearChanged then GameTooltip:AddLine("Gear changed since last export", 1, 0.4, 0.4) end
    GameTooltip:AddLine("Left-click: export   Right-click: last export", 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
  mm:SetScript("OnLeave", function() GameTooltip:Hide() end)
  placeMinimap()
  mm:SetShown(not DB.hideMinimap)
end

---------------------------------------------------------------- events
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
ev:RegisterEvent("PLAYER_LOGOUT")
ev:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON then
    WhoNeedsGearDB = WhoNeedsGearDB or {}
    DB = WhoNeedsGearDB
    DB.chars = DB.chars or {}
    if DB.remindDays == nil then DB.remindDays = 3 end
    createMinimap()
  elseif event == "PLAYER_ENTERING_WORLD" and arg1 then -- initial login
    C_Timer.After(5, function()
      local rec = charRecord()
      local days = DB.remindDays or 0
      if days > 0 then
        if not rec.exportedAt then
          print(PREFIX .. "This character hasn't been exported yet. Type /wng export.")
        elseif GetServerTime() - rec.exportedAt > days * 86400 then
          print(PREFIX .. "Last gear export was " .. ago(rec.exportedAt) .. ". Type /wng export to refresh.")
        end
      end
    end)
  elseif event == "PLAYER_EQUIPMENT_CHANGED" then
    gearChanged = true
  elseif event == "PLAYER_LOGOUT" then
    -- keep a fresh snapshot so /wng last works next session
    local ok, text = pcall(buildExport)
    if ok and text and DB then
      local rec = charRecord()
      rec.last, rec.lastAt = text, GetServerTime()
    end
  end
end)

---------------------------------------------------------------- slash
SLASH_WHONEEDSGEAR1 = "/wng"
SlashCmdList.WHONEEDSGEAR = function(msg)
  local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
  if cmd == "" or cmd == "export" then
    exportSoon()
  elseif cmd == "last" then
    local rec = charRecord()
    if rec.last then showExport(rec.last, "Last export (" .. ago(rec.lastAt) .. ") - Ctrl+C to copy")
    else print(PREFIX .. "No saved export for this character yet.") end
  elseif cmd == "minimap" then
    DB.hideMinimap = not DB.hideMinimap
    mm:SetShown(not DB.hideMinimap)
    print(PREFIX .. "Minimap button " .. (DB.hideMinimap and "hidden" or "shown") .. ".")
  elseif cmd == "remind" then
    local n = tonumber(arg)
    if n and n >= 0 then
      DB.remindDays = math.floor(n)
      print(PREFIX .. (n == 0 and "Export reminders off." or ("Reminding when exports are older than " .. DB.remindDays .. " days.")))
    else
      print(PREFIX .. "Usage: /wng remind <days>  (0 turns it off)")
    end
  elseif cmd == "upgrades" then
    local list = scanBagUpgrades()
    if #list == 0 then print(PREFIX .. "No upgrades found in your bags.") end
    for _, b in ipairs(list) do
      print(PREFIX .. string.format("%s: %s  %d -> %d (+%d)", b.slot, b.name, b.equipped, b.ilvl, b.gain))
    end
  else
    print(PREFIX .. "Commands: /wng export, /wng last, /wng upgrades, /wng minimap, /wng remind <days>")
  end
end
