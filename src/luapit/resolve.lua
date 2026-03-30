local exec = require("luapit.exec")
local path = require("pl.path")
local pldir = require("pl.dir")
local stringx = require("pl.stringx")
local utils = require("pl.utils")

local M = {}

local quote_arg = utils.quote_arg

--- @param cmd string Shell command to execute.
--- @return boolean ok True if command exited with code 0.
local function exec_ok(cmd)
   return (exec.run(cmd))
end

--- Capture stdout of a shell command, trimmed.
--- @param cmd string Shell command to execute.
--- @return string|nil output Trimmed output, or nil on failure.
local function capture(cmd)
   local ok, stdout = exec.run(cmd)
   if not ok or stdout == nil then
      return nil
   end
   return stringx.strip(stdout)
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
   local alias, rest = spec:match("^([^=]+)=(.+)$")
   if alias == nil then
      rest = spec
   end

   if rest == "." then
      return { alias = alias, bare_dot = true }
   end

   local repo, ref

   -- SSH: git@host:path#ref
   repo, ref = rest:match("^(git@[^#]+)#(.+)$")
   if repo == nil then
      -- HTTPS: https://...#ref
      repo, ref = rest:match("^(https?://[^#]+)#(.+)$")
   end
   if repo == nil then
      -- Local: .<optional-path>#ref
      repo, ref = rest:match("^(%.[^#]*)#(.+)$")
   end
   if repo ~= nil then
      return { alias = alias, repo = repo, ref = ref }
   end

   if path.isdir(rest) then
      return { alias = alias, local_dir = path.abspath(rest) }
   end

   local hash_ref = rest:match("^#(.+)$")
   if hash_ref ~= nil then
      return nil,
         string.format(
            "invalid target: %q\n  Detected ref %q without a repo -- did you mean '.#%s'?",
            spec,
            hash_ref,
            hash_ref
         )
   end

   return nil,
      string.format(
         "invalid target: %q\n  Expected format: [alias=][repo]#ref or existing directory path\n"
            .. "  Examples: .#main  v1=.#v1.0.0  https://github.com/user/repo#tag  /path/to/dir",
         spec
      )
end

--- Derive display name from parsed target.
--- @param parsed ParsedTarget Parsed target data.
--- @return string name Display name.
function M.display_name(parsed)
   if parsed.alias ~= nil then
      return parsed.alias
   end
   if parsed.bare_dot ~= nil then
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
--- @param raw_specs string[] Original raw spec strings (for error messages).
--- @return boolean|nil ok True if valid, nil on error.
--- @return string|nil err Error message if duplicates found.
function M.validate_targets(parsed_list, raw_specs)
   local seen = {} --- @type table<string, string>
   for i = 1, #parsed_list do
      local name = M.display_name(parsed_list[i])
      if seen[name] ~= nil then
         return nil,
            string.format(
               "duplicate target name %q (from %q and %q)"
                  .. " -- add aliases to disambiguate (e.g. a=%s b=%s)",
               name,
               seen[name],
               raw_specs[i],
               seen[name],
               raw_specs[i]
            )
      end
      seen[name] = raw_specs[i]
   end
   return true
end

--- Create a temp directory with a luapit prefix.
--- @param prefix string Prefix for the directory name.
--- @return string|nil dir_path Path to created directory, or nil on error.
--- @return string|nil err Error message on failure.
local function make_temp_dir(prefix)
   local tmp = path.tmpname()
   os.remove(tmp)
   local sanitized = prefix:gsub("[^%w%-_]", "_")
   local dir_path = tmp .. "-luapit-" .. sanitized
   local ok, err = pldir.makepath(dir_path)
   if ok == nil then
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
      local shallow_cmd = table.concat({
         "git clone --depth 1 --branch",
         quote_arg(ref),
         quote_arg(repo_url),
         quote_arg(dest_dir),
         "2>/dev/null",
      }, " ")
      if exec_ok(shallow_cmd) then
         return true
      end
   end

   -- Full clone: remote fallback (commit hash) or local repos
   local clone_cmd = table.concat({
      "git clone",
      quote_arg(repo_url),
      quote_arg(dest_dir),
      "2>/dev/null",
   }, " ")
   if not exec_ok(clone_cmd) then
      return nil, string.format("failed to clone %q", repo_url)
   end

   -- Checkout ref (needed for full clones that didn't use --branch)
   local checkout_cmd = table.concat({
      "git -C",
      quote_arg(dest_dir),
      "checkout",
      quote_arg(ref),
      "2>/dev/null",
   }, " ")
   if not exec_ok(checkout_cmd) then
      return nil, string.format("failed to checkout ref %q in %q", ref, repo_url)
   end

   return true
end

--- Resolve a bare "." spec to git repo root or cwd.
--- @param alias string|nil Optional alias override.
--- @return ResolvedTarget result Resolved target.
local function resolve_bare_dot(alias)
   local git_root = capture("git rev-parse --show-toplevel 2>/dev/null")
   local resolved_path
   if git_root ~= nil and git_root ~= "" then
      resolved_path = git_root
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
--- @field original_spec string Raw spec string from the input array.

--- Resolve raw target specifiers into benchmark targets.
--- Parse all specs first, validate for duplicates, then resolve each.
--- @param raw_specs string[] Raw positional arguments.
--- @return ResolvedTarget[]|nil targets Resolved targets, or nil on error.
--- @return string|nil err Error message on failure.
function M.resolve_targets(raw_specs)
   local parsed_list = {}
   for i = 1, #raw_specs do
      local parsed, err = M.parse_target(raw_specs[i])
      if parsed == nil then
         return nil, err
      end
      parsed_list[#parsed_list + 1] = parsed
   end

   local ok, err = M.validate_targets(parsed_list, raw_specs)
   if ok == nil then
      return nil, err
   end

   local resolved = {}
   local cleanup_on_error = {}

   for i = 1, #parsed_list do
      local p = parsed_list[i]
      local name = M.display_name(p)

      if p.bare_dot ~= nil then
         local target = resolve_bare_dot(p.alias)
         target.original_spec = raw_specs[i]
         resolved[#resolved + 1] = target
      elseif p.local_dir ~= nil then
         resolved[#resolved + 1] = {
            path = p.local_dir,
            name = name,
            cleanup = false,
            original_spec = raw_specs[i],
         }
      elseif p.repo ~= nil and p.ref ~= nil then
         local temp_dir, temp_err = make_temp_dir(p.ref)
         if temp_dir == nil then
            M.cleanup(cleanup_on_error)
            return nil, "failed to create temp directory: " .. (temp_err or "unknown error")
         end

         local is_remote = is_remote_url(p.repo)
         local repo_path = is_remote and p.repo or path.abspath(p.repo)

         local clone_ok, clone_err = clone_repo(repo_path, temp_dir, p.ref, is_remote)
         if clone_ok == nil then
            cleanup_on_error[#cleanup_on_error + 1] =
               { path = temp_dir, name = name, cleanup = true }
            M.cleanup(cleanup_on_error)
            return nil, clone_err
         end

         local target =
            { path = temp_dir, name = name, cleanup = true, original_spec = raw_specs[i] }
         resolved[#resolved + 1] = target
         cleanup_on_error[#cleanup_on_error + 1] = target
      end
   end

   return resolved
end

--- Clean up temp directories created during target resolution.
--- Warns on stderr if removal fails but does not error.
--- @param targets ResolvedTarget[] List of resolved targets.
function M.cleanup(targets)
   for i = 1, #targets do
      local t = targets[i]
      if t.cleanup then
         local ok, err = pcall(pldir.rmtree, t.path)
         if not ok then
            io.stderr:write(
               string.format("luapit: warning: failed to clean up %s: %s\n", t.path, tostring(err))
            )
         end
      end
   end
end

--- Run a preparation command for each cloned target.
--- Targets with cleanup=false pass through unchanged. For cleanup=true targets,
--- run cmd in the target directory; on failure, warn on stderr and remove.
--- @param targets ResolvedTarget[] Resolved targets to prepare.
--- @param cmd string Shell command to run in each cloned target's directory.
--- @return ResolvedTarget[] prepared Targets that succeeded (or were non-cloned).
function M.prepare_targets(targets, cmd)
   local result = {}
   for i = 1, #targets do
      local t = targets[i]
      if not t.cleanup then
         result[#result + 1] = t
      else
         local full_cmd = table.concat({ "cd", quote_arg(t.path), "&&", cmd }, " ")
         local ok = exec.stream(full_cmd)
         if ok then
            result[#result + 1] = t
         else
            io.stderr:write(
               string.format("luapit: warning: prepare command failed for %s, skipping\n", t.name)
            )
            M.cleanup({ t })
         end
      end
   end
   return result
end

return M
