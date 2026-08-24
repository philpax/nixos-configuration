-- Local vortex splash skin: a fire tunnel. Drops of code fall toward the
-- viewer from the screen center, winding in a slow vortex as they
-- approach. The spiral runs deep red at the eye to bright red at the rim,
-- and fast violet sparks streak ahead of it as a second layer.
-- A faint breathing glow lights the eye, and a slow layer of dust crawls
-- the funnel behind the drops. The signature and version sit at the eye.
-- Stateful, stepped by frame dt; resets when the home screen shows again.

local GLYPHS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789<>[]{}=+*/"
local Z_FAR = 8.0
local Z_MIN = 0.5
local DT_MAX = 0.25 -- cap the sim step so a t gap pauses, not teleports
local ASPECT = 0.55
local STREAK = 0.16
local TRAIL_MAX = 14
local SPIN = 1.0 -- rad of winding per unit ln(z) while approaching
local DUST_NEAR = 0.3 -- z at which a dust mote exits the funnel
local DUST_FAR = 22.0 -- z at which a dust mote is born
local DROPS_DIV = 7 -- terminal cells per drop
local DROPS_MIN = 90
local DROPS_MAX = 480
local DUST_DIV = 13 -- terminal cells per dust mote
local DUST_MIN = 70
local DUST_MAX = 380
local SPARK_NEAR = 1.1 -- z at which a spark respawns
local SPARKS_DIV = 35 -- terminal cells per spark
local SPARKS_MIN = 36
local SPARKS_MAX = 200
local SPARK_STREAK = 0.08 -- z-distance a spark trail spans behind its head
-- Per-frame color LUTs: the screen is a handful of quantized styles, so they
-- are computed once and indexed by coarse level instead of per cell.
local BG_LEVELS = 64 -- radial glow levels, eye to rim
local FIRE_VQ = 32 -- fire-ramp v levels
local FIRE_AQ = 16 -- fire brightness levels
local SPARK_UQ = 16 -- spark-ramp u levels
local SPARK_AQ = 16 -- spark brightness levels
-- Fire ramp stops, eye to rim: deep red to bright red.
local FIRE_STOPS = {
  { 170, 45, 55 },
  { 225, 65, 60 },
  { 255, 95, 75 },
}
-- Spark ramp stops, tail to head: deep purple to bright violet.
local SPARK_STOPS = {
  { 140, 35, 110 },
  { 220, 60, 170 },
  { 255, 95, 205 },
}
-- Version drift stops: purple to lunared red.
local VER_STOPS = {
  { 187, 134, 252 },
  { 255, 69, 69 },
}
local SIGN_TOP = "phil"
local SIGN_APOST = "'s"
local SIGN_BOTTOM = "makima"
local C_NAME = { 112, 80, 151 } -- purple, dimmed
local C_APOST = { 147, 147, 147 } -- white, dimmed
local C_LUNA = { 153, 41, 41 } -- lunared red, dimmed
local M = {}

local function theme_or(name, fallback)
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

local BG_HEX
local style_cache = {}

local function refresh_colors()
  local bg = theme_or("background", { 0, 0, 0 })
  -- The tunnel needs a dark backdrop; light themes get pure black.
  if 0.2126 * bg[1] + 0.7152 * bg[2] + 0.0722 * bg[3] > 70 then
    bg = { 0, 0, 0 }
  end
  BG_HEX = string.format("#%02x%02x%02x", bg[1], bg[2], bg[3])
  style_cache = {}
end

-- Style cache: always fetch styles through here and reuse the returned
-- table. The renderer coalesces runs of identical tables.
local function color(hex)
  local s = style_cache[hex]
  if not s then
    s = { fg = hex, bg = BG_HEX, bold = false }
    style_cache[hex] = s
  end
  return s
end

local W, H
local CX, CY, BG_SCALE
local DX2T
local bg_lut = {}
local fire_lut = {}
local spark_lut = {}

-- Overlay cells: the sparse non-background cells that particles and labels
-- write on top of the derived glow.
local function put(over, x, y, g, s)
  if x >= 1 and x <= W and y >= 1 and y <= H then
    local r = over[y]
    if not r then
      r = {}
      over[y] = r
    end
    r[x] = { g = g, s = s }
  end
end

local function place_text(over, row, x, text, st)
  if row < 1 or row > H then
    return
  end
  local r = over[row]
  if not r then
    r = {}
    over[row] = r
  end
  for i = 1, #text do
    local xx = x + i - 1
    if xx >= 1 and xx <= W then
      r[xx] = { g = string.sub(text, i, i), s = st }
    end
  end
end

-- Walk each row left to right, coalescing runs of identical style. The
-- background is derived from the radial LUT; `over` holds the cells the
-- particles and labels wrote on top of it.
local function build_rows(over)
  local rows = {}
  local last = BG_LEVELS - 1
  for y = 1, H do
    local dy = y - CY
    local dy2 = dy * dy
    local ov = over[y]
    local segs = {}
    local buf = {}
    local cur
    local function flush()
      if #buf > 0 then
        segs[#segs + 1] = { glyphs = table.concat(buf), style = cur }
        buf = {}
      end
    end
    for x = 1, W do
      local cell = ov and ov[x]
      local st, g
      if cell then
        st = cell.s
        g = cell.g
      else
        local li = math.sqrt(DX2T[x] + dy2) * BG_SCALE
        if li >= last then
          li = last
        else
          li = math.floor(li)
        end
        st = bg_lut[li + 1]
        g = " "
      end
      if st ~= cur then
        flush()
        cur = st
      end
      buf[#buf + 1] = g
    end
    flush()
    rows[y] = segs
  end
  return rows
end

local function flat_rows(w, h, st)
  local rows = {}
  for y = 1, h do
    rows[y] = { { glyphs = string.rep(" ", w), style = st } }
  end
  return rows
end

-- Quantize RGB (0-255) to 5 bits/channel and return the cached style table.
-- Quantizing keeps the style cache bounded; table identity is what the
-- renderer coalesces runs of cells on.
local function color_q(r, g, b)
  local function q(v)
    if v < 0 then
      v = 0
    elseif v > 255 then
      v = 255
    end
    return math.floor(v * 31 / 255 + 0.5) * 255 / 31
  end
  local hex = string.format("#%02x%02x%02x", math.floor(q(r) + 0.5), math.floor(q(g) + 0.5), math.floor(q(b) + 0.5))
  local s = style_cache[hex]
  if not s then
    s = { fg = hex, bg = BG_HEX, bold = false }
    style_cache[hex] = s
  end
  return s
end

local function fade_color(c, f)
  return color_q(c[1] * f, c[2] * f, c[3] * f)
end

-- Quantized point on a color ramp scaled by `f`, as a cached style.
-- u is position on the ramp (0 = first stop, 1 = last stop).
local function ramp(stops, u, f)
  if u < 0 then
    u = 0
  elseif u > 1 then
    u = 1
  end
  local n = #stops - 1
  local pos = u * n
  local i = math.floor(pos)
  if i >= n then
    i = n - 1
  end
  local a = stops[i + 1]
  local b = stops[i + 2]
  local v = pos - i
  return color_q(
    (a[1] + (b[1] - a[1]) * v) * f,
    (a[2] + (b[2] - a[2]) * v) * f,
    (a[3] + (b[3] - a[3]) * v) * f
  )
end

-- The red fire ramp: the drop spiral and the dust. v is approach
-- progress, 0 at the eye, 1 at the rim: dim deep-red glimmers at the eye,
-- bright red streaks at the rim.
local function fire(v, f)
  return ramp(FIRE_STOPS, v, f)
end

-- The violet ramp: the fast sparks, the second spiral. u runs tail to
-- head, so the head is the brightest violet in the scene.
local function spark(u, f)
  return ramp(SPARK_STOPS, u, f)
end

-- Per-frame style LUTs. The glow only takes a few distinct quantized colors,
-- so the radial levels are far finer than what the eye can separate.
local function build_luts(breathe)
  local last = BG_LEVELS - 1
  for i = 0, last do
    local u = i / last
    local one_m = 1 - u
    bg_lut[i + 1] = fire(one_m, (0.02 + 0.05 * one_m * one_m) * breathe)
  end
  local vm1 = FIRE_VQ - 1
  local am1 = FIRE_AQ - 1
  for vi = 0, vm1 do
    local row = {}
    fire_lut[vi + 1] = row
    local v = vi / vm1
    for ai = 0, am1 do
      row[ai + 1] = fire(v, ai / am1)
    end
  end
  local um1 = SPARK_UQ - 1
  local sam1 = SPARK_AQ - 1
  for ui = 0, um1 do
    local row = {}
    spark_lut[ui + 1] = row
    local u = ui / um1
    for ai = 0, sam1 do
      row[ai + 1] = spark(u, ai / sam1)
    end
  end
end

local function fire_at(v, a)
  local vi = math.floor(v * (FIRE_VQ - 1))
  if vi < 0 then
    vi = 0
  elseif vi > FIRE_VQ - 1 then
    vi = FIRE_VQ - 1
  end
  local ai = math.floor(a * (FIRE_AQ - 1))
  if ai > FIRE_AQ - 1 then
    ai = FIRE_AQ - 1
  end
  return fire_lut[vi + 1][ai + 1]
end

local function spark_at(u, a)
  local ui = math.floor(u * (SPARK_UQ - 1))
  if ui > SPARK_UQ - 1 then
    ui = SPARK_UQ - 1
  end
  local ai = math.floor(a * (SPARK_AQ - 1))
  if ai > SPARK_AQ - 1 then
    ai = SPARK_AQ - 1
  end
  return spark_lut[ui + 1][ai + 1]
end

local function glyph()
  local i = math.random(1, #GLYPHS)
  return string.sub(GLYPHS, i, i)
end

local state = { drops = nil, dust = nil, sparks = nil, key = nil, last_t = nil }

maki.api.create_autocmd("SplashShown", {
  callback = function()
    state.drops = nil
    state.dust = nil
    state.sparks = nil
    state.key = nil
    state.last_t = nil
  end,
})

local function spawn(d)
  d.z = Z_FAR * (0.75 + 0.25 * math.random())
  d.phi = math.random() * 2 * math.pi
  d.speed = 0.7 + math.random() * 0.6
  d.spin = SPIN * (0.85 + math.random() * 0.3)
  d.tint_jitter = math.random() * 0.24 - 0.12
  d.char = glyph()
  d.mutate_at = 0.7 + math.random() * 1.3
end

local function make_drops()
  local n = math.floor(math.max(DROPS_MIN, math.min(DROPS_MAX, W * H / DROPS_DIV)))
  local drops = {}
  for i = 1, n do
    local d = {}
    spawn(d)
    d.z = Z_MIN + math.random() * (Z_FAR - Z_MIN)
    drops[i] = d
  end
  return drops
end

local function spawn_dust(d)
  d.z = DUST_FAR * (0.75 + 0.25 * math.random())
  d.phi = math.random() * 2 * math.pi
  d.speed = 0.08 + math.random() * 0.14
  d.spin = SPIN * 0.6 * (0.85 + math.random() * 0.3)
  d.tint_jitter = math.random() * 0.16 - 0.08
end

local function make_dust()
  local n = math.floor(math.max(DUST_MIN, math.min(DUST_MAX, W * H / DUST_DIV)))
  local dust = {}
  for i = 1, n do
    local d = {}
    spawn_dust(d)
    d.z = DUST_NEAR + math.random() * (DUST_FAR - DUST_NEAR)
    dust[i] = d
  end
  return dust
end

local function spawn_spark(d)
  d.z = 3.0 + math.random() * (Z_FAR - 3.0)
  d.phi = math.random() * 2 * math.pi
  d.speed = 2.2 + math.random() * 1.8
  d.spin = SPIN * 1.4 * (0.85 + math.random() * 0.3)
  d.char = glyph()
end

local function make_sparks()
  local n = math.floor(math.max(SPARKS_MIN, math.min(SPARKS_MAX, W * H / SPARKS_DIV)))
  local sparks = {}
  for i = 1, n do
    local d = {}
    spawn_spark(d)
    d.z = SPARK_NEAR + math.random() * (Z_FAR - SPARK_NEAR)
    sparks[i] = d
  end
  return sparks
end

function M.render(w, h, t, fade)
  refresh_colors()
  W, H = w, h
  local f = fade or 1.0
  if w < 20 or h < 10 then
    return flat_rows(w, h, color(BG_HEX))
  end

  local key = w .. "x" .. h
  if state.key ~= key then
    state.key = key
    state.drops = make_drops()
    state.dust = make_dust()
    state.sparks = make_sparks()
    state.last_t = nil
    -- The vanishing point sits fixed at the screen center.
    CX = (w + 1) / 2
    CY = (h + 1) / 2
    -- Per-column dx^2, rebuilt only on resize.
    DX2T = {}
    for x = 1, w do
      local dx = x - CX
      DX2T[x] = dx * dx
    end
  end
  local drops = state.drops
  local dust = state.dust
  local sparks = state.sparks

  local dt = state.last_t and math.max(0, t - state.last_t) or 0
  if dt > DT_MAX then
    dt = DT_MAX
  end
  state.last_t = t

  local Rmax = w / 2
  local diag = math.sqrt((w / 2) ^ 2 + (h / 2) ^ 2)
  BG_SCALE = (BG_LEVELS - 1) / Rmax

  for i = 1, #drops do
    local d = drops[i]
    d.z = d.z - d.speed * dt
    -- Angular velocity scales with 1/z, so near drops sweep around the
    -- vanishing point faster: the field winds into a vortex as it approaches.
    d.phi = d.phi - d.spin * dt / (d.z + 0.35)
    d.mutate_at = d.mutate_at - dt
    if d.mutate_at <= 0 then
      d.char = glyph()
      d.mutate_at = 0.7 + math.random() * 1.3
    end
    -- Respawn once the drop has passed the near plane or flown off the
    -- screen. The z < Z_MIN arm catches negative z that a large dt step can
    -- overshoot, where Rmax / z (negative) would otherwise never respawn.
    if d.z < Z_MIN or Rmax / d.z >= diag then
      spawn(d)
    end
  end

  -- The dust crawls the same funnel much slower than the drops: a deep
  -- parallax layer that traces the vortex spiral behind them.
  for i = 1, #dust do
    local d = dust[i]
    d.z = d.z - d.speed * dt
    d.phi = d.phi - d.spin * dt / (d.z + 0.35)
    if d.z < DUST_NEAR then
      spawn_dust(d)
    end
  end

  -- Sparks run the funnel much faster than the drops.
  for i = 1, #sparks do
    local s = sparks[i]
    s.z = s.z - s.speed * dt
    s.phi = s.phi - s.spin * dt / (s.z + 0.35)
    if s.z < SPARK_NEAR then
      spawn_spark(s)
    end
  end

  -- Far (dim) drops first so near (bright) streaks draw on top.
  table.sort(drops, function(a, b)
    return a.z > b.z
  end)

  -- Background: a faint radial glow lighting the eye of the vortex, breathing
  -- on an ~18s period. It is derived per row in build_rows from the LUT, so
  -- particles write only the cells they cover.
  local breathe = 1 + 0.15 * math.sin(t * 0.35)
  build_luts(breathe)

  local over = {}
  for i = 1, #dust do
    local d = dust[i]
    local R = Rmax / d.z
    local x = math.floor(CX + R * math.cos(d.phi) + 0.5)
    local y = math.floor(CY + R * math.sin(d.phi) * ASPECT + 0.5)
    if x >= 1 and x <= w and y >= 1 and y <= h then
      local br = R / h
      if br > 1 then
        br = 1
      end
      local v = (DUST_FAR - d.z) / (DUST_FAR - DUST_NEAR)
      put(over, x, y, ".", fire_at(v + d.tint_jitter, (0.12 + 0.45 * br * br) * f))
    end
  end
  for i = 1, #drops do
    local d = drops[i]
    local R = Rmax / d.z
    local br = R / h
    if br > 1 then
      br = 1
    end
    br = br * br * br
    local trail = math.floor(R * d.speed / d.z * 0.12) + 2
    if trail > TRAIL_MAX then
      trail = TRAIL_MAX
    end
    local dz = d.speed * STREAK / (trail - 1)
    -- The drop rotated while it travelled the trail length; unwind phi per
    -- segment so the streak follows the drop's true spiral arc.
    local dphi = d.spin * STREAK / (trail - 1)
    for j = trail - 1, 0, -1 do
      local zj = d.z + j * dz
      local Rj = Rmax / zj
      local phij = d.phi + dphi * j / (zj + 0.35)
      local x = math.floor(CX + Rj * math.cos(phij) + 0.5)
      local y = math.floor(CY + Rj * math.sin(phij) * ASPECT + 0.5)
      if x >= 1 and x <= w and y >= 1 and y <= h then
        local brj = br * (1 - j / trail)
        brj = brj * brj
        -- Each segment takes the fire color at its own z, so the streak
        -- runs bright red at the rim and dims to deep red toward the eye.
        local v = (Z_FAR - zj) / (Z_FAR - Z_MIN) + d.tint_jitter
        local st
        if j == 0 then
          st = fire_at(v, (0.3 + 0.65 * br) * f)
        else
          st = fire_at(v, (0.12 + 0.7 * brj) * f)
        end
        local size = 1 + (Rj > 0.5 * Rmax and 1 or 0) + (Rj > 0.8 * Rmax and 1 or 0)
        local half = math.floor((size - 1) / 2)
        for dy = 0, size - 1 do
          for dx = 0, size - 1 do
            put(over, x - half + dx, y - half + dy, d.char, st)
          end
        end
      end
    end
  end

  -- Far (dim) sparks first so near (bright) ones draw on top; the whole
  -- layer draws last, on top of the drops, as the foreground.
  table.sort(sparks, function(a, b)
    return a.z > b.z
  end)
  for i = 1, #sparks do
    local s = sparks[i]
    local R = Rmax / s.z
    local br = R / h
    if br > 1 then
      br = 1
    end
    local trail = math.floor(R * s.speed / s.z * 0.05) + 2
    if trail > 5 then
      trail = 5
    end
    local dz = s.speed * SPARK_STREAK / (trail - 1)
    local dphi = s.spin * SPARK_STREAK / (trail - 1)
    for j = trail - 1, 0, -1 do
      local zj = s.z + j * dz
      local Rj = Rmax / zj
      local phij = s.phi + dphi * j / (zj + 0.35)
      local xx = math.floor(CX + Rj * math.cos(phij) + 0.5)
      local yy = math.floor(CY + Rj * math.sin(phij) * ASPECT + 0.5)
      if xx >= 1 and xx <= w and yy >= 1 and yy <= h then
        local brj = br * (1 - j / trail)
        brj = brj * brj
        local st = spark_at(1 - j / trail, (0.35 + 0.65 * brj) * f)
        if j == 0 then
          st = spark_at(1, (0.55 + 0.45 * br) * f)
        end
        put(over, xx, yy, s.char, st)
      end
    end
  end

  -- The signature and version sit at the eye of the vortex. Quantize cx
  -- once and anchor all lines on that column so they shift in lockstep
  -- instead of snapping independently.
  local anchor = math.floor(CX + 0.5)
  local top_row = math.floor(CY - 0.5)
  local bot_row = math.floor(CY + 0.5)
  local x1 = anchor - math.floor((#SIGN_TOP + #SIGN_APOST) / 2)
  place_text(over, top_row, x1, SIGN_TOP, fade_color(C_NAME, f))
  place_text(over, top_row, x1 + #SIGN_TOP, SIGN_APOST, fade_color(C_APOST, f))
  place_text(over, bot_row, anchor - math.floor(#SIGN_BOTTOM / 2), SIGN_BOTTOM, fade_color(C_LUNA, f))

  -- Version beneath the signature, drifting along the heat gradient so the
  -- furniture never sits still.
  local ver = "v" .. maki.version().current
  place_text(over, bot_row + 1, anchor - math.floor(#ver / 2), ver, ramp(VER_STOPS, 0.5 + 0.25 * math.sin(t * 0.23), 0.5 * f))
  return build_rows(over)
end

return M