-- IPD heads-up readout for the Valve Index on Monado.
--
-- The Index's IPD is a physical dial; Monado reports whatever it's set to but
-- has no in-headset readout. This overlay watches the inter-eye distance (the
-- separation between the two view poses *is* the IPD) and, whenever it changes
-- by more than a nudge, fades a small readout into the lower-right of your view.

local SHOW_TIME = 2.5    -- seconds to keep the readout up after the last change
local FADE_IN   = 0.15
local FADE_OUT  = 0.6

-- The reported view poses jitter by a couple of tenths of a millimetre even
-- with the dial untouched, which is enough to trip a naive threshold. Smooth
-- the reading first: noise averages out over this time constant, while a real
-- turn of the dial is large enough to come through it near-instantly.
local SMOOTH_S  = 0.3

-- Deadzone: while the readout is asleep it takes a deliberate turn of the dial
-- to wake it. Once awake, finer movement keeps it alive, so a coarse
-- adjustment followed by fine-tuning stays on screen until the dial settles.
local WAKE_MM   = 0.6
local TRACK_MM  = 0.15

local DISTANCE  = 1.6    -- metres in front of the head
local OFFSET_X  = 0.42   -- metres right of centre at that distance (~15 degrees)
local OFFSET_Y  = -0.32  -- metres below centre (~11 degrees)

-- accent / palette
local ACCENT = { 0.36, 0.78, 0.92 }
local PANEL  = { 0.04, 0.05, 0.08 }
local MUTED  = { 0.72, 0.77, 0.84 }

-- alpha ceilings, so the panel stays something you glance at rather than read
local PANEL_ALPHA  = 0.5
local BORDER_ALPHA = 0.35
local TEXT_ALPHA   = 0.8

-- `ipd` is the smoothed reading; `mark` is the value the readout was last
-- reconciled with — the resting IPD while asleep, and the last motion we
-- reacted to while awake.
local state = { ipd = nil, mark = nil, timer = 0 }

-- Set IPD_DEBUG=1 to print the smoothed reading and its wander once a second,
-- which is how you find the real noise floor to size WAKE_MM against.
local DEBUG = os.getenv('IPD_DEBUG') ~= nil
local debugState = { t = 0, lo = nil, hi = nil }

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

local function logNoise(ipd, dt)
  debugState.t = debugState.t + dt
  debugState.lo = math.min(debugState.lo or ipd, ipd)
  debugState.hi = math.max(debugState.hi or ipd, ipd)
  if debugState.t >= 1 then
    print(string.format('ipd %.3f mm  (1s spread %.3f mm)',
      ipd, debugState.hi - debugState.lo))
    debugState.t, debugState.lo, debugState.hi = 0, nil, nil
  end
end

function lovr.update(dt)
  local raw = readIPD()
  if raw then
    -- exponential low-pass; frame-rate independent
    if not state.ipd then
      state.ipd = raw
    else
      state.ipd = state.ipd + (raw - state.ipd) * (1 - math.exp(-dt / SMOOTH_S))
    end
    local ipd = state.ipd

    if not state.mark then
      state.mark = ipd -- first reading is the resting point, don't flash for it
    else
      local awake = state.timer > 0
      local threshold = awake and TRACK_MM or WAKE_MM
      if math.abs(ipd - state.mark) >= threshold then
        state.mark = ipd
        state.timer = SHOW_TIME
      end
    end

    if DEBUG then logNoise(ipd, dt) end
  end
  if state.timer > 0 then
    state.timer = math.max(0, state.timer - dt)
    -- on settling, re-anchor the deadzone to wherever the dial ended up
    if state.timer == 0 and state.ipd then state.mark = state.ipd end
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

  -- Head-locked, parked down and to the right, then aimed back at the head so
  -- it isn't read edge-on from its off-axis position.
  local base = mat4(lovr.headset.getPose('head'))
    :translate(OFFSET_X, OFFSET_Y, -DISTANCE)
    :rotate(-math.atan(OFFSET_X / DISTANCE), 0, 1, 0)
    :rotate(math.atan(OFFSET_Y / DISTANCE), 1, 0, 0)

  -- faint accent frame behind a darker panel
  pass:setColor(ACCENT[1], ACCENT[2], ACCENT[3], BORDER_ALPHA * a)
  pass:plane(mat4(base):scale(0.30, 0.135, 1))
  pass:setColor(PANEL[1], PANEL[2], PANEL[3], PANEL_ALPHA * a)
  pass:plane(mat4(base):translate(0, 0, 0.001):scale(0.288, 0.123, 1))

  -- caption
  pass:setColor(ACCENT[1], ACCENT[2], ACCENT[3], TEXT_ALPHA * a)
  pass:text('IPD', mat4(base):translate(0, 0.037, 0.003):scale(0.022))

  -- value
  pass:setColor(1, 1, 1, TEXT_ALPHA * a)
  pass:text(string.format('%.1f', state.ipd),
    mat4(base):translate(-0.017, -0.018, 0.003):scale(0.062))

  -- unit
  pass:setColor(MUTED[1], MUTED[2], MUTED[3], TEXT_ALPHA * a)
  pass:text('mm', mat4(base):translate(0.072, -0.028, 0.003):scale(0.026))
end
