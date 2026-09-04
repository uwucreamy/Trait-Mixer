-- Trait Mixer v1.1
-- Original script by creamy.eth
--
-- Makes a collection from layered trait groups in Aseprite.
--
-- SETUP
-- - Put each trait category in a top-level group named Trait_Background, Trait_Eyes, etc.
-- - Put each possible trait on its own layer inside that group.
-- - Optional weighting: a layer named "Blue Hat[5]" is picked 5x as often as "Blue Hat[1]".
--   The [number] is removed from the exported trait name.
--
-- EXPORTS
-- - PNG images
-- - Optional OpenSea Studio CSV
-- - Optional per-token JSON metadata
-- - Optional trait report with final trait counts
--
-- NOTES
-- - "No duplicate trait combos" only checks the current run.
-- - "First token #" changes numbering only; it does not load or compare an earlier batch.
-- - Trait groups are drawn in the same bottom-to-top order they use in the Aseprite file.

math.randomseed(os.time())

local function starts_with(str, prefix) return str:sub(1, #prefix) == prefix end
local function is_group(layer) return layer.isGroup ~= nil and layer.isGroup end
local function ensure_dir(path) if not app.fs.isDirectory(path) then app.fs.makeDirectory(path) end end
local function pad(num, width) local s=tostring(num) while #s<width do s="0"..s end return s end

-- ---------- JSON ----------
local function json_escape(s)
  s = s:gsub("\\", "\\\\")
  s = s:gsub("\"", "\\\"")
  s = s:gsub("\n", "\\n")
  s = s:gsub("\r", "\\r")
  s = s:gsub("\t", "\\t")
  return s
end

local function json_encode(v)
  local t = type(v)
  if t == "nil" then return "null" end
  if t == "boolean" then return v and "true" or "false" end
  if t == "number" then return tostring(v) end
  if t == "string" then return "\"" .. json_escape(v) .. "\"" end
  if t == "table" then
    -- Arrays use numbered keys; objects use named keys.
    local isArray = true
    local n = 0
    for k,_ in pairs(v) do
      if type(k) ~= "number" then isArray = false break end
      if k > n then n = k end
    end
    if isArray then
      local parts = {}
      for i=1,n do parts[#parts+1] = json_encode(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for k,val in pairs(v) do
        parts[#parts+1] = "\"" .. json_escape(tostring(k)) .. "\":" .. json_encode(val)
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return "\"<unsupported>\""
end

local function write_text(path, text)
  local f = io.open(path, "w")
  if not f then return false end
  f:write(text)
  f:close()
  return true
end

local function write_json(path, obj)
  return write_text(path, json_encode(obj))
end

-- ---------- Layer helpers ----------
local function collect_trait_groups(sprite)
  -- Aseprite returns top-level layers bottom-to-top, which is our draw order.
  local groups = {}
  for _, layer in ipairs(sprite.layers) do
    if is_group(layer) and starts_with(layer.name, "Trait_") then
      table.insert(groups, layer)
    end
  end
  return groups
end

local function collect_leaf_layers(layer, out)
  out = out or {}
  if is_group(layer) then
    for _, child in ipairs(layer.layers) do collect_leaf_layers(child, out) end
  else
    table.insert(out, layer)
  end
  return out
end

-- ---------- OpenSea Studio CSV ----------
-- OpenSea Studio uses CSV for drop metadata uploads.
-- If OpenSea changes its example CSV later, update the column names below.
local OPENSEA_FIXED_COLS = { "tokenID", "file_name", "name", "description", "external_url" }
local OPENSEA_TRAIT_COL_FMT = "attributes[%s]"

local function csv_escape(s)
  s = tostring(s)
  if s:find('[,"\n\r]') then
    s = '"' .. s:gsub('"', '""') .. '"'
  end
  return s
end

local function write_opensea_csv(path, traitTypes, rows)
  local header = {}
  for _, c in ipairs(OPENSEA_FIXED_COLS) do header[#header+1] = c end
  for _, tt in ipairs(traitTypes) do
    header[#header+1] = string.format(OPENSEA_TRAIT_COL_FMT, tt)
  end

  local lines = { table.concat(header, ",") }
  for _, r in ipairs(rows) do
    local cols = {
      tostring(r.tokenID),
      csv_escape(r.file_name),
      csv_escape(r.name),
      csv_escape(r.description),
      "" -- external_url (blank)
    }
    for _, tt in ipairs(traitTypes) do
      cols[#cols+1] = csv_escape(r.traits[tt] or "")
    end
    lines[#lines+1] = table.concat(cols, ",")
  end
  return write_text(path, table.concat(lines, "\n") .. "\n")
end

local function get_frame_obj(sprite)
  return sprite.frames[1] -- your file shows 1 frame
end

local function get_cel(layer, frameObj)
  local ok, cel = pcall(function() return layer:cel(frameObj) end)
  if ok and cel and cel.image then return cel end
  return nil
end

local function draw_cel(dst, cel)
  if not cel or not cel.image then return false end
  local x, y = 0, 0
  if cel.position then
    x = cel.position.x or 0
    y = cel.position.y or 0
  end
  dst:drawImage(cel.image, x, y)
  return true
end

-- ---------- Trait weights ----------
-- "Dark Blue[5]" -> ("Dark Blue", 5)
local function parse_weighted_name(raw)
  local name, w = raw:match("^(.-)%[(%d+)%]%s*$")
  if name and w then
    name = name:gsub("%s+$", ""):gsub("^%s+", "")
    return name, tonumber(w) or 1
  end
  return raw, 1
end

local function pretty_trait_type(groupName)
  -- "Trait_Background" -> "Background"
  local t = groupName:gsub("^Trait_", "")
  t = t:gsub("_", " ")
  return t
end

local function weighted_pick(leaves)
  local total = 0
  local weights = {}
  local cleanNames = {}

  for i, layer in ipairs(leaves) do
    local clean, w = parse_weighted_name(layer.name)
    if w < 1 then w = 1 end
    weights[i] = w
    cleanNames[i] = clean
    total = total + w
  end

  local r = math.random() * total
  local acc = 0
  for i, layer in ipairs(leaves) do
    acc = acc + weights[i]
    if r <= acc then
      return layer, cleanNames[i], weights[i]
    end
  end

  return leaves[#leaves], cleanNames[#leaves], weights[#leaves]
end

-- ---------- DNA + trait report ----------
local function make_dna(attributesArray)
  -- Sort a copy of the trait names so the same combo always has the same DNA.
  local parts = {}
  for _, a in ipairs(attributesArray) do
    parts[#parts+1] = a.trait_type .. "=" .. a.value
  end
  table.sort(parts)
  return table.concat(parts, "|")
end

local function bump_trait_report(report, trait_type, value)
  report.by_trait_type[trait_type] = report.by_trait_type[trait_type] or {}
  report.by_trait_type[trait_type][value] = (report.by_trait_type[trait_type][value] or 0) + 1
end

-- ---------------- UI ----------------
local spr = app.activeSprite
if not spr then app.alert("No active sprite open.") return end

local dlg = Dialog("Trait Mixer")
dlg:number{ id="count", label="How many?", text="10", decimals=0 }
dlg:entry { id="prefix", label="File name prefix", text="token_" }
dlg:number{ id="start", label="First token #", text="1", decimals=0 }

dlg:combobox{
  id="outMode",
  label="Output folder",
  options={ "Next to source file", "Documents", "Custom folder..." },
  option="Next to source file",
  onchange=function()
    local isCustom = (dlg.data.outMode == "Custom folder...")
    dlg:modify{ id="folderName", visible=not isCustom }
    dlg:modify{ id="customOut", visible=isCustom }
  end
}
dlg:entry{ id="folderName", label="Folder name (optional)", text="" }
dlg:entry{ id="customOut", label="Custom folder", text=app.fs.userDocsPath, visible=false }

dlg:check{ id="enforceUnique", label="No duplicate trait combos", selected=true }
dlg:number{ id="maxAttempts", label="Re-roll limit if duplicates", text="2000", decimals=0 }

dlg:check{ id="perTokenJson", label="Write per-token JSON files", selected=false }
dlg:check{ id="openseaCsv", label="Write OpenSea Studio CSV", selected=true }
dlg:check{ id="traitReport", label="Write trait report (JSON)", selected=true }
dlg:entry { id="desc", label="Description (optional)", text="" }

dlg:button{ id="go", text="Generate", focus=true }
dlg:button{ text="Cancel" }
dlg:show()

local data = dlg.data
if not data or data.go == false then return end

local count = math.max(1, tonumber(data.count) or 1)
local prefix = tostring(data.prefix or "token_")
local startIndex = math.max(0, tonumber(data.start) or 1)
local maxAttempts = math.max(1, tonumber(data.maxAttempts) or 2000)
local description = tostring(data.desc or "")
local folderName = tostring(data.folderName or ""):gsub("^%s+", ""):gsub("%s+$", "")
if folderName == "" then folderName = "TraitMixer_Output" end

local outputDir
if data.outMode == "Next to source file" then
  if spr.filename and spr.filename ~= "" then
    outputDir = app.fs.joinPath(app.fs.filePath(spr.filename), folderName)
  else
    outputDir = app.fs.joinPath(app.fs.userDocsPath, folderName)
  end
elseif data.outMode == "Documents" then
  outputDir = app.fs.joinPath(app.fs.userDocsPath, folderName)
else -- Custom folder...
  outputDir = tostring(data.customOut or app.fs.userDocsPath)
end
ensure_dir(outputDir)

local traitGroups = collect_trait_groups(spr)
if #traitGroups == 0 then
  app.alert('No trait groups found. Make top-level groups named like "Trait_Frog", "Trait_Background", etc.')
  return
end

-- Read each trait group once before generation starts.
local traitData = {}
for _, group in ipairs(traitGroups) do
  local leaves = collect_leaf_layers(group, {})
  if #leaves > 0 then
    table.insert(traitData, {
      traitType = pretty_trait_type(group.name),
      leaves = leaves
    })
  end
end

-- Maximum possible unique combinations, ignoring weights.
local maxUnique = 1
for _, td in ipairs(traitData) do
  maxUnique = maxUnique * #td.leaves
end

local frameObj = get_frame_obj(spr)

-- OpenSea Studio CSV rows
local openseaRows = {}

-- Trait combinations already used in this run.
local seenDNA = {}

-- Trait counts for the finished batch.
local report = {
  generated = 0,
  requested = count,
  unique_enforced = data.enforceUnique and true or false,
  duplicates_rejected = 0,
  max_attempts_per_token = maxAttempts,
  theoretical_max_unique = maxUnique,
  by_trait_type = {}
}

-- ---------------- Generate collection ----------------
local produced = 0
for i = 0, count - 1 do
  local attempt = 0
  local dna = nil
  local pickedLayers = nil
  local attributesArray = nil

  while true do
    attempt = attempt + 1
    if attempt > maxAttempts then
      -- stop early if we cannot find a new unique combo
      break
    end

    pickedLayers = {}
    attributesArray = {}

    -- Pick one layer from each trait group.
    for _, td in ipairs(traitData) do
      local pickLayer, cleanValue = weighted_pick(td.leaves)
      table.insert(pickedLayers, pickLayer)
      attributesArray[#attributesArray+1] = { trait_type = td.traitType, value = cleanValue }
    end

    dna = make_dna(attributesArray)

    if data.enforceUnique then
      if not seenDNA[dna] then
        seenDNA[dna] = true
        break
      else
        report.duplicates_rejected = report.duplicates_rejected + 1
      end
    else
      break
    end
  end

  if attempt > maxAttempts then
    -- couldn't find another unique
    break
  end

  -- Draw the chosen traits bottom-to-top.
  local outImg = Image(spr.spec)
  for _, layer in ipairs(pickedLayers) do
    local cel = get_cel(layer, frameObj)
    draw_cel(outImg, cel)
  end

  local tokenNumber = startIndex + produced
  local name = prefix .. pad(tokenNumber, 4)
  local pngFile = name .. ".png"
  local pngPath = app.fs.joinPath(outputDir, pngFile)

  outImg:saveAs(pngPath)

  -- per-token JSON
  if data.perTokenJson then
    local jsonPath = app.fs.joinPath(outputDir, name .. ".json")
    local tokenObj = {
      name = name,
      description = description,
      image = pngFile,
      attributes = attributesArray
    }
    write_json(jsonPath, tokenObj)
  end

  -- OpenSea Studio CSV row
  if data.openseaCsv then
    local traits = {}
    for _, a in ipairs(attributesArray) do traits[a.trait_type] = a.value end
    openseaRows[#openseaRows+1] = {
      tokenID = tokenNumber, -- Studio maps rows by token ID.
      file_name = pngFile,
      name = name,
      description = description,
      traits = traits
    }
  end

  -- Update trait counts.
  if data.traitReport then
    for _, a in ipairs(attributesArray) do
      bump_trait_report(report, a.trait_type, a.value)
    end
  end

  produced = produced + 1
  report.generated = produced

  -- Stop once every possible combination has been used.
  if data.enforceUnique and produced >= maxUnique then
    break
  end
end

-- Save OpenSea Studio CSV
if data.openseaCsv then
  local traitTypes = {}
  for _, td in ipairs(traitData) do traitTypes[#traitTypes+1] = td.traitType end
  local csvPath = app.fs.joinPath(outputDir, "opensea_metadata.csv")
  write_opensea_csv(csvPath, traitTypes, openseaRows)
end

-- Save trait report
if data.traitReport then
  local reportPath = app.fs.joinPath(outputDir, "trait_report.json")
  write_json(reportPath, report)
end

local msg = "Done!\nExported to:\n" .. outputDir .. "\n\nGenerated: " .. tostring(report.generated) .. " / " .. tostring(report.requested)
if data.enforceUnique then
  msg = msg .. "\nUniqueness: ON"
  msg = msg .. "\nDuplicates rejected: " .. tostring(report.duplicates_rejected)
  msg = msg .. "\nTheoretical max unique: " .. tostring(report.theoretical_max_unique)
  if report.generated < report.requested then
    msg = msg .. "\n(Stopped early: couldn't find more unique combos within max attempts.)"
  end
end

app.alert(msg)
