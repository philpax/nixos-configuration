-- IPD heads-up readout for the Valve Index on Monado.
--
-- The Index's IPD is a physical dial; Monado reports whatever it's set to but
-- has no in-headset readout. This overlay watches the inter-eye distance (the
-- separation between the two view poses *is* the IPD) and, whenever it changes,
-- flashes the value centred in your view, then fades out.

local SHOW_TIME = 2.5   -- seconds to keep the readout up after the last change
local FADE_IN   = 0.15
local FADE_OUT  = 0.6
local CHANGE_MM = 0.1   -- re-show once IPD drifts this far from the anchor
local DISTANCE  = 2.0   -- metres in front of the head

-- accent / palette
local ACCENT = { 0.36, 0.78, 0.92 }
local PANEL  = { 0.04, 0.05, 0.08 }
local MUTED  = { 0.72, 0.77, 0.84 }

local state = { ipd = nil, anchor = nil, timer = 0 }

function lovr.load()
  lovr.graphics.setBackgroundColor(0, 0, 0, 0)
end

local function readIPD()
  if lovr.headset.getViewCount() < 2 then return nil end
  local x1, y1, z1 = lovr.headset.getViewPose(1)
  local x2, y2, z2 = lovr.headset.getViewPose(2)
  if not (x1 and x2) then return nil end
  local dx, dy, dz = x2 - x1, y2 - y1, z2 - z1
  local mm = math.sqrt(dx * dx + dy * dy + dz * dz) * 1000
  if mm < 40 or mm > 90 then return nil end -- ignore garbage before tracking settles
  return mm
end

function lovr.update(dt)
  local ipd = readIPD()
  if ipd then
    if not state.anchor or math.abs(ipd - state.anchor) >= CHANGE_MM then
      state.anchor = ipd
      state.timer = SHOW_TIME
    end
    state.ipd = ipd
  end
  if state.timer > 0 then
    state.timer = math.max(0, state.timer - dt)
  end
end

local function opacity()
  local elapsed = SHOW_TIME - state.timer
  local a = 1
  if elapsed < FADE_IN then a = elapsed / FADE_IN end
  if state.timer < FADE_OUT then a = math.min(a, state.timer / FADE_OUT) end
  return a
end

function lovr.draw(pass)
  if state.timer <= 0 or not state.ipd then return end
  local a = opacity()

  pass:setDepthTest()  -- overlay: always draw on top, ignore depth

  -- head-locked anchor: centred, a couple of metres ahead, dropped slightly so
  -- it sits just below the line of sight rather than dead-centre.
  local base = mat4(lovr.headset.getPose('head')):translate(0, -0.03, -DISTANCE)

  -- accent frame behind a darker panel
  pass:setColor(ACCENT[1], ACCENT[2], ACCENT[3], 0.9 * a)
  pass:plane(mat4(base):scale(0.66, 0.36, 1))
  pass:setColor(PANEL[1], PANEL[2], PANEL[3], 0.85 * a)
  pass:plane(mat4(base):translate(0, 0, 0.001):scale(0.63, 0.33, 1))

  -- caption
  pass:setColor(ACCENT[1], ACCENT[2], ACCENT[3], a)
  pass:text('IPD', mat4(base):translate(0, 0.085, 0.003):scale(0.045))

  -- accent underline
  pass:plane(mat4(base):translate(0, 0.045, 0.003):scale(0.30, 0.004, 1))

  -- big value
  pass:setColor(1, 1, 1, a)
  pass:text(string.format('%.1f', state.ipd),
    mat4(base):translate(0, -0.025, 0.003):scale(0.16))

  -- unit
  pass:setColor(MUTED[1], MUTED[2], MUTED[3], a)
  pass:text('mm', mat4(base):translate(0, -0.12, 0.003):scale(0.04))
end
