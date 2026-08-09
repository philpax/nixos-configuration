function lovr.conf(t)
  -- Run as an OpenXR overlay session so we composite on top of WayVR / the
  -- active app instead of taking over the scene. The number is the layer's
  -- sort order (higher = nearer the top of the overlay stack).
  t.headset.overlay = 6

  -- Headset-only: no desktop mirror window cluttering the niri layout.
  t.window = nil
end
