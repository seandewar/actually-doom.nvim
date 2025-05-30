local api = vim.api
local fn = vim.fn
local fs = vim.fs
local ui = vim.ui
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

--- @enum BuildLockChoice
local lock_choices = {
  WAIT = 1,
  ABORT = 2,
  IGNORE = 3,
  DELETE = 4,
}

--- @type table<BuildLockChoice, string>
local lock_choice_to_label = {
  [lock_choices.WAIT] = "Wait for the lock to release",
  [lock_choices.ABORT] = "Don't build",
  [lock_choices.IGNORE] = "Build anyway without locking",
  [lock_choices.DELETE] = "Delete the lock and retry",
}

--- @param console Console
--- @param result_cb fun(ok: boolean, rv: any)
local function acquire_lock(console, result_cb)
  local lock_path = fs.joinpath(data_dir, ".~actually-doom.nvim.lock")
  local acquired_lock_fd
  local retry_timer --- @type uv.uv_timer_t?

  local function release_lock()
    if acquired_lock_fd then -- Don't delete the lock if we didn't open it...
      -- Don't need to yield for this.
      assert(uv.fs_unlink(lock_path, function(err_msg, ok)
        if not ok then
          console:plugin_print(
            ("Failed to delete build lock: %s\n"):format(err_msg),
            "Warn"
          )
        end
      end))
    end
  end

  -- Using coroutines here to make the logic seem procedural, to guard against
  -- callback hell.
  --
  -- This approach relies on the fact that asynchronous luv calls are guaranteed
  -- to happen after at least one event loop tick (:h luv), so there should be
  -- no case where the callbacks try to resume the coroutine before it yields.
  local co

  --- @param f fun(): fun()?
  --- @return fun(...)
  --- @nodiscard
  local function co_wrap(f)
    return coroutine.wrap(function()
      local ok, rv = pcall(f)

      if retry_timer then
        retry_timer:close()
      end
      if acquired_lock_fd then
        assert(uv.fs_close(acquired_lock_fd, co))
        local close_err_msg, close_ok = coroutine.yield()

        if not close_ok then
          console:plugin_print(
            ("Failed to close file descriptor to build lock: %s\n"):format(
              close_err_msg
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

  --- @return integer? lock_pid
  --- @nodiscard
  --- @async
  local function check_lock_valid()
    assert(uv.fs_open(lock_path, "r", 0, co))
    local open_err_msg, fd = coroutine.yield()
    if open_err_msg and not open_err_msg:find "^ENOENT:" then
      error(
        ("Failed to read existing build lock file: %s"):format(open_err_msg),
        0
      )
    elseif not fd then
      return nil
    end

    -- Feels overkill using luv to just read a PID, but the primary reason for
    -- doing it this way was to ignore ENOENT above and reuse the fd for fstat.
    local data = ""
    local ok, rv = pcall(function()
      -- Before checking the PID, check that the lock was last modified since
      -- the last boot, otherwise the PID may wrongly map to a running, but
      -- unrelated process.
      assert(uv.fs_fstat(fd, co))
      local stat_err_msg, stat = coroutine.yield()
      if stat_err_msg then
        error(
          ("Failed to stat existing build lock file: %s"):format(stat_err_msg),
          0
        )
      end
      local boot_time = assert(select(1, uv.gettimeofday()))
        - assert(uv.uptime())
      if boot_time > stat.mtime.sec then
        return false
      end

      -- libuv pipes to fds are broken and can cause aborts; avoid them.
      -- Don't bother handling partial reads; don't expect to be reading much.
      assert(uv.fs_read(fd, stat.size, nil, co))
      local read_err_msg
      read_err_msg, data = coroutine.yield()
      data = data or ""
      if #data ~= stat.size then
        read_err_msg = ("Partial read (%d/%d bytes)"):format(#data, stat.size)
      end
      if read_err_msg then
        error(
          ("Failed to read existing build lock file: %s"):format(read_err_msg),
          0
        )
      end

      return true
    end)

    -- Don't even bother warning if this fails.
    assert(uv.fs_close(fd, function() end))

    if not ok then
      error(rv, 0)
    elseif not rv then
      return nil
    end

    local lock_pid = tonumber(data)
    if not lock_pid then
      return nil -- Lock contents are nonsense.
    end

    -- Using kill to not send a signal, but to instead check whether the process
    -- is running. If no error, then it definitely is, but if ESRCH, then it
    -- definitely isn't. This is similar to how Vim/Nvim checks swapfiles.
    local pid_status, pid_err_msg, pid_err = uv.kill(lock_pid, 0)
    if not pid_status and pid_err ~= "ESRCH" then
      error(
        ("Couldn't determine if build lock owner PID %d is running: %s"):format(
          lock_pid,
          pid_err_msg
        ),
        0
      )
    end

    return pid_status == 0 and lock_pid or nil
  end

  --- @param prompt string
  --- @param choices BuildLockChoice[]
  --- @return integer choice
  --- @nodiscard
  --- @async
  local function ask_user(prompt, choices)
    -- vim.ui.select may not work within a fast event context.
    vim.schedule(co)
    coroutine.yield()

    ui.select(choices, {
      prompt = prompt,
      format_item = function(choice)
        return lock_choice_to_label[choice]
          .. (choice == choices[1] and " (recommended)" or "")
      end,
    }, vim.schedule_wrap(co))
    local choice, choice_i = coroutine.yield()
    choice_i = choice_i or 1 -- Default to the first choice.

    if choice == lock_choices.WAIT then
      console:plugin_print "Waiting for build lock to release...\n"
    elseif choice == lock_choices.ABORT then
      error("Cancelled acquiring build lock", 0)
    elseif choice == lock_choices.IGNORE then
      console:plugin_print("Building without acquiring a lock!\n", "Warn")
    elseif choice == lock_choices.DELETE then
      console:plugin_print("Deleting existing build lock!\n", "Warn")

      assert(uv.fs_unlink(lock_path, vim.schedule_wrap(co)))
      local unlink_err_msg, unlink_ok = coroutine.yield()
      if not unlink_ok and not unlink_err_msg:find "^ENOENT:" then
        error(
          ("Failed to delete existing build lock: %s"):format(unlink_err_msg),
          0
        )
      end
    else
      error "Unhandled choice"
    end

    return choice
  end

  co = co_wrap(function()
    console:plugin_print(
      ('Acquiring build lock at "%s"...\n'):format(lock_path),
      "Debug"
    )

    -- Don't want many rebuilds to the same directory happening at once!
    -- Attempt to (atomically!) create the lock file, or fail if it exists.
    -- 420 (blaze it) is octal 644, which is -rw-r--r--.
    while true do
      if not api.nvim_buf_is_loaded(console.buf) then
        error("Console buffer was closed", 0)
      end

      assert(uv.fs_open(lock_path, "wx", 420, co))
      local open_err_msg
      open_err_msg, acquired_lock_fd = coroutine.yield()
      if acquired_lock_fd then
        break
      end

      local ask_msg
      local ask_choices
      if open_err_msg:find "^EEXIST:" then
        -- Lock already exists. Check if it's valid, and ask the user what to
        -- do next, as we can't easily take over an existing lock without race
        -- conditions. (At least not with what luv provides)
        -- TODO: use "flock" executable if available?
        local check_ok, check_rv = pcall(check_lock_valid)
        if not check_ok then
          console:plugin_print(
            ("Failed to validate existing build lock: %s\n"):format(check_rv),
            "Warn"
          )

          ask_msg = "DOOM build lock exists, but its status is unknown; "
            .. "a build may be in progress elsewhere! "
          ask_choices =
            { lock_choices.WAIT, lock_choices.ABORT, lock_choices.IGNORE }
        elseif check_rv then
          ask_msg = ("DOOM build still in progress for PID %d! "):format(
            check_rv
          )
          ask_choices =
            { lock_choices.WAIT, lock_choices.ABORT, lock_choices.IGNORE }
        else
          ask_msg = "DOOM build lock exists, but it appears to be stale! "
          ask_choices = { lock_choices.DELETE, lock_choices.ABORT }
        end
      else
        console:plugin_print(
          ("Failed to create build lock: %s\n"):format(open_err_msg),
          "Warn"
        )

        ask_msg = "Failed to acquire DOOM build lock! "
        ask_choices = { lock_choices.ABORT, lock_choices.IGNORE }
      end

      if not retry_timer then
        local ask_choice = ask_user(ask_msg, ask_choices)
        if ask_choice == lock_choices.IGNORE then
          -- Pretend we got the lock, return a no-op release callback.
          return function() end
        elseif ask_choice == lock_choices.WAIT then
          -- Allocate the timer, but retry immediately in case the lock released
          -- while the user was deciding what to do.
          retry_timer = assert(uv.new_timer())
        end
      else
        -- Retry after a bit. Not setting the repeat time on the timer to
        -- schedule the next retry only after we get to this point.
        assert(retry_timer:start(1500, 0, vim.schedule_wrap(co)))
        coroutine.yield()
      end
    end

    --- @cast acquired_lock_fd integer
    -- libuv pipes to fds are broken and can cause aborts; avoid them.
    -- Don't bother handling partial writes; we're not writing much anyway.
    local data = tostring(uv.os_getpid())
    assert(uv.fs_write(acquired_lock_fd, data, nil, co))
    local write_err, written = coroutine.yield()
    if written ~= #data then
      write_err = ("Partial write (%d/%d bytes)"):format(written, #data)
    end
    if write_err then
      error(("Failed to write to build lock: %s"):format(write_err), 0)
    end

    assert(uv.fs_fsync(acquired_lock_fd, co))
    local sync_err, sync_ok = coroutine.yield()
    if not sync_ok then
      -- Lame, but maybe OK as long as all processes are local.
      console:plugin_print(
        ("Failed to sync build lock contents to disk: %s\n"):format(sync_err),
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
  local finish_augroup
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

        local rm_ok, rm_rv = pcall(fs.rm, out_dir, { recursive = true })
        if not rm_ok then
          console:plugin_print(
            ('Failed to delete temporary build directory "%s": %s\n'):format(
              out_dir,
              rm_rv
            ),
            "Warn"
          )
        end
      end

      release_lock()
      if finish_augroup then
        api.nvim_del_augroup_by_id(finish_augroup)
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

    ---@param err any
    ---@return fun()
    ---@nodiscard
    local function finish_autocmd_cb(err)
      return function()
        api.nvim_del_augroup_by_id(finish_augroup)
        finish_augroup = nil
        finish(false, err)
      end
    end
    finish_augroup =
      api.nvim_create_augroup(("actually-doom.build."):format(console.buf), {})

    api.nvim_create_autocmd("VimLeave", {
      group = finish_augroup,
      once = true,
      callback = finish_autocmd_cb "Nvim is exiting",
    })
    api.nvim_create_autocmd("BufUnload", {
      group = finish_augroup,
      once = true,
      buffer = console.buf,
      callback = finish_autocmd_cb "Console buffer was closed",
    })

    local reason = force and "Rebuild requested" or "Executable out-of-date"
    local parallelism = uv.available_parallelism()
    console:plugin_print(
      ("%s; rebuilding DOOM using %d parallel jobs...\n"):format(
        reason,
        parallelism
      )
    )

    local out_dir_template =
      fs.joinpath(fs.dirname(fn.tempname()), "actually-doom.nvim.XXXXXX")
    assert(uv.fs_mkdtemp(out_dir_template, co))
    local out_dir_err_msg
    out_dir_err_msg, out_dir = coroutine.yield(co)

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
        ('(%d/%d) Building DOOM object "%s"...\n'):format(
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
