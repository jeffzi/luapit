local path = require("pl.path")
local pldir = require("pl.dir")

local M = {}

--- Execute a shell command and return whether it succeeded.
--- Compatible with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--- @param cmd string Shell command to execute.
--- @return boolean ok True if command exited with code 0.
local function exec_ok(cmd)
   local r1, r2 = os.execute(cmd)
   -- Lua 5.2+: r1=true/nil, r2="exit"/"signal"
   -- Lua 5.1/LuaJIT: r1=exit_code (0=success), r2=nil
   if r2 ~= nil then
      return r1 == true
   end
   return r1 == 0
end

--- Capture stdout of a shell command, trimmed.
--- @param cmd string Shell command to execute.
--- @return string|nil output Trimmed output, or nil on failure.
local function capture(cmd)
   local h = io.popen(cmd)
   if not h then
      return nil
   end
   local out = h:read("*a")
   h:close()
   return out:match("^(.-)%s*$")
end

--- @class ParsedTarget
--- @field alias string|nil User-provided alias.
--- @field repo string|nil Repository path or URL.
--- @field ref string|nil Git ref (branch, tag, commit).
--- @field bare_dot boolean|nil True when spec is bare ".".
--- @field local_dir string|nil Absolute path to existing local directory.

--- Parse a single target specifier.
--- @param spec string Raw positional argument.
--- @return ParsedTarget|nil parsed Parsed target, or nil on error.
--- @return string|nil err Error message if parsing failed.
function M.parse_target(spec)
   -- Extract alias if present
   local alias, rest = spec:match("^([^=]+)=(.+)$")
   if not alias then
      rest = spec
   end

   -- Bare "." - working tree
   if rest == "." then
      return { alias = alias, bare_dot = true }
   end

   -- Try repo#ref patterns
   local repo, ref

   -- SSH: git@host:path#ref
   repo, ref = rest:match("^(git@[^#]+)#(.+)$")
   if not repo then
      -- HTTPS: https://...#ref
      repo, ref = rest:match("^(https?://[^#]+)#(.+)$")
   end
   if not repo then
      -- Local: .<optional-path>#ref
      repo, ref = rest:match("^(%.[^#]*)#(.+)$")
   end
   if repo then
      return { alias = alias, repo = repo, ref = ref }
   end

   -- Local directory (no #, must be existing dir)
   if path.isdir(rest) then
      return { alias = alias, local_dir = path.abspath(rest) }
   end

   -- Invalid
   return nil,
      string.format(
         "invalid target: %q\n  Expected format: [alias=][repo]#ref or existing directory path\n"
            .. "  Examples: .#main  v1=.#v1.0.0  https://github.com/user/repo#tag  /path/to/dir",
         spec
      )
end

--- Derive display name from parsed target per D-17/D-18/D-19/D-23.
--- @param parsed ParsedTarget Parsed target data.
--- @return string name Display name.
function M.display_name(parsed)
   if parsed.alias ~= nil then
      return parsed.alias
   end
   if parsed.bare_dot then
      return "working-tree"
   end
   if parsed.local_dir ~= nil then
      return path.basename(parsed.local_dir)
   end
   if parsed.ref ~= nil then
      return parsed.ref
   end
   return "unknown"
end

--- Validate parsed targets for duplicate display names.
--- @param parsed_list ParsedTarget[] List of parsed targets.
--- @return boolean|nil ok True if valid, nil on error.
--- @return string|nil err Error message if duplicates found.
function M.validate_targets(parsed_list)
   local seen = {}
   for i = 1, #parsed_list do
      local name = M.display_name(parsed_list[i])
      if seen[name] then
         return nil,
            string.format(
               "duplicate target name %q -- add aliases to disambiguate (e.g. alias1=target1 alias2=target2)",
               name
            )
      end
      seen[name] = true
   end
   return true
end

--- Create a temp directory with a luabench prefix.
--- @param prefix string Prefix for the directory name.
--- @return string|nil dir_path Path to created directory, or nil on error.
--- @return string|nil err Error message on failure.
local function make_temp_dir(prefix)
   local tmp = path.tmpname()
   os.remove(tmp)
   local sanitized = prefix:gsub("[^%w%-_]", "_")
   local dir_path = tmp .. "-luabench-" .. sanitized
   local ok, err = pldir.makepath(dir_path)
   if not ok then
      return nil, err
   end
   return dir_path
end

--- Detect whether a repository URL is remote.
--- @param repo string Repository path or URL.
--- @return boolean is_remote True if URL is remote (HTTPS or SSH).
local function is_remote_url(repo)
   return repo:match("^https?://") ~= nil or repo:match("^git@") ~= nil
end

--- Clone a git repo and check out a ref.
--- @param repo_url string Repository path or URL.
--- @param dest_dir string Destination directory for clone.
--- @param ref string Git ref to check out.
--- @param is_remote boolean Whether the repo is remote.
--- @return boolean|nil ok True on success, nil on error.
--- @return string|nil err Error message on failure.
local function clone_repo(repo_url, dest_dir, ref, is_remote)
   if is_remote then
      -- Try shallow clone with --branch first (works for tags/branches)
      local shallow_cmd =
         string.format("git clone --depth 1 --branch %q %q %q 2>/dev/null", ref, repo_url, dest_dir)
      if exec_ok(shallow_cmd) then
         return true
      end

      -- Fall back to full clone (commit hash or other reason)
      local full_cmd = string.format("git clone %q %q 2>/dev/null", repo_url, dest_dir)
      if not exec_ok(full_cmd) then
         return nil, string.format("failed to clone %q", repo_url)
      end
   else
      -- Local repos: always full clone (per D-13)
      local cmd = string.format("git clone %q %q 2>/dev/null", repo_url, dest_dir)
      if not exec_ok(cmd) then
         return nil, string.format("failed to clone %q", repo_url)
      end
   end

   -- Checkout ref (needed for full clones that didn't use --branch)
   local checkout_cmd = string.format("git -C %q checkout %q 2>/dev/null", dest_dir, ref)
   if not exec_ok(checkout_cmd) then
      return nil, string.format("failed to checkout ref %q in %q", ref, repo_url)
   end

   return true
end

--- Resolve a bare "." spec to git repo root or cwd.
--- @param alias string|nil Optional alias override.
--- @return ResolvedTarget result Resolved target.
local function resolve_bare_dot(alias)
   local resolved_path
   if exec_ok("git rev-parse --show-toplevel 2>/dev/null") then
      resolved_path = capture("git rev-parse --show-toplevel 2>/dev/null")
   else
      resolved_path = path.abspath(".")
   end
   return {
      path = resolved_path,
      name = alias or "working-tree",
      cleanup = false,
   }
end

--- @class ResolvedTarget
--- @field path string Absolute directory path to use for benchmarking.
--- @field name string Display name (alias > ref > basename > working-tree).
--- @field cleanup boolean Whether this target's path needs cleanup (temp dir).

--- Resolve raw target specifiers into benchmark targets.
--- Parse all specs first, validate for duplicates, then resolve each.
--- @param raw_specs string[] Raw positional arguments.
--- @return ResolvedTarget[]|nil targets Resolved targets, or nil on error.
--- @return string|nil err Error message on failure.
function M.resolve_targets(raw_specs)
   -- Parse all specs first (fail fast on any parse error per D-11)
   local parsed_list = {}
   for i = 1, #raw_specs do
      local parsed, err = M.parse_target(raw_specs[i])
      if parsed == nil then
         return nil, err
      end
      parsed_list[#parsed_list + 1] = parsed
   end

   -- Check for duplicate display names (per D-20)
   local ok, err = M.validate_targets(parsed_list)
   if not ok then
      return nil, err
   end

   -- Resolve each target
   local resolved = {}
   local cleanup_on_error = {}

   for i = 1, #parsed_list do
      local p = parsed_list[i]
      local name = M.display_name(p)

      if p.bare_dot then
         resolved[#resolved + 1] = resolve_bare_dot(p.alias)
      elseif p.local_dir ~= nil then
         resolved[#resolved + 1] = {
            path = p.local_dir,
            name = name,
            cleanup = false,
         }
      elseif p.repo ~= nil and p.ref ~= nil then
         -- Git ref: clone into temp dir
         local temp_dir, temp_err = make_temp_dir(p.ref)
         if temp_dir == nil then
            -- Clean up already-created temp dirs
            M.cleanup(cleanup_on_error)
            return nil, "failed to create temp directory: " .. (temp_err or "unknown error")
         end

         local repo_path = p.repo
         if not is_remote_url(repo_path) then
            -- Local repo: resolve to absolute path
            repo_path = path.abspath(repo_path)
         end

         local clone_ok, clone_err = clone_repo(repo_path, temp_dir, p.ref, is_remote_url(p.repo))
         if not clone_ok then
            -- Clean up this temp dir and already-created ones
            cleanup_on_error[#cleanup_on_error + 1] =
               { path = temp_dir, name = name, cleanup = true }
            M.cleanup(cleanup_on_error)
            return nil, clone_err
         end

         local target = { path = temp_dir, name = name, cleanup = true }
         resolved[#resolved + 1] = target
         cleanup_on_error[#cleanup_on_error + 1] = target
      end
   end

   return resolved
end

--- Clean up temp directories created during target resolution.
--- Warns on stderr if removal fails but does not error (per D-16).
--- @param targets ResolvedTarget[] List of resolved targets.
function M.cleanup(targets)
   for i = 1, #targets do
      local t = targets[i]
      if t.cleanup then
         local ok, err = pcall(pldir.rmtree, t.path)
         if not ok then
            io.stderr:write(
               string.format(
                  "luabench: warning: failed to clean up %s: %s\n",
                  t.path,
                  tostring(err)
               )
            )
         end
      end
   end
end

-- Expose internal functions for testing
M._exec_ok = exec_ok
M._capture = capture
M._resolve_bare_dot = resolve_bare_dot
M._clone_repo = clone_repo

return M
