local api = vim.api
local fn = vim.fn
local fs = vim.fs
local uv = vim.uv

local data_dir = fn.stdpath "data"

local M = {
  exe_install_path = fs.joinpath(
    data_dir,
    "actually-doom.nvim",
    "actually-doom"
  ),
}

local script_dir = (function()
  return fs.dirname(fs.abspath(debug.getinfo(2, "S").source:sub(2)))
end)()

local src_dir = fs.normalize(
  fs.joinpath(script_dir, "../../doom/src"),
  { expand_env = false }
)

local augroup = api.nvim_create_augroup("actually-doom.build", {})

local object_names = {
  "am_map.o",
  "d_event.o",
  "d_items.o",
  "d_iwad.o",
  "d_loop.o",
  "d_main.o",
  "d_mode.o",
  "d_net.o",
  "doomstat.o",
  "dstrings.o",
  "f_finale.o",
  "f_wipe.o",
  "g_game.o",
  "hu_lib.o",
  "hu_stuff.o",
  "i_cdmus.o",
  "i_endoom.o",
  "i_input.o",
  "i_joystick.o",
  "i_scale.o",
  "i_sound.o",
  "i_system.o",
  "i_timer.o",
  "i_video.o",
  "info.o",
  "m_argv.o",
  "m_bbox.o",
  "m_cheat.o",
  "m_config.o",
  "m_controls.o",
  "m_fixed.o",
  "m_menu.o",
  "m_misc.o",
  "m_random.o",
  "memio.o",
  "p_ceilng.o",
  "p_doors.o",
  "p_enemy.o",
  "p_floor.o",
  "p_inter.o",
  "p_lights.o",
  "p_map.o",
  "p_maputl.o",
  "p_mobj.o",
  "p_plats.o",
  "p_pspr.o",
  "p_saveg.o",
  "p_setup.o",
  "p_sight.o",
  "p_spec.o",
  "p_switch.o",
  "p_telept.o",
  "p_tick.o",
  "p_user.o",
  "r_bsp.o",
  "r_data.o",
  "r_draw.o",
  "r_main.o",
  "r_plane.o",
  "r_segs.o",
  "r_sky.o",
  "r_things.o",
  "s_sound.o",
  "sha1.o",
  "sounds.o",
  "st_lib.o",
  "st_stuff.o",
  "statdump.o",
  "tables.o",
  "v_video.o",
  "w_checksum.o",
  "w_file.o",
  "w_file_stdc.o",
  "w_main.o",
  "w_wad.o",
  "wi_stuff.o",
  "z_zone.o",
  "doomgeneric.o",
  "doomgeneric_actually.o",
}

local cflags = {
  "-std=c99",
  "-Wall",
  "-Wextra",
  "-Wpedantic",
  "-D_POSIX_C_SOURCE=199309",
  "-D_GNU_SOURCE",
  "-g",
  "-O3",
  "-flto",
}

--- @return boolean
--- @nodiscard
local function needs_rebuild()
  local exe_stat, exe_stat_err_msg, exe_stat_err =
    uv.fs_stat(M.exe_install_path)
  if not exe_stat and exe_stat_err ~= "ENOENT" then
    error(
      ('Unexpected stat error while checking "%s": %s'):format(
        M.exe_install_path,
        exe_stat_err_msg
      ),
      0
    )
  end
  if not exe_stat then
    return true -- Executable does not exist.
  end

  -- Executable exists, but may be out-of-date. Compare its last modification
  -- time against that of its source and header files.
  for name, type in fs.dir(src_dir) do
    if type == "file" and (name:find "%.c$" or name:find "%.h$") then
      local path = fs.joinpath(src_dir, name)
      local stat, stat_err_msg = uv.fs_stat(path)
      if not stat then
        error(
          ('Unexpected stat error while checking "%s": %s'):format(
            path,
            stat_err_msg
          ),
          0
        )
      end

      if
        stat.mtime.sec > exe_stat.mtime.sec
        or (
          stat.mtime.sec == exe_stat.mtime.sec
          and stat.mtime.nsec >= exe_stat.mtime.nsec
        )
      then
        return true -- Source file is newer; should rebuild.
      end
    end
  end

  return false
end

--- @param console Console
--- @param result_cb fun(ok: boolean, rv: any) Called after at least one event loop tick.
local function acquire_lock(console, result_cb)
  local lock_path = fs.joinpath(data_dir, ".~actually-doom.nvim.lock")
  local fd

  local function release_lock()
    if fd then -- Don't delete the lock if we didn't open it...
      local ok, err_msg = uv.fs_unlink(lock_path)
      if not ok then
        console:plugin_print(
          ("Failed to delete build lock file: %s\n"):format(err_msg),
          "Warn"
        )
      end
    end
  end

  --- @param f fun(): fun()?
  --- @return fun(...)
  --- @nodiscard
  local function co_wrap(f)
    return coroutine.wrap(function()
      local ok, rv = pcall(f)

      if fd then
        local close_ok, close_err = uv.fs_close(fd)
        if not close_ok then
          console:plugin_print(
            ("Failed to close file descriptor to build lock file: %s\n"):format(
              close_err
            ),
            "Warn"
          )
        end
      end
      if not ok then
        release_lock()
      end

      result_cb(ok, rv)
    end)
  end

  -- Using coroutines here to make the logic seem procedural, to guard against
  -- callback hell.
  --
  -- This approach relies on the fact that asynchronous luv calls are guaranteed
  -- to happen after at least one event loop tick (:h luv), so there should be
  -- no case where the callbacks try to resume the coroutine before it yields.

  local co
  co = co_wrap(function()
    console:plugin_print(
      ('Acquiring build lock file at "%s"...\n'):format(lock_path),
      "Debug"
    )

    -- Don't want many rebuilds to the same directory happening at once!
    -- Attempt to (atomically!) create the lock file, or fail if it exists.
    -- 420 (blaze it) is octal 644, which is -rw-r--r--.
    assert(uv.fs_open(lock_path, "wx", 420, co))
    local open_err
    open_err, fd = coroutine.yield()
    if not fd then
      if open_err:find "^EEXIST:" then
        -- Lock file already exists! Could check that the process that created
        -- it is not running (in case it crashed, etc.), but it's not easy to
        -- read the PID without a race condition (at least without flock).
        -- TODO: maybe prompt the user or try again?
        error(
          (
            'Build lock file already exists at "%s"; '
            .. "a rebuild is likely already in-progress!"
          ):format(lock_path),
          0
        )
      else
        error(
          ('Failed to create build lock file at "%s": %s'):format(
            lock_path,
            open_err
          ),
          0
        )
      end
    end

    --- @cast fd integer
    local pipe = assert(uv.new_pipe())
    assert(pipe:open(fd))
    assert(
      pipe:write(("%d\n%d"):format(uv.os_getpid(), assert(uv.uptime())), co)
    )
    local write_err = coroutine.yield()
    if write_err then
      error(("Failed to write to build lock file: %s"):format(write_err), 0)
    end

    assert(uv.fs_fsync(fd, co))
    local sync_err, sync_ok = coroutine.yield()
    if not sync_ok then
      -- Lame, but maybe OK as long as all processes are local.
      console:plugin_print(
        ("Failed to sync build lock file contents to disk: %s\n"):format(
          sync_err
        ),
        "Warn"
      )
    end

    return release_lock
  end)

  co()
end

--- @param console Console?
--- @param force boolean?
--- @param result_cb fun(ok: boolean, err: any?)?
function M.rebuild(console, force, result_cb)
  result_cb = result_cb or function(_) end
  console = console or require("actually-doom.ui").Console.new()

  local finished = false
  local pid_to_process = {} --- @type table<integer, vim.SystemObj>
  local release_lock = function() end
  local leave_autocmd
  local out_dir

  --- @param ok boolean
  --- @param err any?
  local function finish(ok, err)
    finished = true
    if not ok then
      console:plugin_print(("Build error: %s\n"):format(err), "Error")
    end

    for _, process in pairs(pid_to_process) do
      process:kill "sigterm" -- Could wait for them to quit, but probably fine.
    end

    vim.schedule(function()
      if out_dir then
        console:plugin_print "Cleaning up the temporary build directory...\n"
        if fn.delete(out_dir, "rf") == -1 then
          console:plugin_print(
            ('Failed to delete temporary build directory "%s"\n'):format(
              out_dir
            ),
            "Warn"
          )
        end
      end

      release_lock()
      if leave_autocmd then
        api.nvim_del_autocmd(leave_autocmd)
      end

      result_cb(ok, err)
    end)
  end

  -- I wish Lua had defer... 😔
  local function finish_on_err(...)
    local ok, rv = pcall(...)
    if not ok then
      finish(false, rv)
    end
    return rv
  end
  --- @param f function
  --- @return function
  --- @nodiscard
  local function finish_on_err_wrap(f)
    return function(...)
      return finish_on_err(f, ...)
    end
  end

  local co
  co = coroutine.wrap(finish_on_err_wrap(function()
    acquire_lock(console, vim.schedule_wrap(co))
    local lock_ok, lock_rv = coroutine.yield()
    if not lock_ok then
      error(lock_rv, 0)
    end
    release_lock = lock_rv

    if not force and not needs_rebuild() then
      console:plugin_print "DOOM executable up-to-date; skipping rebuild\n"
      finish(true)
      return
    end

    leave_autocmd = api.nvim_create_autocmd("VimLeave", {
      group = augroup,
      once = true,
      callback = function()
        finish(false, "Nvim is exiting")
      end,
    })

    local reason = force and "Rebuild requested" or "Executable out-of-date"
    local parallelism = uv.available_parallelism()
    console:plugin_print(
      ("%s; rebuilding DOOM using %d parallel jobs...\n"):format(
        reason,
        parallelism
      )
    )

    local out_dir_err_msg
    out_dir, out_dir_err_msg = uv.fs_mkdtemp(
      fs.joinpath(fs.dirname(fn.tempname()), "actually-doom.nvim.XXXXXX")
    )
    if not out_dir then
      error(
        ("Failed to create temporary build directory: %s"):format(
          out_dir_err_msg
        ),
        0
      )
    end
    console:plugin_print(
      ('Using "%s" as the temporary build directory\n'):format(out_dir),
      "Debug"
    )

    local cc = uv.os_getenv "CC" or "cc"

    local function install()
      if finished then
        return
      end

      local install_dir = fs.dirname(M.exe_install_path)
      console:plugin_print(
        ('Installing DOOM executable to "%s"...\n'):format(M.exe_install_path)
      )

      if fn.mkdir(install_dir, "p") == 0 then
        error(
          ('Failed to create install directory "%s"'):format(install_dir),
          0
        )
      end

      if
        fn.rename(fs.joinpath(out_dir, "actually-doom"), M.exe_install_path)
        ~= 0
      then
        error(
          ('Failed to move built DOOM executable to "%s"'):format(
            M.exe_install_path
          ),
          0
        )
      end

      finish(true)
    end

    --- @param job_name string
    --- @param cmd string[]
    --- @param after_cb fun()
    --- @return vim.SystemObj
    local function spawn_job(job_name, cmd, after_cb)
      local pid
      local ok, rv = pcall(
        vim.system,
        cmd,
        { cwd = out_dir },
        --- @param out vim.SystemCompleted
        finish_on_err_wrap(function(out)
          pid_to_process[pid] = nil
          if finished then
            return
          end

          if assert(out.stderr) ~= "" then
            console:plugin_print(
              ('stderr from job "%s":\n%s'):format(job_name, out.stderr),
              "Warn"
            )
          end

          if out.code ~= 0 then
            error(
              ('Job "%s" exited with code: %d'):format(job_name, out.code),
              0
            )
          end

          after_cb()
        end)
      )
      if not ok then
        error(('Failed to spawn job "%s": %s'):format(job_name, rv), 0)
      end

      pid = rv.pid
      pid_to_process[pid] = rv
      return rv
    end

    local function spawn_link_job()
      if finished then
        return
      end
      console:plugin_print "Linking DOOM executable...\n"

      local cmd = { cc }
      vim.list_extend(cmd, cflags)
      vim.list_extend(cmd, {
        "-lc",
        "-lm",
        "-o",
        "actually-doom",
      })
      vim.list_extend(cmd, object_names)

      spawn_job("link", cmd, vim.schedule_wrap(finish_on_err_wrap(install)))
    end

    local compile_object_i = 1
    local function spawn_next_compile_job()
      if finished then
        return
      end
      if compile_object_i > #object_names then
        if vim.tbl_isempty(pid_to_process) then
          spawn_link_job()
        end
        return
      end

      local object_name = object_names[compile_object_i]
      console:plugin_print(
        ('(%d/%d) Building DOOM object file "%s"...\n'):format(
          compile_object_i,
          #object_names,
          object_name
        )
      )

      local src_name = object_name:gsub(".o$", ".c")
      local src_path = fs.joinpath(src_dir, src_name)
      compile_object_i = compile_object_i + 1

      local cmd = { cc }
      vim.list_extend(cmd, cflags)
      vim.list_extend(cmd, {
        "-c",
        src_path,
        "-o",
        object_name,
      })

      spawn_job(
        ('compile "%s"'):format(object_name),
        cmd,
        spawn_next_compile_job
      )
    end

    for _ = 1, parallelism do
      finish_on_err(spawn_next_compile_job)
    end
  end))

  co()
end

return M
