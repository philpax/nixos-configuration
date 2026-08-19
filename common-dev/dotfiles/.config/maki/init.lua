-- Personal splash: a matrix rain spiralling out from the centre, with the
-- stock text block (logo, tagline, help line, tip, version) painted on top.
-- Replaces the bundled splash.render slot. Stateless: the frame is a pure
-- function of (w, h, t), so a new splash session restarts the same rain with
-- no cleanup.

local RAIN_SEED = 161803398
local LCG_MOD = 2147483647 -- 2^31 - 1, Park-Minimal standard LCG
local LCG_MULT = 48271
local BRIGHT_LEVELS = 5
-- Three rain depths, near to far: faster and brighter up close, slower and
-- dimmer in the back. speed is the outward speed in cells/sec along the
-- spiral, trail the fading tail length in cells. All layers ride the same
-- arms (see strands_for), so depth comes from speed and brightness on a
-- shared trajectory, the way the fall rain shared its columns. Each layer's
-- idle_max is a random idle stretch (in multiples of the run distance) after
-- a bead retires at the edge, so only a fraction of each layer flows at any
-- moment and the back layers are the sparsest. flicker is the per-cell glyph
-- mutation rate (re-rolls per second), higher up close so the near rain
-- shimmers and the far rain holds steady.
local LAYERS = {
  {
    speed = { 5.0, 9.0 },
    trail = { 6, 16 },
    idle_max = 1.0,
    bright = 1.0,
    head_alpha = 0.9,
    head_bold = true,
    head_fg = true,
    flicker = 0.8,
  },
  {
    speed = { 3.0, 6.0 },
    trail = { 5, 12 },
    idle_max = 1.4,
    bright = 0.55,
    head_alpha = 0.6,
    head_bold = false,
    head_fg = true,
    flicker = 1.0,
  },
  {
    speed = { 2.0, 4.0 },
    trail = { 3, 7 },
    idle_max = 1.0,
    bright = 0.3,
    head_alpha = 0.45,
    head_bold = false,
    head_fg = false,
    flicker = 0.5,
  },
}
-- Brightness cap: the entry fade settles at full strength, so the steady
-- state tops out well below the accent to keep the same subtlety as the
-- fade-in. Sparkles are a near-layer flourish just above the trails.
local RAIN_BRIGHT = 0.42
local SPARKLE_ALPHA = 0.35
local SPARKLE_EVERY = 7
-- Each arm winds TURNS full turns from the hole to the outer radius, and the
-- hole keeps a clear circle under the centred text. ARMS is the shared arm
-- count per unit radius, so density holds across sizes.
local SPIRAL_TURNS = 2.0
local SPIRAL_HOLE = 3
local SPIRAL_ARMS = 1.1

local LOGO = "luna-maki"
local TAGLINE = "luna's fucked up efficient coder"
local LOGO_DELAY = 0.2
local LOGO_RAMP = 0.8
local BLOCK_HEIGHT = 8

local HELP = {
  { "Ctrl+H", true },
  { " help", false },
  { " · ", false },
  { "/help", true },
  { " in chat", false },
}
local TIPS = {
  { "Ctrl+S", "to grab file paths with fuzzy search" },
  { "Ctrl+X", "to see what your subagents are up to" },
  { "Ctrl+F", "to find things in the conversation" },
  { "/btw", "to ask something without interrupting the session" },
  { "/memory", "to view, edit, and delete persistent notes" },
  { "/cd", "to switch to a different directory" },
}
local TIP_PREFIX = "tip: "
local tip_idx = 1

local FALLBACK_BG = { 40, 42, 54 }
local FALLBACK_FG = { 248, 248, 242 }
local FALLBACK_ACCENT = { 255, 184, 108 }
local FALLBACK_TIP = { 241, 250, 140 }

local function theme_rgb(name, fallback)
  local c = maki.ui.theme_color(name)
  if c then
    return {
      tonumber(string.sub(c, 2, 3), 16),
      tonumber(string.sub(c, 4, 5), 16),
      tonumber(string.sub(c, 6, 7), 16),
    }
  end
  return fallback
end

local function hex(rgb)
  return string.format("#%02x%02x%02x", rgb[1], rgb[2], rgb[3])
end

local function lerp_u8(a, b, t)
  return math.floor(a + (b - a) * t + 0.5)
end

local function mix(bg, target, t)
  if t > 1 then
    t = 1
  elseif t < 0 then
    t = 0
  end
  return {
    lerp_u8(bg[1], target[1], t),
    lerp_u8(bg[2], target[2], t),
    lerp_u8(bg[3], target[3], t),
  }
end

local function ease_out_cubic(t)
  t = math.max(0, math.min(1, t))
  return 1.0 - (1.0 - t) * (1.0 - t) * (1.0 - t)
end

-- Katakana plus alphanumerics, one string per glyph.
local GLYPHS = {}
do
  for cp = 0x30A0, 0x30FF do
    -- UTF-8 by arithmetic: the host Lua rejects bitwise operators.
    GLYPHS[#GLYPHS + 1] = string.char(0xE0 + math.floor(cp / 4096), 128 + (math.floor(cp / 64) % 64), 128 + (cp % 64))
  end
  local alpha = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
  for i = 1, #alpha do
    GLYPHS[#GLYPHS + 1] = string.sub(alpha, i, i)
  end
end

-- The blitter counts graphemes, and the text block contains one non-ASCII
-- glyph (the middle dot), so widths and placement walk chars, not bytes.
local function charlen(s)
  local n = 0
  for i = 1, #s do
    local b = string.byte(s, i)
    if b < 128 or b >= 192 then
      n = n + 1
    end
  end
  return n
end

local function decode_chars(s)
  local out = {}
  local i, n = 1, #s
  while i <= n do
    local b = string.byte(s, i)
    local len = 1
    if b >= 224 then
      len = 3
    elseif b >= 192 then
      len = 2
    end
    out[#out + 1] = string.sub(s, i, i + len - 1)
    i = i + len
  end
  return out
end

local function make_rng(seed)
  local s = seed % (LCG_MOD - 1)
  if s < 1 then
    s = 1
  end
  return function()
    s = (s * LCG_MULT) % LCG_MOD
    return s / LCG_MOD
  end
end

-- Per-cell glyph: a deterministic hash of (column, birth-step, mutation-gen).
-- A character is born at the head (birth-step k = head - d), persists as it
-- trails down, and re-rolls on its own desynchronised timer (gen ticks at
-- `rate`/sec, phase-shifted per cell). Pure arithmetic, no bitwise ops, and
-- no state: the frame stays a function of (w, h, t).
local HASH_MOD = 1000003
local function glyph_for(c, k, t, rate)
  local kp = k % HASH_MOD
  local phase = ((c * 73856093 + kp * 19349663) % LCG_MOD) / LCG_MOD
  local gen = math.floor(t * rate + phase) % HASH_MOD
  local x = (c * 73856093) % LCG_MOD
  x = (x + kp * 19349663) % LCG_MOD
  x = (x * LCG_MULT) % LCG_MOD
  x = (x + gen * 83492791) % LCG_MOD
  x = (x * LCG_MULT) % LCG_MOD
  return GLYPHS[(x % #GLYPHS) + 1]
end

-- Per-strand lifecycle: a bead runs `span` cells from the hole to the outer
-- radius, trails off for a while, then sits idle for a random per-strand
-- stretch before restarting at the hole. Deriving the phase from t alone
-- keeps the frame a pure function of (w, h, t), so no state is cleared on
-- SplashShown.
--
-- The arm set (base angles) is shared by every layer: parallax in the fall
-- rain came from near and far beads sharing the same columns and differing
-- only in speed and brightness. Separate arm families per layer read as
-- three overlapping lattices whose crossings moiré, not as depth.
local strands = {}
local function strands_for(w, h)
  local key = w * 10000 + h
  local st = strands[key]
  if st then
    return st
  end
  st = { arms = {}, layers = {} }
  local cx = (w + 1) / 2
  local cy = (h + 1) / 2
  st.cx = cx
  st.cy = cy
  st.span = math.max(2.0, math.sqrt(cx * cx + cy * cy) - SPIRAL_HOLE)
  st.twist = SPIRAL_TURNS * 2 * math.pi / st.span
  local count = math.max(2, math.floor(st.span * SPIRAL_ARMS + 0.5))
  for j = 1, count do
    local rng = make_rng(RAIN_SEED + (j - 1) * 7919)
    st.arms[j] = { base = ((j - 1) / count + (rng() - 0.5) / count) * 2 * math.pi }
  end
  for li = 1, #LAYERS do
    local layer = LAYERS[li]
    local arr = {}
    for j = 1, count do
      local rng = make_rng(RAIN_SEED + 1000003 + (li - 1) * 7919 * 1000 + (j - 1) * 7919)
      local speed = layer.speed[1] + (layer.speed[2] - layer.speed[1]) * rng()
      local trail = layer.trail[1] + math.floor(rng() * (layer.trail[2] - layer.trail[1] + 1))
      local wrap = st.span + trail
      local idle = math.floor(wrap * (layer.idle_max * rng()))
      local cycle = wrap + idle
      arr[j] = {
        speed = speed,
        trail = trail,
        wrap = wrap,
        cycle = cycle,
        offset = math.floor(rng() * cycle),
      }
    end
    st.layers[li] = arr
  end
  strands[key] = st
  return st
end

-- Every row comes out exactly w cells wide: the blitter walks the segments
-- left to right wrapping at w, so a short row would skew every row after it.
local function build_frame(w, h, t, fade, bg, fg, accent, tip)
  local bg_hex = hex(bg)
  local layer_levels = {}
  local layer_head = {}
  for li = 1, #LAYERS do
    local layer = LAYERS[li]
    local lv = {}
    for i = 0, BRIGHT_LEVELS - 1 do
      lv[i + 1] =
        hex(mix(bg, accent, ((BRIGHT_LEVELS - 1 - i) / (BRIGHT_LEVELS - 1)) * layer.bright * RAIN_BRIGHT * fade))
    end
    layer_levels[li] = lv
    local target = layer.head_fg and fg or accent
    layer_head[li] = { fg = hex(mix(bg, target, layer.head_alpha * fade)), bg = bg_hex, bold = layer.head_bold }
  end
  local sparkle_hex = hex(mix(bg, fg, SPARKLE_ALPHA * fade))

  local cells = {}
  local styles = {}
  for r = 1, h do
    cells[r] = {}
    styles[r] = {}
  end

  local st = strands_for(w, h)
  local cstep = math.cos(st.twist)
  local sstep = math.sin(st.twist)
  -- Far layers first, so near beads win any cell conflict.
  for li = #LAYERS, 1, -1 do
    local layer = LAYERS[li]
    local levels = layer_levels[li]
    local head_style = layer_head[li]
    local sparkly = li == 1
    local rate = layer.flicker
    for j = 1, #st.arms do
      local s = st.layers[li][j]
      local head = math.floor(t * s.speed) + s.offset
      local hp = head % s.cycle
      if hp < s.wrap then
        local r_head = SPIRAL_HOLE + hp
        local th = st.arms[j].base + st.twist * (r_head - SPIRAL_HOLE)
        local ux, uy = math.cos(th), math.sin(th)
        local key = j + (li - 1) * 500
        for d = 0, s.trail do
          local rd = r_head - d
          if rd >= SPIRAL_HOLE then
            local px = st.cx + rd * ux
            local py = st.cy + rd * uy
            local col = math.floor(px) + 1
            local row = math.floor(py) + 1
            if col >= 1 and col <= w and row >= 1 and row <= h then
              local k = head - d
              cells[row][col] = glyph_for(key, k, t, rate)
              if d == 0 then
                styles[row][col] = head_style
              elseif sparkly and k % SPARKLE_EVERY == 3 then
                styles[row][col] = sparkle_hex
              else
                styles[row][col] = levels[math.floor((d / s.trail) * BRIGHT_LEVELS) + 1]
              end
            end
          end
          local nx = ux * cstep + uy * sstep
          local ny = uy * cstep - ux * sstep
          ux, uy = nx, ny
        end
      end
    end
  end

  local function paint(row, x, text, style)
    if row < 1 or row > h then
      return
    end
    local chars = decode_chars(text)
    for i = 1, #chars do
      local c = x + i - 1
      if c >= 1 and c <= w then
        cells[row][c] = chars[i]
        styles[row][c] = style
      end
    end
  end

  local function text_style(target, alpha, bold)
    return { fg = hex(mix(bg, target, alpha)), bg = bg_hex, bold = bold }
  end

  local top_y = math.floor((h - BLOCK_HEIGHT) / 2)
  paint(
    top_y + 1,
    math.floor((w - charlen(LOGO)) / 2) + 1,
    LOGO,
    text_style(accent, 0.85 * ease_out_cubic((t - LOGO_DELAY) / LOGO_RAMP) * fade, true)
  )
  paint(top_y + 2, math.floor((w - charlen(TAGLINE)) / 2) + 1, TAGLINE, text_style(fg, 0.75 * fade, false))

  local help_total = 0
  for _, seg in ipairs(HELP) do
    help_total = help_total + charlen(seg[1])
  end
  local help_x = math.floor((w - help_total) / 2) + 1
  for _, seg in ipairs(HELP) do
    local target, alpha = fg, 0.5
    if seg[2] then
      target, alpha = accent, 0.75
    end
    paint(top_y + 4, help_x, seg[1], text_style(target, alpha * fade, false))
    help_x = help_x + charlen(seg[1])
  end

  local tip_label, tip_desc = TIPS[tip_idx][1], TIPS[tip_idx][2]
  local tip_total = #TIP_PREFIX + charlen(tip_label) + 1 + charlen(tip_desc)
  local tip_x = math.floor((w - tip_total) / 2) + 1
  paint(top_y + 6, tip_x, TIP_PREFIX, text_style(tip, 0.75 * fade, true))
  paint(top_y + 6, tip_x + #TIP_PREFIX, tip_label, text_style(accent, 0.75 * fade, false))
  paint(top_y + 6, tip_x + #TIP_PREFIX + charlen(tip_label), " ", text_style(bg, 1.0, false))
  paint(top_y + 6, tip_x + #TIP_PREFIX + charlen(tip_label) + 1, tip_desc, text_style(fg, 0.5 * fade, false))

  local version = maki.version()
  local version_text = "v" .. version.current
  if version.update_available then
    version_text = version_text .. " run maki update to get v" .. (version.latest or "")
  end
  paint(1, w - charlen(version_text), version_text, text_style(fg, 0.4 * fade, false))

  local rows = {}
  for r = 1, h do
    local segs = {}
    local run, run_style, first = "", nil, true
    for c = 1, w do
      local ch = cells[r][c] or " "
      local style = styles[r][c] or bg_hex
      if not first and style == run_style then
        run = run .. ch
      else
        if #run > 0 then
          segs[#segs + 1] = { glyphs = run, style = run_style }
        end
        run, run_style, first = ch, style, false
      end
    end
    if #run > 0 then
      segs[#segs + 1] = { glyphs = run, style = run_style }
    end
    rows[r] = segs
  end
  return rows
end

maki.api.create_autocmd("SplashShown", {
  callback = function()
    tip_idx = math.random(1, #TIPS)
  end,
})

maki.api.set_slot("splash.render", function(_prev, w, h, t, fade)
  if w == 0 or h == 0 then
    return {}
  end
  return build_frame(
    w,
    h,
    t,
    fade,
    theme_rgb("background", FALLBACK_BG),
    theme_rgb("foreground", FALLBACK_FG),
    theme_rgb("accent", FALLBACK_ACCENT),
    theme_rgb("todo_in_progress", FALLBACK_TIP)
  )
end)
