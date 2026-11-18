require("code_review")

local vortex = require("vortex")

makima.store.register("splash", "vortex", {
  label = "vortex",
  description = "Code spiraling toward you through a tunnel: purple heart, lunared red rim, signature at the eye.",
  renderer = vortex.render,
})
