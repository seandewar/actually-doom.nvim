local M = {}

function M.play(...)
  return require("actually-doom.game").play(...)
end

function M.rebuild(...)
  return require("actually-doom.build").rebuild(...)
end

return M
