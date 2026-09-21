-- TNS|GPS Homer|TNE
-- =====================================================================
-- GPSHOMER.lua  --  EdgeTX Tools Script for GPS Homer configuration
-- =====================================================================
-- SD card path: /SCRIPTS/TOOLS/GPSHOMER.lua
-- Writes the optional shared config /SCRIPTS/GPSHOMER/config.lua that core.lua
-- overlays at runtime. The config is OPTIONAL: without it the hard-coded
-- defaults in core.lua stay in force.
-- =====================================================================
-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 Mariator-pro
--
-- This program is free software; you can redistribute it and/or modify
-- it under the terms of the GNU General Public License version 2 as
-- published by the Free Software Foundation.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
-- =====================================================================

local CORE_PATH = "/SCRIPTS/GPSHOMER/core.lua"

-- ---------------------------------------------------------------------------
-- Shared core module (read-only here): the editable range, defaults, sound
-- folder, config path and schema all live in core, so the on-radio editor can
-- never drift from what core actually enforces. core is MANDATORY -- without
-- it the editor has no schema to write against, so it shows a hint and exits
-- instead of writing a config against guessed values.
-- ---------------------------------------------------------------------------
local core
do
  local chunk = loadScript and loadScript(CORE_PATH)
  if chunk then
    local ok, mod = pcall(chunk)
    if ok then core = mod end
  end
end
if not core then
  local function run(event)
    lcd.clear()
    lcd.drawText(10, 10, "GPS Homer: core.lua missing", COLOR_THEME_PRIMARY1 or 0)
    lcd.drawText(10, 40, "Install " .. CORE_PATH, COLOR_THEME_PRIMARY1 or 0)
    if event and event ~= 0 then return 1 end   -- any key closes the tool
    return 0
  end
  return { init = function() end, run = run }
end

local VERSION        = core.VERSION
local SCHEMA_VERSION = core.CONFIG_SCHEMA_VERSION
local LIMITS         = core.LIMITS
local PATHS = {
  config    = core.CONFIG_PATH,
  soundDir  = core.SOUND_DIR,                          -- trailing slash: prefix for playFile
  soundList = string.gsub(core.SOUND_DIR, "/$", ""),   -- no trailing slash: passed to dir()
  widget    = "/WIDGETS/GPSHOMER/main.lua",
  tool      = "/SCRIPTS/TOOLS/GPSHOMER.lua",
}

-- Haptic feedback: on/off plus a 1..3 strength tier. Pulse lengths and pulses
-- per event come from core so Test previews the exact buzz a real event fires.
local HAPTIC = {
  min    = LIMITS.hapticStrength.min, max = LIMITS.hapticStrength.max,
  labels = { "Soft", "Normal", "Strong" },
}

-- Buzz alongside a Test preview with the strength currently set in the tool
-- (not the saved config). No-op when haptic is off or playHaptic is absent.
function HAPTIC.test(on, strength, key)
  if not on or not playHaptic then return end
  local dur    = core.HAPTIC_DUR[strength] or core.HAPTIC_DUR[core.DEFAULTS.hapticStrength]
  local pulses = core.HAPTIC_PULSES[key] or 1
  for i = 1, pulses do
    playHaptic(dur, (i < pulses) and dur or 0)   -- gap between pulses, none after the last
  end
end

-- Display unit systems (core.UNIT_CHOICES order) with their row labels.
local UNIT_LABELS = { metric = "Metric (m, km/h)", imperial = "Imperial (ft, mph)" }

-- The three voice events, in editor order: config key, row label, picker title.
local EVENTS = {
  { key = "ready", label = "Ready to fly", title = "Ready to fly sound",
    hint = "GPS fix is stable, safe to arm" },
  { key = "fix",  label = "Home set",    title = "Home set sound",
    hint = "Home stored when arming (or at first stable fix)" },
  { key = "lost", label = "GPS lost",    title = "GPS lost sound",
    hint = "GPS fix lost for a few seconds" },
  { key = "rec",  label = "GPS recover", title = "GPS recover sound",
    hint = "GPS fix is back after a loss" },
}

-- ---------------------------------------------------------------------------
-- Serialization (same table shape core loads) + file write
-- ---------------------------------------------------------------------------

local function quoteString(s)
  s = string.gsub(s, "\\", "\\\\")
  s = string.gsub(s, '"', '\\"')
  s = string.gsub(s, "\n", "\\n")
  return '"' .. s .. '"'
end

local function serialize(value, indent)
  local t = type(value)
  if t == "number" or t == "boolean" then
    return tostring(value)
  elseif t == "string" then
    return quoteString(value)
  elseif t == "table" then
    local nextIndent = indent .. "  "
    local parts      = {}
    for k, v in pairs(value) do
      local keyStr = (type(k) == "string") and ("[" .. quoteString(k) .. "]") or ("[" .. tostring(k) .. "]")
      parts[#parts + 1] = nextIndent .. keyStr .. " = " .. serialize(v, nextIndent)
    end
    if #parts == 0 then return "{}" end
    table.sort(parts)   -- stable file content for a given config
    return "{\n" .. table.concat(parts, ",\n") .. ",\n" .. indent .. "}"
  end
  return "nil"
end

-- Reads a whole file (block reads; "a" format is not on every build), or nil.
local function readFile(path)
  local ok, f = pcall(io.open, path, "r")
  if not ok or not f then return nil end
  local parts = {}
  while true do
    local rok, chunk = pcall(io.read, f, 4096)
    if not rok or not chunk or chunk == "" then break end
    parts[#parts + 1] = chunk
  end
  pcall(io.close, f)
  return table.concat(parts)
end

-- io.open "w" does NOT truncate on some EdgeTX/SD builds, so a shorter write
-- would leave the old tail behind -- pad with trailing newlines (valid after the
-- table) up to the old length. Pcall-wrapped so a full/read-only SD never raises.
local function writeFile(path, content)
  local old = readFile(path)
  if old and #old > #content then
    content = content .. string.rep("\n", #old - #content)
  end
  local ok, f = pcall(io.open, path, "w")
  if not ok or not f then return false end
  local wok = pcall(io.write, f, content)
  pcall(io.close, f)
  return wok == true
end

-- ---------------------------------------------------------------------------
-- Config load / default / save
-- ---------------------------------------------------------------------------

-- Returns (config) on success, or (nil, errKind, detail) where errKind is
-- "missing" | "parse" | "schema".
local function loadConfig()
  local ok, f = pcall(io.open, PATHS.config, "r")
  if not ok or not f then return nil, "missing" end
  pcall(io.close, f)

  local cok, chunk = pcall(loadScript, PATHS.config)
  if not cok or not chunk then return nil, "parse", tostring(chunk) end
  local pok, result = pcall(chunk)
  if not pok then return nil, "parse", tostring(result) end
  if type(result) ~= "table" then return nil, "parse", "not a table" end
  if result.schemaVersion ~= SCHEMA_VERSION then
    return nil, "schema", tostring(result.schemaVersion)
  end
  -- core's clamp/type rules, so a hand-edited value shows here exactly as the
  -- runtime uses it (and a wrong type can never reach the editor).
  local cfg = core.normalizeConfig(result)
  cfg.schemaVersion = SCHEMA_VERSION
  return cfg
end

local function defaultConfig()
  local cfg = core.normalizeConfig({})
  cfg.schemaVersion = SCHEMA_VERSION
  return cfg
end

-- Writes the config. core reads it once at load, so a change takes effect on
-- the next model select / reboot. Returns true on success.
local function saveConfig(cfg)
  local content = "-- GPS Homer configuration (auto-generated by the Tools script).\n"
                  .. "return " .. serialize(cfg, "") .. "\n"
  return writeFile(PATHS.config, content)
end

-- ---------------------------------------------------------------------------
-- Event sounds
-- ---------------------------------------------------------------------------

-- The bundled defaults are reachable via the "Default" slot, so they are left
-- out of the named list.
local SOUND_DEFAULT_FILES = {}
for _, name in pairs(core.SOUND_DEFAULTS) do SOUND_DEFAULT_FILES[name] = true end

-- Sorted *.wav files in the sound folder. pcall: dir() raises when the folder
-- is missing. string.* as free functions: EdgeTX-Lua has no string methods.
-- Names starting with "." are skipped: macOS writes "._name.wav" companions.
local function listSoundFiles()
  local files = {}
  pcall(function()
    for fname in dir(PATHS.soundList) do
      if type(fname) == "string" and string.match(string.lower(fname), "%.wav$")
         and string.sub(fname, 1, 1) ~= "." and not SOUND_DEFAULT_FILES[fname] then
        files[#files + 1] = fname
      end
    end
  end)
  table.sort(files, function(a, b) return string.lower(a) < string.lower(b) end)
  return files
end

-- Fixed picker slots ahead of the user's files: "Off" mutes the event (stored
-- as false), "Default" plays the bundled file (stored as nil, so a deleted
-- custom file falls back to the default instead of breaking).
local SND_OFF, SND_DEFAULT = 1, 2

-- Picker options { label, name }: the two fixed slots, then the user files.
local function buildSoundOptions(defaultName, files)
  local opts = {}
  opts[SND_OFF]     = { label = "Off",     name = false }
  opts[SND_DEFAULT] = { label = "Default", name = defaultName }
  for _, fname in ipairs(files) do
    opts[#opts + 1] = { label = fname, name = fname }
  end
  return opts
end

-- 1-based index for a stored config value: false -> Off, a matching file ->
-- that file, nil / a no-longer-present file -> Default.
local function soundOptionIndex(opts, value)
  if value == false then return SND_OFF end
  if type(value) == "string" then
    for i = SND_DEFAULT + 1, #opts do if opts[i].name == value then return i end end
  end
  return SND_DEFAULT
end

-- Config value for a selection: false for Off, nil for Default, else the name.
local function soundConfigValue(opts, idx)
  if idx == SND_OFF     then return false end
  if idx == SND_DEFAULT then return nil end
  return opts[idx].name
end

-- ---------------------------------------------------------------------------
-- UI state
-- ---------------------------------------------------------------------------

local SCREEN = {
  CONFIG_ERROR = "config_error",
  MAIN         = "main",
  SETTINGS     = "settings",
  ABOUT        = "about",
}

local S = {
  screen    = SCREEN.MAIN,
  cfg       = nil,
  err       = nil,
  errDetail = nil,
  cursor    = 1,
  dialog    = nil,   -- { text, yes, no, onYes } or { rows = {{label,value},...} }
  picker    = nil,
  -- Settings editor working state
  set        = nil,  -- { sats, haptic, hapStr, units, snd = { <event key> = idx } }
  setField   = nil,  -- in-place edited field: "sats", "haptic", "hapStr" or "units"
  sndOpts    = nil,  -- per event key: picker options
  setEditing = false,
  setOrig    = nil,
  setDive    = nil,  -- focused event row (1..#EVENTS), or nil at top level
  setSub     = "snd",
}

-- ---------------------------------------------------------------------------
-- Event helpers (virtual keys)
-- ---------------------------------------------------------------------------

local function isNext(e)  return e == EVT_VIRTUAL_NEXT or e == EVT_VIRTUAL_INC end
local function isPrev(e)  return e == EVT_VIRTUAL_PREV or e == EVT_VIRTUAL_DEC end
local function isEnter(e) return e == EVT_VIRTUAL_ENTER end
local function isExit(e)  return e == EVT_VIRTUAL_EXIT end

-- Moves a 1-based cursor within [1, count], clamped (no wrap).
local function moveCursor(cur, e, count)
  if isNext(e) and cur < count then return cur + 1 end
  if isPrev(e) and cur > 1     then return cur - 1 end
  return cur
end

-- ---------------------------------------------------------------------------
-- Drawing helpers
-- ---------------------------------------------------------------------------

local PAD  = 6
-- Row pitch. The screen-height fraction is only a load-time fallback (sizeText is
-- not valid until a frame runs); draw() raises LINE to the real font height on the
-- first frame, so rows and buttons never overlap.
local LINE = math.max(18, math.floor(LCD_H / 13))
local COL1 = PAD * 2                    -- label / entry column

-- Settings column x-anchors (label / value or sound / Test).
local ST_LBL, ST_VAL, ST_TEST = COL1, math.floor(LCD_W * 0.40), math.floor(LCD_W * 0.74)

local function drawHeader(title)
  local h = LINE + PAD
  lcd.drawFilledRectangle(0, 0, LCD_W, h, COLOR_THEME_SECONDARY1)
  local _, th = lcd.sizeText("Mg")
  lcd.drawText(PAD, math.floor((h - th) / 2), title, COLOR_THEME_PRIMARY2 + BOLD)
end

local function bodyY(row)
  return LINE + PAD * 2 + (row - 1) * LINE
end

-- Navigation row: `folder` prefixes "> " and bolds it; the cursor row is INVERS.
local function drawNavRow(row, text, selected, opts)
  opts = opts or {}
  local flags = COLOR_THEME_PRIMARY1
  if opts.folder then text = "> " .. text; flags = flags + BOLD end
  if selected then flags = flags + INVERS end
  lcd.drawText(COL1, bodyY(row), text, flags)
end

-- Downward triangle marking a field that opens a picker popup.
local ARROW_W   = 11
local ARROW_H   = math.ceil(ARROW_W / 2)
local ARROW_GAP = 5
local function drawDownArrow(x, y, color)
  for i = 0, ARROW_H - 1 do
    lcd.drawFilledRectangle(x + i, y + i, ARROW_W - 2 * i, 1, color)
  end
end

-- Same triangle pointing right, marking a row that dives into a sub-context.
local function drawRightArrow(x, y, color)
  for i = 0, ARROW_H - 1 do
    lcd.drawFilledRectangle(x + i, y + i, 1, ARROW_W - 2 * i, color)
  end
end

-- Popup arrow at (x, y), vertically centred on the row; returns the value x.
local function drawArrowBefore(x, y, color)
  local _, th = lcd.sizeText("Mg")
  drawDownArrow(x, y + math.floor((th - ARROW_H) / 2), color)
  return x + ARROW_W + ARROW_GAP
end

-- Small "i" badge marking a hint line; returns the x where its text starts.
local function drawInfoBadge(x, y)
  local _, sh = lcd.sizeText("Mg", SMLSIZE)
  local r     = math.floor(sh / 2)
  lcd.drawFilledCircle(x + r, y + r, r, COLOR_THEME_FOCUS)
  local iw = lcd.sizeText("i", SMLSIZE)
  lcd.drawText(x + r - math.floor(iw / 2), y, "i", COLOR_THEME_PRIMARY2 + SMLSIZE)
  return x + 2 * r + ARROW_GAP
end

local BTN_GAP = 8

-- Y of the separator line above the bottom button bar.
local function barTopY()
  local _, th = lcd.sizeText("Mg")
  return LCD_H - (th + 4) - 2 * BTN_GAP
end

-- One button at (x, y): outlined, or filled with the accent colour when focused.
-- Disabled (Test while the sound is Off): greyed + struck through, ENTER no-op.
local BTN_PADX = 6
local function drawButton(x, y, label, focused, disabled)
  local _, th = lcd.sizeText("Mg")
  local w     = lcd.sizeText(label) + 2 * BTN_PADX
  if disabled then
    lcd.drawRectangle(x, y, w, th + 4, focused and COLOR_THEME_FOCUS or COLOR_THEME_DISABLED)
    lcd.drawText(x + BTN_PADX, y + 2, label, COLOR_THEME_DISABLED)
    lcd.drawFilledRectangle(x + BTN_PADX, y + 2 + math.floor(th / 2),
                            w - 2 * BTN_PADX, 2, COLOR_THEME_DISABLED)
  elseif focused then
    lcd.drawFilledRectangle(x, y, w, th + 4, COLOR_THEME_FOCUS)
    lcd.drawText(x + BTN_PADX, y + 2, label, COLOR_THEME_PRIMARY2)
  else
    lcd.drawRectangle(x, y, w, th + 4, COLOR_THEME_PRIMARY1)
    lcd.drawText(x + BTN_PADX, y + 2, label, COLOR_THEME_PRIMARY1)
  end
  return w
end

-- Bottom action bar; `firstItem` is the cursor index of labels[1].
local function drawButtonBar(labels, firstItem, cursor)
  local sepY = barTopY()
  local btnY = sepY + BTN_GAP
  lcd.drawFilledRectangle(PAD, sepY, LCD_W - 2 * PAD, 1, COLOR_THEME_PRIMARY3)
  local x = PAD
  for i, label in ipairs(labels) do
    local w = drawButton(x, btnY, label, cursor == firstItem + i - 1)
    x = x + w + PAD
  end
end

-- Full-screen shade behind a popup/dialog. opacity 0 = solid, 15 = invisible.
local DIM_OPACITY = 9
local function dimScreen()
  lcd.drawFilledRectangle(0, 0, LCD_W, LCD_H, lcd.RGB(0, 0, 0), DIM_OPACITY)
end

-- ---------------------------------------------------------------------------
-- Confirm dialog (Yes/No, EXIT cancels) and info popup
-- ---------------------------------------------------------------------------

local function openDialog(text, onYes, yesLabel, noLabel)
  S.dialog = { text = text, onYes = onYes, cursor = 2,  -- default to the safe answer
               yes = yesLabel or "Yes", no = noLabel or "No" }
end

local function openInfoRows(rows)
  S.dialog = { rows = rows }
end

-- Word-wraps `text` to lines no wider than maxW px, breaking on spaces.
local function wrapText(text, maxW)
  local lines, line = {}, ""
  local i, n = 1, #text
  while i <= n do
    local sp = string.find(text, " ", i, true)
    local word
    if sp then word = string.sub(text, i, sp - 1); i = sp + 1
    else       word = string.sub(text, i);         i = n + 1 end
    local cand = (line == "") and word or (line .. " " .. word)
    if line ~= "" and lcd.sizeText(cand) > maxW then
      lines[#lines + 1] = line
      line = word
    else
      line = cand
    end
  end
  lines[#lines + 1] = line
  return lines
end

-- Two-column popup: every value starts at one measured x.
local function drawInfoRows(d)
  local rows = d.rows
  local gap  = PAD * 2
  local labelW, valueW = 0, 0
  for _, it in ipairs(rows) do
    labelW = math.max(labelW, lcd.sizeText(it[1]))
    valueW = math.max(valueW, lcd.sizeText(it[2]))
  end
  local w = math.min(LCD_W - 2 * PAD, labelW + gap + valueW + 2 * PAD)
  local x = math.floor((LCD_W - w) / 2)
  local h = (#rows + 2) * LINE + PAD * 2
  local y = math.floor((LCD_H - h) / 2)
  dimScreen()
  lcd.drawFilledRectangle(x + 3, y + 3, w, h, COLOR_THEME_PRIMARY1)
  lcd.drawFilledRectangle(x, y, w, h, COLOR_THEME_SECONDARY3)
  lcd.drawRectangle(x, y, w, h, COLOR_THEME_SECONDARY1)
  local valX = x + PAD + labelW + gap
  for i, it in ipairs(rows) do
    local ry = y + PAD + (i - 1) * LINE
    lcd.drawText(x + PAD, ry, it[1], COLOR_THEME_PRIMARY1)
    lcd.drawText(valX,    ry, it[2], COLOR_THEME_PRIMARY1)
  end
  drawButton(x + PAD * 2, y + h - LINE - PAD, "Close", true)
end

local function drawDialog()
  local d = S.dialog
  if d.rows then drawInfoRows(d); return end
  dimScreen()
  local w     = math.floor(LCD_W * 0.8)
  local x     = math.floor((LCD_W - w) / 2)
  local lines = wrapText(d.text, w - 2 * PAD)
  local h     = (#lines + 2) * LINE + PAD * 2
  local y     = math.floor((LCD_H - h) / 2)
  lcd.drawFilledRectangle(x + 3, y + 3, w, h, COLOR_THEME_PRIMARY1)
  lcd.drawFilledRectangle(x, y, w, h, COLOR_THEME_SECONDARY3)
  lcd.drawRectangle(x, y, w, h, COLOR_THEME_SECONDARY1)
  for i, line in ipairs(lines) do
    lcd.drawText(x + PAD, y + PAD + (i - 1) * LINE, line, COLOR_THEME_PRIMARY1)
  end
  local btnY = y + h - LINE - PAD
  drawButton(x + PAD * 2,                 btnY, d.yes, d.cursor == 1)
  drawButton(x + math.floor(w / 2) + PAD, btnY, d.no,  d.cursor == 2)
end

local function handleDialog(e)
  local d = S.dialog
  if d.rows then
    if isEnter(e) or isExit(e) then S.dialog = nil end
    return
  end
  if isNext(e) or isPrev(e) then
    d.cursor = (d.cursor == 1) and 2 or 1
  elseif isEnter(e) then
    local onYes, choseYes = d.onYes, d.cursor == 1
    S.dialog = nil
    if choseYes and onYes then onYes() end
  elseif isExit(e) then
    S.dialog = nil   -- EXIT == the cancelling answer
  end
end

-- ---------------------------------------------------------------------------
-- Scrollable picker popup
-- ---------------------------------------------------------------------------

local PICKER_MAX_ROWS = 5

local function pickerEnsureVisible(rows)
  local p = S.picker
  if p.sel < p.top then p.top = p.sel end
  if p.sel > p.top + rows - 1 then p.top = p.sel - rows + 1 end
  if p.top < 1 then p.top = 1 end
end

local function openPicker(title, labels, sel, onPick)
  S.picker = { title = title, labels = labels, sel = sel or 1, top = 1, onPick = onPick }
  pickerEnsureVisible(PICKER_MAX_ROWS)
end

local function pickerRows()
  local _, th  = lcd.sizeText("Mg")
  local maxFit = math.floor((LCD_H - 2 * LINE - th - 2 * PAD) / LINE)
  return math.max(1, math.min(PICKER_MAX_ROWS, #S.picker.labels, maxFit))
end

-- Vertical scrollbar for `visibleRows` of `totalRows`, `firstIdx` the top row.
local function drawScrollbar(sx, y0, visibleRows, firstIdx, totalRows)
  local trackH = visibleRows * LINE
  lcd.drawFilledRectangle(sx, y0, 3, trackH, COLOR_THEME_PRIMARY3)
  local thumbH = math.max(6, math.floor(trackH * visibleRows / totalRows))
  local thumbY = y0 + math.floor(trackH * (firstIdx - 1) / totalRows)
  lcd.drawFilledRectangle(sx, thumbY, 3, thumbH, COLOR_THEME_FOCUS)
end

local PICK_INDENT = 8
local function drawPicker()
  local p     = S.picker
  local n     = #p.labels
  local rows  = pickerRows()
  local _, th = lcd.sizeText("Mg")
  local headH = th + 6
  local w     = math.floor(LCD_W * 0.58)
  local h     = headH + rows * LINE + 4
  local x     = math.floor((LCD_W - w) / 2)
  local y     = math.floor((LCD_H - h) / 2)
  local hasBar = n > rows
  local textY  = math.floor((LINE - th) / 2)

  dimScreen()
  lcd.drawFilledRectangle(x + 3, y + 3, w, h, COLOR_THEME_PRIMARY1)
  lcd.drawFilledRectangle(x, y, w, h, COLOR_THEME_SECONDARY3)
  lcd.drawRectangle(x, y, w, h, COLOR_THEME_SECONDARY1)
  lcd.drawFilledRectangle(x, y, w, headH, COLOR_THEME_SECONDARY1)
  lcd.drawText(x + PICK_INDENT, y + 3, p.title, COLOR_THEME_PRIMARY2 + BOLD)
  lcd.drawText(x + w - PICK_INDENT, y + 3, p.sel .. "/" .. n, COLOR_THEME_PRIMARY2 + RIGHT)

  local listY = y + headH
  for i = 0, rows - 1 do
    local idx = p.top + i
    if idx <= n then
      local ry = listY + i * LINE
      if idx == p.sel then
        lcd.drawFilledRectangle(x, ry, w - (hasBar and 5 or 0), LINE, COLOR_THEME_FOCUS)
        lcd.drawText(x + PICK_INDENT, ry + textY, p.labels[idx], COLOR_THEME_PRIMARY2)
      else
        lcd.drawText(x + PICK_INDENT, ry + textY, p.labels[idx], COLOR_THEME_PRIMARY1)
      end
    end
  end
  if hasBar then drawScrollbar(x + w - 4, listY, rows, p.top, n) end
end

local function handlePicker(e)
  local p = S.picker
  local n = #p.labels
  if isNext(e) or isPrev(e) then
    p.sel = isNext(e) and (p.sel % n + 1) or ((p.sel - 2) % n + 1)   -- wrap-around
    pickerEnsureVisible(pickerRows())
  elseif isEnter(e) then
    local onPick, sel = p.onPick, p.sel
    S.picker = nil
    if onPick then onPick(sel) end
  elseif isExit(e) then
    S.picker = nil
  end
end

-- Runs a write closure (true on success). On failure a Retry / Cancel dialog
-- re-runs the same closure; on success onDone is called.
local function withRetry(writeFn, onDone)
  if writeFn() then
    if onDone then onDone() end
  else
    openDialog("Save failed, check SD card.",
               function() withRetry(writeFn, onDone) end, "Retry", "Cancel")
  end
end

-- Overwrites config.lua with factory defaults and clears any parse/schema error.
local function resetConfig(onDone)
  local fresh = defaultConfig()
  withRetry(function() return saveConfig(fresh) end, function()
    S.cfg              = fresh
    S.err, S.errDetail = nil, nil
    if onDone then onDone() end
  end)
end

-- ---------------------------------------------------------------------------
-- Screen: config error
-- ---------------------------------------------------------------------------

local function drawConfigError()
  drawHeader("CONFIG ERROR")
  if S.err == "schema" then
    lcd.drawText(COL1, bodyY(1), "Schema version mismatch", COLOR_THEME_PRIMARY1)
    lcd.drawText(COL1, bodyY(2), "(found " .. tostring(S.errDetail) .. ", expected "
                 .. SCHEMA_VERSION .. ").", COLOR_THEME_PRIMARY1)
  else
    lcd.drawText(COL1, bodyY(1), "Parse error in config.lua", COLOR_THEME_PRIMARY1)
  end
  lcd.drawText(COL1, bodyY(3), "Edit config.lua on PC,", COLOR_THEME_PRIMARY1)
  lcd.drawText(COL1, bodyY(4), "or reset to defaults below.", COLOR_THEME_PRIMARY1)
  drawButtonBar({ "Reset config", "Exit" }, 1, S.cursor)
end

local function handleConfigError(e)
  S.cursor = moveCursor(S.cursor, e, 2)
  if isEnter(e) then
    if S.cursor == 1 then
      openDialog("Reset settings to factory defaults?",
                 function() resetConfig(function() S.screen = SCREEN.MAIN; S.cursor = 1 end) end)
    else
      return 1
    end
  elseif isExit(e) then
    return 1
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- Screen: main menu
-- ---------------------------------------------------------------------------

local MAIN_ITEMS = { "Settings", "About" }

local function drawMain()
  drawHeader("GPS HOMER - SETUP")
  for i, item in ipairs(MAIN_ITEMS) do
    drawNavRow(i, item, S.cursor == i, { folder = true })
  end
  drawButtonBar({ "Exit" }, #MAIN_ITEMS + 1, S.cursor)
end

local function enterSettings()
  local files = listSoundFiles()
  S.sndOpts = {}
  S.set     = { sats = S.cfg.homeMinSats, haptic = S.cfg.haptic, hapStr = S.cfg.hapticStrength,
                units = S.cfg.units, snd = {} }
  for _, ev in ipairs(EVENTS) do
    S.sndOpts[ev.key]  = buildSoundOptions(core.SOUND_DEFAULTS[ev.key], files)
    S.set.snd[ev.key]  = soundOptionIndex(S.sndOpts[ev.key], S.cfg.sounds[ev.key])
  end
  S.setEditing = false
  S.setDive    = nil
  S.setSub     = "snd"
  S.cursor     = 1
  S.screen     = SCREEN.SETTINGS
end

local function handleMain(e)
  S.cursor = moveCursor(S.cursor, e, #MAIN_ITEMS + 1)
  if isEnter(e) then
    if S.cursor > #MAIN_ITEMS then return 1 end   -- Exit button closes the tool
    if MAIN_ITEMS[S.cursor] == "Settings" then
      enterSettings()
    else
      S.screen = SCREEN.ABOUT
      S.cursor = 1
    end
  elseif isExit(e) then
    return 1
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- Screen: About
-- ---------------------------------------------------------------------------

local ABOUT = (function()
  local lines = {
    "(c) Mariator-pro   GPL-2.0",
    "GPS Homer  v" .. tostring(VERSION),
  }
  -- Firmware line only on the radio: getVersion is absent in host tests.
  if getVersion then
    local ver, radio, _, _, _, osname = getVersion()
    lines[#lines + 1] = (osname or "EdgeTX") .. " " .. tostring(ver) .. " (" .. tostring(radio) .. ")"
  end
  lines[#lines + 1] = "github.com/Mariator-pro/edgetx-gps-homer"
  lines[#lines + 1] = "Schema version: " .. SCHEMA_VERSION
  lines[#lines + 1] = "File locations..."   -- last line: ENTER opens the path popup
  local pathItems = {
    { "Core:",   CORE_PATH },
    { "Config:", PATHS.config },
    { "Widget:", PATHS.widget },
    { "Tool:",   PATHS.tool },
    { "Sounds:", PATHS.soundDir },
  }
  return { lines = lines, pathItems = pathItems }
end)()

local function drawAbout()
  drawHeader("ABOUT")
  local n       = #ABOUT.lines
  local maxRows = math.max(1, math.floor((barTopY() - bodyY(1)) / LINE))
  local focus   = math.max(1, math.min(S.cursor, n))
  local start   = math.max(1, math.min(focus - math.floor(maxRows / 2), n - maxRows + 1))
  local row = 0
  for i = start, math.min(n, start + maxRows - 1) do
    row = row + 1
    lcd.drawText(COL1, bodyY(row), ABOUT.lines[i], COLOR_THEME_PRIMARY1 + (S.cursor == i and INVERS or 0))
  end
  if n > maxRows then drawScrollbar(LCD_W - 4, bodyY(1), maxRows, start, n) end
  drawButtonBar({ "Back" }, n + 1, S.cursor)
end

local function handleAbout(e)
  local n = #ABOUT.lines
  S.cursor = moveCursor(S.cursor, e, n + 1)
  if isExit(e) then
    S.screen = SCREEN.MAIN; S.cursor = 2
  elseif isEnter(e) then
    if S.cursor > n then
      S.screen = SCREEN.MAIN; S.cursor = 2
    elseif S.cursor == n then
      openInfoRows(ABOUT.pathItems)
    end
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- Screen: Settings editor
-- ---------------------------------------------------------------------------

-- Cursor rows: Min sats (1), the event rows (2..1+#EVENTS), Haptic on/off,
-- Haptic strength (hidden while haptic is off), Units, Reset, Back, Save. ENTER on an
-- event row dives in; the roller then steps Sound -> Test and ENTER opens the
-- picker / plays the focused cell.
local ROW_SATS, ROW_EV1 = 1, 2
local ROW_HAPTIC = ROW_EV1 + #EVENTS
local ROW_HAPSTR, ROW_UNITS = ROW_HAPTIC + 1, ROW_HAPTIC + 2
local ROW_RESET, ROW_BACK, ROW_SAVE = ROW_UNITS + 1, ROW_UNITS + 2, ROW_UNITS + 3
local SET_ITEMS = ROW_SAVE
local SET_SUBS      = { "snd", "test" }
local SET_SUBS_MUTE = { "snd" }   -- Test dropped when the sound is Off

local function eventOf(row) return EVENTS[row - ROW_EV1 + 1] end
local function selectedOpt(ev) return S.sndOpts[ev.key][S.set.snd[ev.key]] end

local function activeSubs()
  local opt = selectedOpt(eventOf(S.setDive))
  if opt and opt.name == false then return SET_SUBS_MUTE end
  return SET_SUBS
end

local function settingsDirty()
  if S.set.sats ~= S.cfg.homeMinSats or S.set.haptic ~= S.cfg.haptic
     or S.set.hapStr ~= S.cfg.hapticStrength or S.set.units ~= S.cfg.units then return true end
  for _, ev in ipairs(EVENTS) do
    if soundConfigValue(S.sndOpts[ev.key], S.set.snd[ev.key]) ~= S.cfg.sounds[ev.key] then return true end
  end
  return false
end

local function leaveSettings()
  S.screen = SCREEN.MAIN
  S.cursor = 1
end

local function saveSettings()
  S.cfg.homeMinSats    = S.set.sats
  S.cfg.haptic         = S.set.haptic
  S.cfg.hapticStrength = S.set.hapStr
  S.cfg.units          = S.set.units
  for _, ev in ipairs(EVENTS) do
    S.cfg.sounds[ev.key] = soundConfigValue(S.sndOpts[ev.key], S.set.snd[ev.key])
  end
  withRetry(function() return saveConfig(S.cfg) end, leaveSettings)
end

local function cancelSettings()
  if settingsDirty() then
    openDialog("Discard changes?", leaveSettings)
  else
    leaveSettings()
  end
end

-- One event row (label + Sound/Test cells) honouring the dive state.
local function drawEventRow(row, y)
  local ev     = eventOf(row)
  local opt    = selectedOpt(ev)
  local dived  = S.setDive == row
  local rowSel = (S.cursor == row) and not dived
  local _, lh  = lcd.sizeText("Mg")
  drawRightArrow(ST_LBL, y + math.floor((lh - ARROW_W) / 2), COLOR_THEME_PRIMARY1)
  lcd.drawText(ST_LBL + ARROW_W + ARROW_GAP, y, ev.label,
               COLOR_THEME_PRIMARY1 + (rowSel and INVERS or 0))
  local sndX = drawArrowBefore(ST_VAL, y, COLOR_THEME_PRIMARY1)
  lcd.drawText(sndX, y, opt.label,
               COLOR_THEME_PRIMARY1 + ((dived and S.setSub == "snd") and INVERS or 0))
  drawButton(ST_TEST, y - 2, "Test", dived and S.setSub == "test", opt.name == false)
end

-- A "label value" row edited in place: value blinks while editing, inverted
-- when only selected.
local function drawChoiceRow(y, label, value, selected, editing)
  lcd.drawText(ST_LBL, y, label, COLOR_THEME_PRIMARY1)
  local f = COLOR_THEME_PRIMARY1
  if editing then f = f + BLINK + INVERS
  elseif selected then f = f + INVERS end
  lcd.drawText(ST_VAL, y, value, f)
end

local function hintFor(cursor)
  if cursor == ROW_SATS then return "Home is set once this many sats are stable" end
  if cursor >= ROW_EV1 and cursor < ROW_HAPTIC then return eventOf(cursor).hint end
  return nil
end

local function drawSettings()
  drawHeader("SETTINGS")
  -- Scrollable content rows; Back/Save stay fixed below. One shared hint row
  -- sits under the event block while Min sats or an event is focused -- dropped,
  -- not blanked, so the list never scrolls past an empty gap.
  local rows, focus = {}, 1
  local function add(fn, isFocus)
    rows[#rows + 1] = fn
    if isFocus then focus = #rows end
  end
  local hint = hintFor(S.cursor)
  add(function(y) drawChoiceRow(y, "Min sats", tostring(S.set.sats),
                                S.cursor == ROW_SATS, S.setEditing and S.setField == "sats") end,
      S.cursor == ROW_SATS)
  add(function(y)
    lcd.drawText(ST_LBL,  y, "Event", COLOR_THEME_PRIMARY1 + BOLD)
    lcd.drawText(ST_VAL,  y, "Sound", COLOR_THEME_PRIMARY1 + BOLD)
    lcd.drawText(ST_TEST, y, "Test",  COLOR_THEME_PRIMARY1 + BOLD)
  end)
  for i = 1, #EVENTS do
    local row = ROW_EV1 + i - 1
    add(function(y) drawEventRow(row, y) end, S.cursor == row)
  end
  if hint then
    add(function(y) lcd.drawText(drawInfoBadge(COL1, y), y, hint, COLOR_THEME_PRIMARY1 + SMLSIZE) end)
  end
  add(function(y) drawChoiceRow(y, "Haptic feedback", S.set.haptic and "On" or "Off",
                                S.cursor == ROW_HAPTIC, S.setEditing and S.setField == "haptic") end,
      S.cursor == ROW_HAPTIC)
  -- Strength only matters once feedback is on, so it is hidden (and skipped in
  -- navigation) while haptic is off.
  if S.set.haptic then
    add(function(y) drawChoiceRow(y, "Haptic strength", HAPTIC.labels[S.set.hapStr] or "Normal",
                                  S.cursor == ROW_HAPSTR, S.setEditing and S.setField == "hapStr") end,
        S.cursor == ROW_HAPSTR)
  end
  add(function(y) drawChoiceRow(y, "Units", UNIT_LABELS[S.set.units] or S.set.units,
                                S.cursor == ROW_UNITS, S.setEditing and S.setField == "units") end,
      S.cursor == ROW_UNITS)
  add(function(y) drawButton(PAD, y, "Reset to defaults", S.cursor == ROW_RESET) end, S.cursor == ROW_RESET)
  if S.cursor > ROW_RESET then focus = #rows end   -- on Back/Save show the list bottom

  local top0    = bodyY(1)
  local sepY    = barTopY()
  local nRows   = #rows
  local rowsFit = math.max(1, math.floor((sepY - top0) / LINE))
  local start   = math.max(1, math.min(focus - math.floor(rowsFit / 2), nRows - rowsFit + 1))
  for i = 0, rowsFit - 1 do
    local idx = start + i
    if idx <= nRows then rows[idx](top0 + i * LINE) end
  end
  if nRows > rowsFit then drawScrollbar(LCD_W - 4, top0, rowsFit, start, nRows) end
  drawButtonBar({ "Back", "Save" }, ROW_BACK, S.cursor)
end

local function handleSettings(e)
  -- In-place edit: haptic toggles, units cycle through the choices, numeric
  -- fields are clamped to LIMITS without wrap; ENTER keeps, EXIT reverts.
  if S.setEditing then
    local field = S.setField
    if field == "haptic" then
      if isNext(e) or isPrev(e) then S.set.haptic = not S.set.haptic end
    elseif field == "units" then
      if isNext(e) or isPrev(e) then
        local c, idx = core.UNIT_CHOICES, 1
        for j, u in ipairs(c) do if u == S.set.units then idx = j end end
        S.set.units = c[(idx - 1 + (isNext(e) and 1 or -1)) % #c + 1]
      end
    else
      local lim = (field == "sats") and LIMITS.homeMinSats or LIMITS.hapticStrength
      if isNext(e) and S.set[field] < lim.max then
        S.set[field] = S.set[field] + lim.step
      elseif isPrev(e) and S.set[field] > lim.min then
        S.set[field] = S.set[field] - lim.step
      end
    end
    if isEnter(e) then
      S.setEditing = false
    elseif isExit(e) then
      S.set[field] = S.setOrig
      S.setEditing = false
    end
    return 0
  end

  -- Dived into an event row: roller steps Sound -> Test, ENTER opens the picker
  -- / plays the focused cell, EXIT leaves the row.
  if S.setDive then
    local ev = eventOf(S.setDive)
    if isNext(e) or isPrev(e) then
      local subs = activeSubs()
      local idx = 1
      for j, s in ipairs(subs) do if s == S.setSub then idx = j end end
      idx = idx + (isNext(e) and 1 or -1)
      if idx < 1 then idx = #subs elseif idx > #subs then idx = 1 end
      S.setSub = subs[idx]
    elseif isEnter(e) then
      if S.setSub == "snd" then
        local labels = {}
        for _, o in ipairs(S.sndOpts[ev.key]) do labels[#labels + 1] = o.label end
        openPicker(ev.title, labels, S.set.snd[ev.key],
                   function(sel) S.set.snd[ev.key] = sel end)
      else
        local name = selectedOpt(ev).name
        if type(name) == "string" and playFile then playFile(PATHS.soundDir .. name) end
        HAPTIC.test(S.set.haptic, S.set.hapStr, ev.key)
      end
    elseif isExit(e) then
      S.setDive = nil
    end
    return 0
  end

  -- Top-level row navigation; the hidden strength row is skipped while haptic is off.
  S.cursor = moveCursor(S.cursor, e, SET_ITEMS)
  if S.cursor == ROW_HAPSTR and not S.set.haptic then
    S.cursor = isNext(e) and ROW_UNITS or ROW_HAPTIC
  end
  if isEnter(e) then
    if S.cursor == ROW_SATS then
      S.setField, S.setEditing, S.setOrig = "sats", true, S.set.sats
    elseif S.cursor == ROW_HAPTIC then
      S.setField, S.setEditing, S.setOrig = "haptic", true, S.set.haptic
    elseif S.cursor == ROW_HAPSTR then
      S.setField, S.setEditing, S.setOrig = "hapStr", true, S.set.hapStr
    elseif S.cursor == ROW_UNITS then
      S.setField, S.setEditing, S.setOrig = "units", true, S.set.units
    elseif S.cursor >= ROW_EV1 and S.cursor < ROW_HAPTIC then
      S.setDive, S.setSub = S.cursor, "snd"
    elseif S.cursor == ROW_RESET then
      openDialog("Reset settings to factory defaults?",
                 function() resetConfig(function() enterSettings() end) end)
    elseif S.cursor == ROW_BACK then
      cancelSettings()
    elseif S.cursor == ROW_SAVE then
      saveSettings()
    end
  elseif isExit(e) then
    cancelSettings()
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

local function init()
  S.cfg, S.err, S.errDetail = loadConfig()
  S.cursor = 1
  S.dialog = nil
  S.picker = nil
  if S.err == "missing" then
    -- Config is optional: start from in-RAM defaults; Save will create the file.
    S.cfg, S.err, S.errDetail = defaultConfig(), nil, nil
    S.screen = SCREEN.MAIN
  elseif S.err then
    S.screen = SCREEN.CONFIG_ERROR
  else
    S.screen = SCREEN.MAIN
  end
end

-- Handle the event first, then draw, so one frame reflects the result of the
-- input and a modal dialog renders on top of its screen.
local function handleEvent(event)
  if S.dialog then handleDialog(event); return 0 end
  if S.picker then handlePicker(event); return 0 end
  if S.screen == SCREEN.CONFIG_ERROR then return handleConfigError(event) end
  if S.screen == SCREEN.SETTINGS     then return handleSettings(event)    end
  if S.screen == SCREEN.ABOUT        then return handleAbout(event)       end
  return handleMain(event)
end

local function draw()
  lcd.clear()
  if not S.lineMeasured then            -- correct row pitch to the real font height once
    local _, fh = lcd.sizeText("Mg")
    if fh and fh > 0 then LINE = math.max(LINE, fh + 8) end
    S.lineMeasured = true
  end
  if S.screen == SCREEN.CONFIG_ERROR then
    drawConfigError()
  elseif S.screen == SCREEN.SETTINGS then
    drawSettings()
  elseif S.screen == SCREEN.ABOUT then
    drawAbout()
  else
    drawMain()
  end
  if S.picker then drawPicker() end
  if S.dialog then drawDialog() end
end

local function run(event)
  local ret = handleEvent(event) or 0
  draw()
  return ret
end

return { init = init, run = run }
