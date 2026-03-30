---@diagnostic disable: need-check-nil

local path = require("pl.path")
local utils = require("pl.utils")

local M = {}

local IS_WINDOWS = path.is_windows

local quote_arg = utils.quote_arg
local readfile = utils.readfile

--- @type boolean
local posix_ok
--- @type table|nil
local unistd
--- @type table|nil
local wait_mod
--- @type table|nil
local posix_mod
--- @type table|nil
local poll_mod

if not IS_WINDOWS then
   posix_ok, unistd = pcall(require, "posix.unistd")
   if posix_ok then
      wait_mod = require("posix.sys.wait")
      posix_mod = require("posix")
      poll_mod = require("posix.poll")
   end
end

--- @param ... string Paths to remove.
local function cleanup(...)
   for i = 1, select("#", ...) do
      pcall(os.remove, select(i, ...))
   end
end

local SIGINT = 2
local SIGINT_EXIT = 128 + SIGINT -- 130: conventional exit code for SIGINT death

--- Raise an "interrupted!" error to propagate SIGINT up the call stack.
local function raise_interrupted()
   error("interrupted!")
end

--- Check a POSIX-style wait result for SIGINT and return success status.
--- Raises "interrupted!" if the child was killed by SIGINT or exited with code 130.
--- @param reason string "killed"/"exited" (posix.sys.wait) or "signal"/"exit" (os.execute 5.2+).
--- @param status number|nil Signal number or exit code (nil-safe for os.execute narrowing).
--- @return boolean ok True if the process exited with status 0.
local function check_exit(reason, status)
   if reason == "killed" or reason == "signal" then
      if status == SIGINT then
         raise_interrupted()
      end
      return false
   end
   if status == SIGINT_EXIT then
      raise_interrupted()
   end
   return status == 0
end

--- Get the parent process ID via luaposix (POSIX only).
--- @return number|nil ppid Parent PID, or nil if luaposix unavailable.
function M._get_ppid()
   if not posix_ok then
      return nil
   end
   return unistd.getppid()
end

--- Raise "interrupted!" if parent process died (we became orphaned).
--- When the parent (e.g. npm/tsx) is killed by SIGINT, the OS reparents us.
--- Detecting ppid change is more reliable than exit codes since programs like
--- npm exit with code 1 (not 130) on SIGINT.
--- @param ppid_before number|nil PID of parent before execution, or nil if luaposix unavailable.
local function check_orphaned(ppid_before)
   if ppid_before == nil then
      return
   end
   local ppid_after = M._get_ppid()
   if ppid_after ~= nil and ppid_after ~= ppid_before then
      raise_interrupted()
   end
end

--- Drain two pipe read-ends concurrently using poll to avoid deadlock.
--- @param fd1 number First file descriptor (e.g. stdout).
--- @param fd2 number Second file descriptor (e.g. stderr).
--- @return string data1 Data read from fd1.
--- @return string data2 Data read from fd2.
local function drain_pipes(fd1, fd2)
   local rpoll = poll_mod.rpoll
   local chunks1, chunks2 = {}, {}
   local open1, open2 = true, true

   while open1 or open2 do
      local progress = false

      if open1 and rpoll(fd1, 0) == 1 then
         local data = unistd.read(fd1, 4096)
         if data == nil or data == "" then
            open1 = false
         else
            chunks1[#chunks1 + 1] = data
         end
         progress = true
      end

      if open2 and rpoll(fd2, 0) == 1 then
         local data = unistd.read(fd2, 4096)
         if data == nil or data == "" then
            open2 = false
         else
            chunks2[#chunks2 + 1] = data
         end
         progress = true
      end

      if not progress and (open1 or open2) then
         local wait_fd = open1 and fd1 or fd2
         rpoll(wait_fd, 10)
      end
   end

   return table.concat(chunks1), table.concat(chunks2)
end

--- Run a shell command capturing stdout and stderr via POSIX pipes (no temp files).
--- @param cmd string Shell command to execute.
--- @return boolean ok True if the command exited with status 0.
--- @return string stdout Captured standard output.
--- @return string stderr Captured standard error.
local function run_posix(cmd)
   local ppid_before = M._get_ppid()

   local stdout_r, stdout_w = unistd.pipe()
   if stdout_r == nil then
      return false, "", "pipe failed"
   end

   local stderr_r, stderr_w = unistd.pipe()
   if stderr_r == nil then
      unistd.close(stdout_r)
      unistd.close(stdout_w)
      return false, "", "pipe failed"
   end

   local pid = unistd.fork()
   if pid == nil or pid == -1 then
      unistd.close(stdout_r)
      unistd.close(stdout_w)
      unistd.close(stderr_r)
      unistd.close(stderr_w)
      return false, "", "fork failed"
   end
   if pid == 0 then
      -- Child: redirect stdout/stderr to pipe write ends
      unistd.close(stdout_r)
      unistd.close(stderr_r)
      unistd.dup2(stdout_w, unistd.STDOUT_FILENO)
      unistd.dup2(stderr_w, unistd.STDERR_FILENO)
      unistd.close(stdout_w)
      unistd.close(stderr_w)
      unistd.exec("/bin/sh", { "-c", cmd })
      unistd._exit(127) -- exec failed
   end

   -- Parent: close write ends before reading to avoid deadlock
   unistd.close(stdout_w)
   unistd.close(stderr_w)

   local stdout_data, stderr_data = drain_pipes(stdout_r, stderr_r)
   unistd.close(stdout_r)
   unistd.close(stderr_r)

   local _, reason, status = wait_mod.wait(pid)
   check_orphaned(ppid_before)
   local ok = check_exit(reason, status)
   return ok, stdout_data, stderr_data
end

--- Run a shell command capturing stdout and stderr via temp files (Windows fallback).
--- Uses cmd /v:on delayed expansion to capture the real exit code.
--- @param cmd string Shell command to execute.
--- @return boolean ok True if the command exited with status 0.
--- @return string stdout Captured standard output.
--- @return string stderr Captured standard error.
local function run_windows(cmd)
   local out_path = os.tmpname()
   local err_path = os.tmpname()
   local rc_path = os.tmpname()

   -- cmd /v:on enables delayed expansion so !errorlevel! evaluates after cmd runs
   local full_cmd = string.format(
      'cmd /v:on /c "%s > %s 2> %s & echo !errorlevel! > %s"',
      cmd,
      quote_arg(out_path),
      quote_arg(err_path),
      quote_arg(rc_path)
   )

   local h = io.popen(full_cmd)
   if h == nil then
      cleanup(out_path, err_path, rc_path)
      return false, "", ""
   end
   h:close()

   local rc_content = readfile(rc_path) or "1"
   local exit_code = tonumber(rc_content:match("(%d+)")) or 1
   local stdout = readfile(out_path) or ""
   local stderr = readfile(err_path) or ""
   cleanup(out_path, err_path, rc_path)

   if exit_code == SIGINT_EXIT then
      raise_interrupted()
   end
   return exit_code == 0, stdout, stderr
end

--- Run a shell command and capture stdout and stderr separately.
--- On POSIX (with luaposix): uses fork/pipe/dup2/exec/wait — no temp files.
--- On Windows (or without luaposix): uses cmd /v:on temp files.
--- @param cmd string Shell command to execute.
--- @return boolean ok True if the command exited with status 0.
--- @return string stdout Captured standard output.
--- @return string stderr Captured standard error.
function M.run(cmd)
   if posix_ok then
      return run_posix(cmd)
   end
   return run_windows(cmd)
end

--- Run a shell command on POSIX using posix.spawn (child inherits terminal).
--- @param cmd string Shell command to execute.
--- @return boolean ok True if the command exited with status 0.
local function stream_posix(cmd)
   local ppid_before = M._get_ppid()
   local status, reason = posix_mod.spawn({ "/bin/sh", "-c", cmd })
   check_orphaned(ppid_before)
   return check_exit(reason, status)
end

--- Run a shell command streaming output to terminal (Windows/fallback).
--- Uses os.execute with Lua 5.1/5.2+ compatible exit code parsing.
--- @param cmd string Shell command to execute.
--- @return boolean ok True if the command exited with status 0.
local function stream_fallback(cmd)
   local ppid_before = M._get_ppid()
   local rc, what, code = os.execute(cmd)

   check_orphaned(ppid_before)

   -- Lua 5.2+: os.execute returns (true/nil, "exit"/"signal", code)
   if what ~= nil then
      return check_exit(what, code)
   end
   -- Lua 5.1/LuaJIT: rc is raw wait status from system()
   if IS_WINDOWS then
      -- On Windows, system() returns the exit code directly.
      if rc == SIGINT_EXIT then
         raise_interrupted()
      end
      return rc == 0
   end
   -- On POSIX, rc encodes signal in low bits, exit code in upper bits.
   if rc % 128 == SIGINT then
      raise_interrupted()
   end
   local exit_code = math.floor(rc / 256)
   if exit_code == SIGINT_EXIT then
      raise_interrupted()
   end
   return exit_code == 0
end

--- Run a shell command, streaming stdout and stderr directly to the terminal.
--- On POSIX (with luaposix): uses posix.spawn for clean exit code handling.
--- On Windows (or without luaposix): uses os.execute with exit code parsing.
--- @param cmd string Shell command to execute.
--- @return boolean ok True if the command exited with status 0.
function M.stream(cmd)
   if posix_ok then
      return stream_posix(cmd)
   end
   return stream_fallback(cmd)
end

return M
