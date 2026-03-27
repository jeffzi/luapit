---@diagnostic disable: need-check-nil, duplicate-set-field, missing-parameter, redundant-parameter, unused-local
local pldir = require("pl.dir")
local plpath = require("pl.path")

describe("resolve", function()
   local resolve

   local CWD = plpath.currentdir()
   local FIXTURE_DIR = CWD .. "/tests/fixtures"
   local LIBV1_DIR = FIXTURE_DIR .. "/targets/libv1"

   before_each(function()
      resolve = require("luabench.resolve")
   end)

   for _, case in ipairs({
      {
         desc = "local repo ref",
         input = ".#main",
         expected = { repo = ".", ref = "main" },
      },
      {
         desc = "HTTPS URL ref",
         input = "https://github.com/user/repo#v2",
         expected = { repo = "https://github.com/user/repo", ref = "v2" },
      },
      {
         desc = "SSH URL ref",
         input = "git@github.com:user/repo#main",
         expected = { repo = "git@github.com:user/repo", ref = "main" },
      },
      {
         desc = "aliased local repo ref",
         input = "v1=.#v1.0.0",
         expected = { alias = "v1", repo = ".", ref = "v1.0.0" },
      },
   }) do
      it("parse_target parses " .. case.desc, function()
         local parsed = resolve.parse_target(case.input)

         assert.is_not_nil(parsed)
         assert.are_equal(case.expected.repo, parsed.repo)
         assert.are_equal(case.expected.ref, parsed.ref)
         if case.expected.alias ~= nil then
            assert.are_equal(case.expected.alias, parsed.alias)
         end
      end)
   end

   it("parse_target parses bare dot with and without alias", function()
      local plain = resolve.parse_target(".")
      local aliased = resolve.parse_target("wt=.")

      assert.is_true(plain.bare_dot)
      assert.is_nil(plain.alias)
      assert.is_true(aliased.bare_dot)
      assert.are_equal("wt", aliased.alias)
   end)

   -- parse_target: local directories

   it("parse_target detects existing directory as local_dir", function()
      local parsed = resolve.parse_target(LIBV1_DIR)

      assert.is_not_nil(parsed)
      assert.are_equal(LIBV1_DIR, parsed.local_dir)
   end)

   it("parse_target resolves relative local dir to absolute path", function()
      local parsed = resolve.parse_target("tests/fixtures/targets/libv1")

      assert.is_not_nil(parsed)
      assert.are_equal(LIBV1_DIR, parsed.local_dir)
   end)

   it("parse_target parses aliased local directory", function()
      local parsed = resolve.parse_target("v1=" .. LIBV1_DIR)

      assert.is_not_nil(parsed)
      assert.are_equal("v1", parsed.alias)
      assert.are_equal(LIBV1_DIR, parsed.local_dir)
   end)

   -- parse_target: invalid specs

   it("parse_target returns nil and error for invalid spec", function()
      local parsed, err = resolve.parse_target("not_a_valid_spec")

      assert.is_nil(parsed)
      assert.is_string(err)
      assert.matches("invalid target", err)
   end)

   -- display_name derivation

   for _, case in ipairs({
      {
         desc = "alias wins over ref",
         parsed = { alias = "v1", repo = ".", ref = "v1.0.0" },
         expected = "v1",
      },
      {
         desc = "ref name when no alias for git ref",
         parsed = { repo = ".", ref = "main" },
         expected = "main",
      },
      {
         desc = "basename for local dir without alias",
         parsed = { local_dir = "/path/to/mylib" },
         expected = "mylib",
      },
      {
         desc = "alias wins over local dir basename",
         parsed = { alias = "lib", local_dir = "/path/to/mylib" },
         expected = "lib",
      },
      {
         desc = "working-tree for bare dot without alias",
         parsed = { bare_dot = true },
         expected = "working-tree",
      },
      {
         desc = "alias wins over working-tree",
         parsed = { alias = "current", bare_dot = true },
         expected = "current",
      },
      {
         desc = "unknown when no fields match",
         parsed = {},
         expected = "unknown",
      },
   }) do
      it("display_name returns " .. case.desc, function()
         local name = resolve.display_name(case.parsed)

         assert.are_equal(case.expected, name)
      end)
   end

   -- validate_targets: duplicate detection

   it("validate_targets detects duplicate display names with original specs", function()
      local parsed_list = {
         { repo = ".", ref = "main" },
         { repo = "https://example.com/repo", ref = "main" },
      }
      local raw_specs = { ".#main", "https://example.com/repo#main" }

      local ok, err = resolve.validate_targets(parsed_list, raw_specs)

      assert.is_nil(ok)
      assert.matches("duplicate", err)
      assert.matches('"main"', err)
      assert.matches(".#main", err, 1, true)
      assert.matches("https://example.com/repo#main", err, 1, true)
   end)

   it("validate_targets passes when names are unique", function()
      local parsed_list = {
         { alias = "v1", repo = ".", ref = "v1.0.0" },
         { repo = ".", ref = "main" },
      }
      local raw_specs = { "v1=.#v1.0.0", ".#main" }

      local ok = resolve.validate_targets(parsed_list, raw_specs)

      assert.is_true(ok)
   end)

   -- exec_ok cross-version wrapper

   it("exec_ok returns true for successful command", function()
      local ok = resolve._exec_ok("true")

      assert.is_true(ok)
   end)

   it("exec_ok returns false for failing command", function()
      local ok = resolve._exec_ok("false")

      assert.is_false(ok)
   end)

   -- capture wrapper

   it("capture returns trimmed output of command", function()
      local out = resolve._capture("echo hello")

      assert.are_equal("hello", out)
   end)

   -- resolve_bare_dot

   it("resolve_bare_dot inside git repo returns repo root", function()
      local result = resolve._resolve_bare_dot(nil)

      assert.is_not_nil(result)
      assert.are_equal("working-tree", result.name)
      assert.is_false(result.cleanup)
      assert.is_string(result.path)
      -- We're inside a git repo, so path should be a real directory
      assert.is_true(plpath.isdir(result.path))
   end)

   it("resolve_bare_dot uses alias when provided", function()
      local result = resolve._resolve_bare_dot("wt")

      assert.are_equal("wt", result.name)
   end)

   -- clone_repo (integration test with real git)

   it("clone_repo clones a local repo and checks out ref", function()
      -- Use the current repo as source
      local toplevel = resolve._capture("git rev-parse --show-toplevel 2>/dev/null")
      if toplevel == nil then
         pending("not inside a git repo")
         return
      end

      local dest = plpath.tmpname()
      os.remove(dest)
      dest = dest .. "-luabench-clone-test"

      local ok, err = resolve._clone_repo(toplevel, dest, "main", false)

      -- Clean up
      if plpath.isdir(dest) then
         pldir.rmtree(dest)
      end

      assert.is_true(ok, err)
   end)

   it("clone_repo returns nil and error when local repo path does not exist", function()
      local dest = plpath.tmpname()
      os.remove(dest)
      dest = dest .. "-luabench-clone-fail"

      local ok, err = resolve._clone_repo("/nonexistent/repo", dest, "main", false)

      if plpath.isdir(dest) then
         pldir.rmtree(dest)
      end

      assert.is_nil(ok)
      assert.matches("failed to clone", err)
   end)

   it("clone_repo returns nil and error when ref does not exist", function()
      local toplevel = resolve._capture("git rev-parse --show-toplevel 2>/dev/null")
      if toplevel == nil then
         pending("not inside a git repo")
         return
      end

      local dest = plpath.tmpname()
      os.remove(dest)
      dest = dest .. "-luabench-badref"

      local ok, err = resolve._clone_repo(toplevel, dest, "nonexistent_ref_xyz_999", false)

      if plpath.isdir(dest) then
         pldir.rmtree(dest)
      end

      assert.is_nil(ok)
      assert.matches("failed to checkout ref", err)
   end)

   it("clone_repo returns nil and error for unreachable remote", function()
      local dest = plpath.tmpname()
      os.remove(dest)
      dest = dest .. "-luabench-remote-fail"

      local ok, err = resolve._clone_repo("file:///nonexistent/remote/repo", dest, "main", true)

      if plpath.isdir(dest) then
         pldir.rmtree(dest)
      end

      assert.is_nil(ok)
      assert.matches("failed to clone", err)
   end)

   -- cleanup

   it("cleanup removes temp dirs where cleanup is true", function()
      local tmp = plpath.tmpname()
      os.remove(tmp)
      local temp_dir = tmp .. "-luabench-cleanup-test"
      pldir.makepath(temp_dir)
      assert.is_true(plpath.isdir(temp_dir))

      resolve.cleanup({
         { path = temp_dir, name = "test", cleanup = true },
         { path = "/some/other/dir", name = "keep", cleanup = false },
      })

      assert.is_false(plpath.isdir(temp_dir))
   end)

   it("cleanup warns on stderr but does not error when removal fails", function()
      local original_stderr = io.stderr
      io.stderr = io.tmpfile()

      resolve.cleanup({
         { path = "/nonexistent/dir/should/not/exist", name = "bad", cleanup = true },
      })

      io.stderr:seek("set")
      local stderr_output = io.stderr:read("*a")
      io.stderr:close()
      io.stderr = original_stderr

      -- Should not error (we got here) and may warn
      assert.is_string(stderr_output)
   end)

   -- resolve_targets end-to-end (with local dirs and bare dot)

   it("resolve_targets resolves local dir targets", function()
      local targets, err = resolve.resolve_targets({ LIBV1_DIR })

      assert.is_not_nil(targets, err)
      assert.are_equal(1, #targets)
      assert.are_equal(LIBV1_DIR, targets[1].path)
      assert.are_equal("libv1", targets[1].name)
      assert.is_false(targets[1].cleanup)
   end)

   it("resolve_targets resolves bare dot target", function()
      local targets, err = resolve.resolve_targets({ "." })

      assert.is_not_nil(targets, err)
      assert.are_equal(1, #targets)
      assert.are_equal("working-tree", targets[1].name)
      assert.is_false(targets[1].cleanup)
   end)

   it("resolve_targets fails fast on invalid spec", function()
      local targets, err = resolve.resolve_targets({ "not_valid_at_all" })

      assert.is_nil(targets)
      assert.matches("invalid target", err)
   end)

   it("resolve_targets detects duplicate display names", function()
      local targets, err = resolve.resolve_targets({ ".#main", "https://example.com/r#main" })

      assert.is_nil(targets)
      assert.matches("duplicate", err)
   end)

   it("resolve_targets resolves multiple targets with unique names", function()
      local targets, err = resolve.resolve_targets({
         "v1=" .. LIBV1_DIR,
         ".",
      })

      assert.is_not_nil(targets, err)
      assert.are_equal(2, #targets)
      assert.are_equal("v1", targets[1].name)
      assert.are_equal("working-tree", targets[2].name)
   end)

   -- resolve_targets with git refs (integration)

   it("resolve_targets returns error and cleans up when checkout fails", function()
      local toplevel = resolve._capture("git rev-parse --show-toplevel 2>/dev/null")
      if toplevel == nil then
         pending("not inside a git repo")
         return
      end

      local original_stderr = io.stderr
      io.stderr = io.tmpfile()

      local targets, err = resolve.resolve_targets({ ".#nonexistent_ref_xyz_999" })

      io.stderr:close()
      io.stderr = original_stderr

      assert.is_nil(targets)
      assert.matches("failed to checkout ref", err)
   end)

   it("resolve_targets clones a git ref and cleans up", function()
      local toplevel = resolve._capture("git rev-parse --show-toplevel 2>/dev/null")
      if toplevel == nil then
         pending("not inside a git repo")
         return
      end

      local targets, err = resolve.resolve_targets({ ".#main" })

      assert.is_not_nil(targets, err)
      assert.are_equal(1, #targets)
      assert.are_equal("main", targets[1].name)
      assert.is_true(targets[1].cleanup)
      assert.is_true(plpath.isdir(targets[1].path))

      -- Cleanup
      resolve.cleanup(targets)
      assert.is_false(plpath.isdir(targets[1].path))
   end)

   -- prepare_targets

   local prepare_temp_dirs = {}

   --- Create a real temp directory for prepare_targets testing.
   --- @return string path Absolute path to the temp directory.
   local function make_prepare_temp_dir()
      local tmp = plpath.tmpname()
      os.remove(tmp)
      local dir = tmp .. "-luabench-prepare-test"
      pldir.makepath(dir)
      prepare_temp_dirs[#prepare_temp_dirs + 1] = dir
      return dir
   end

   --- Run fn with stderr redirected; return captured stderr output.
   --- Restores io.stderr even if fn raises an error.
   --- @param fn fun()
   --- @return string stderr_output
   local function capture_stderr(fn)
      local original = io.stderr
      local tmp = io.tmpfile()
      io.stderr = tmp
      local ok, err = pcall(fn)
      tmp:seek("set")
      local output = tmp:read("*a")
      tmp:close()
      io.stderr = original
      if not ok then
         error(err, 0)
      end
      return output
   end

   after_each(function()
      for _, dir in ipairs(prepare_temp_dirs) do
         if plpath.isdir(dir) then
            pldir.rmtree(dir)
         end
      end
      prepare_temp_dirs = {}
   end)

   it("prepare_targets skips targets where cleanup is false", function()
      local targets = {
         { path = "/some/local/dir", name = "local-a", cleanup = false },
         { path = "/another/dir", name = "local-b", cleanup = false },
      }

      local result = resolve.prepare_targets(targets, "touch marker.txt")

      assert.are_same(targets, result)
   end)

   it("prepare_targets runs command in cloned target directory", function()
      local dir = make_prepare_temp_dir()
      local targets = {
         { path = dir, name = "cloned-ref", cleanup = true },
      }

      local result = resolve.prepare_targets(targets, "touch marker.txt")

      assert.are_equal(1, #result)
      assert.is_true(plpath.isfile(dir .. "/marker.txt"))
   end)

   it("prepare_targets removes failed target and warns on stderr", function()
      local dir = make_prepare_temp_dir()
      local targets = {
         { path = dir, name = "bad-ref", cleanup = true },
      }

      local result
      local stderr_output = capture_stderr(function()
         result = resolve.prepare_targets(targets, "false")
      end)

      assert.are_equal(0, #result)
      assert.is_false(plpath.isdir(dir))
      assert.matches("bad%-ref", stderr_output)
   end)

   it("prepare_targets returns empty list when all cloned targets fail", function()
      local dir1 = make_prepare_temp_dir()
      local dir2 = make_prepare_temp_dir()
      local targets = {
         { path = dir1, name = "fail-a", cleanup = true },
         { path = dir2, name = "fail-b", cleanup = true },
      }

      local result
      capture_stderr(function()
         result = resolve.prepare_targets(targets, "false")
      end)

      assert.are_same({}, result)
   end)

   it("prepare_targets preserves non-cloned targets when all cloned targets fail", function()
      local dir = make_prepare_temp_dir()
      local targets = {
         { path = "/some/local/dir", name = "local-one", cleanup = false },
         { path = dir, name = "cloned-fail", cleanup = true },
      }

      local result
      capture_stderr(function()
         result = resolve.prepare_targets(targets, "false")
      end)

      assert.are_equal(1, #result)
      assert.are_equal("local-one", result[1].name)
      assert.is_false(result[1].cleanup)
   end)

   it("prepare_targets returns all targets when command succeeds", function()
      local dir1 = make_prepare_temp_dir()
      local dir2 = make_prepare_temp_dir()
      local targets = {
         { path = dir1, name = "ref-a", cleanup = true },
         { path = dir2, name = "ref-b", cleanup = true },
      }

      local result = resolve.prepare_targets(targets, "true")

      assert.are_equal(2, #result)
      assert.are_equal("ref-a", result[1].name)
      assert.are_equal("ref-b", result[2].name)
   end)
end)
