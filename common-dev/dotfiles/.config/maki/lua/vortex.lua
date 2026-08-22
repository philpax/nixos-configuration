-- Local vortex splash skin: a code tunnel. Drops of code fall toward the
-- viewer from the screen center, winding in a slow vortex as they
-- approach: dim glimmers at the heart, long bright curved streaks at the rim.
-- Color sweeps from purple at the heart to lunared red at the rim. A faint
-- breathing glow lights the eye, and a deeper, slower layer of dust crawls
-- down the same funnel behind the drops.
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
local C_PURPLE = { 187, 134, 252 } -- particle heat at spawn
local C_RED = { 255, 69, 69 } -- particle heat at the rim (lunared red)
local SIGN_TOP = "phil"
local SIGN_APOST = "'s"
local SIGN_BOTTOM = "lunamaki"
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

local function place_text(grid, row, x, text, st)
  if row < 1 or row > H then
    return
  end
  local r = grid[row]
  for i = 1, #text do
    local xx = x + i - 1
    if xx >= 1 and xx <= W then
      r[xx] = { glyph = string.sub(text, i, i), style = st }
    end
  end
end

local function build_rows(grid)
  local rows = {}
  for y = 1, H do
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
      local cell = grid[y][x]
      if cell.style ~= cur then
        flush()
        cur = cell.style
      end
      buf[#buf + 1] = cell.glyph
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

-- Quantized lerp between two RGB colors scaled by `f`, as a cached style.
-- u is position on the heat gradient (0 = cold purple end, 1 = hot red end).
local function mix(c1, c2, u, f)
  return color_q(
    (c1[1] + (c2[1] - c1[1]) * u) * f,
    (c1[2] + (c2[2] - c1[2]) * u) * f,
    (c1[3] + (c2[3] - c1[3]) * u) * f
  )
end

local function glyph()
  local i = math.random(1, #GLYPHS)
  return string.sub(GLYPHS, i, i)
end

local state = { drops = nil, dust = nil, key = nil, last_t = nil }

maki.api.create_autocmd("SplashShown", {
  callback = function()
    state.drops = nil
    state.dust = nil
    state.key = nil
    state.last_t = nil
  end,
})

local function spawn(d)
  d.z = Z_FAR * (0.75 + 0.25 * math.random())
  d.phi = math.random() * 2 * math.pi
  d.speed = 0.7 + math.random() * 0.6
  d.spin = SPIN * (0.85 + math.random() * 0.3)
  d.tint_jitter = math.random() * 0.1 - 0.05
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
    state.last_t = nil
  end
  local drops = state.drops
  local dust = state.dust

  local dt = state.last_t and math.max(0, t - state.last_t) or 0
  if dt > DT_MAX then
    dt = DT_MAX
  end
  state.last_t = t

  -- The vanishing point sits fixed at the screen center.
  local cx = (w + 1) / 2
  local cy = (h + 1) / 2
  local Rmax = w / 2
  local diag = math.sqrt((w / 2) ^ 2 + (h / 2) ^ 2)

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

  -- Far (dim) drops first so near (bright) streaks draw on top.
  table.sort(drops, function(a, b)
    return a.z > b.z
  end)

  -- Background: a faint radial glow lighting the eye of the vortex, breathing
  -- on an ~18s period. Dust and drops are drawn on top.
  local breathe = 1 + 0.15 * math.sin(t * 0.35)
  local grid = {}
  for y = 1, h do
    local row = {}
    grid[y] = row
    local dy = y - cy
    for x = 1, w do
      local dx = x - cx
      local u = math.sqrt(dx * dx + dy * dy) / Rmax
      if u > 1 then
        u = 1
      end
      local glow = (0.03 + 0.06 * (1 - u) * (1 - u)) * breathe
      row[x] = { glyph = " ", style = mix(C_PURPLE, C_RED, u, glow) }
    end
  end
  for i = 1, #dust do
    local d = dust[i]
    local R = Rmax / d.z
    local x = math.floor(cx + R * math.cos(d.phi) + 0.5)
    local y = math.floor(cy + R * math.sin(d.phi) * ASPECT + 0.5)
    if x >= 1 and x <= w and y >= 1 and y <= h then
      local br = R / h
      if br > 1 then
        br = 1
      end
      local p = 1 - (d.z - DUST_NEAR) / (DUST_FAR - DUST_NEAR)
      local st = mix(C_PURPLE, C_RED, p, (0.12 + 0.45 * br * br) * f)
      grid[y][x] = { glyph = ".", style = st }
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
    local p = 1 - (d.z - Z_MIN) / (Z_FAR - Z_MIN)
    if p < 0 then
      p = 0
    elseif p > 1 then
      p = 1
    end
    local u = p + d.tint_jitter
    if u < 0 then
      u = 0
    elseif u > 1 then
      u = 1
    end
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
      local x = math.floor(cx + Rj * math.cos(phij) + 0.5)
      local y = math.floor(cy + Rj * math.sin(phij) * ASPECT + 0.5)
      if x >= 1 and x <= w and y >= 1 and y <= h then
        local brj = br * (1 - j / trail)
        brj = brj * brj
        -- The head is nudged toward the hot (red) end of the gradient; the
        -- tail decays toward black on the drop's own life color so the whole
        -- streak carries its tint.
        local st
        if j == 0 then
          local uh = u + 0.1
          if uh > 1 then
            uh = 1
          end
          st = mix(C_PURPLE, C_RED, uh, (0.3 + 0.65 * br) * f)
        else
          st = mix(C_PURPLE, C_RED, u, (0.12 + 0.7 * brj) * f)
        end
        local size = 1 + (Rj > 0.5 * Rmax and 1 or 0) + (Rj > 0.8 * Rmax and 1 or 0)
        local half = math.floor((size - 1) / 2)
        for dy = 0, size - 1 do
          for dx = 0, size - 1 do
            local xx = x - half + dx
            local yy = y - half + dy
            if xx >= 1 and xx <= w and yy >= 1 and yy <= h then
              grid[yy][xx] = { glyph = d.char, style = st }
            end
          end
        end
      end
    end
  end

  -- The signature and version sit at the eye of the vortex. Quantize cx
  -- once and anchor all lines on that column so they shift in lockstep
  -- instead of snapping independently.
  local anchor = math.floor(cx + 0.5)
  local top_row = math.floor(cy - 0.5)
  local bot_row = math.floor(cy + 0.5)
  local x1 = anchor - math.floor((#SIGN_TOP + #SIGN_APOST) / 2)
  place_text(grid, top_row, x1, SIGN_TOP, fade_color(C_NAME, f))
  place_text(grid, top_row, x1 + #SIGN_TOP, SIGN_APOST, fade_color(C_APOST, f))
  place_text(grid, bot_row, anchor - math.floor(#SIGN_BOTTOM / 2), SIGN_BOTTOM, fade_color(C_LUNA, f))

  -- Version beneath the signature, drifting along the heat gradient so the
  -- furniture never sits still.
  local ver = "v" .. maki.version().current
  place_text(grid, bot_row + 1, anchor - math.floor(#ver / 2), ver, mix(C_PURPLE, C_RED, 0.5 + 0.25 * math.sin(t * 0.23), 0.5 * f))
  return build_rows(grid)
end

return M