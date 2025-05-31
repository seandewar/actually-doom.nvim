local M = {}

function M.setup(...)
  return require("actually-doom.config").setup(...)
end

function M.play(...)
  return require("actually-doom.game").play(...)
end

function M.rebuild(...)
  return require("actually-doom.build").rebuild(...)
end

return M
