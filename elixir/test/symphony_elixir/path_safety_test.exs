defmodule SymphonyElixir.PathSafetyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PathSafety

  describe "canonicalize/1" do
    test "returns the path unchanged when it does not exist" do
      path = "/tmp/symphony-path-safety-nonexistent-#{System.unique_integer([:positive])}/foo/bar"
      assert {:ok, canonical} = PathSafety.canonicalize(path)
      # The resolved path may differ from `path` due to symlink resolution on the parent dirs
      # (e.g., /tmp -> /private/tmp on macOS), but must end with the same basename.
      assert String.ends_with?(canonical, "/foo/bar")
    end

    test "returns the canonical path for a real directory" do
      dir = System.tmp_dir!()
      assert {:ok, canonical} = PathSafety.canonicalize(dir)
      assert is_binary(canonical)
    end

    test "resolves a symlink to its real target" do
      test_root =
        Path.join(System.tmp_dir!(), "symphony-path-safety-symlink-#{System.unique_integer([:positive])}")

      try do
        real_dir = Path.join(test_root, "real")
        link_path = Path.join(test_root, "link")
        File.mkdir_p!(real_dir)
        File.ln_s!(real_dir, link_path)

        assert {:ok, canonical_real} = PathSafety.canonicalize(real_dir)
        assert {:ok, canonical_link} = PathSafety.canonicalize(link_path)
        assert canonical_link == canonical_real
      after
        File.rm_rf(test_root)
      end
    end

    test "returns error when lstat fails with a non-enoent OS error" do
      test_root =
        Path.join(System.tmp_dir!(), "symphony-path-safety-noperm-#{System.unique_integer([:positive])}")

      try do
        locked_dir = Path.join(test_root, "locked")
        target = Path.join(locked_dir, "secret")
        File.mkdir_p!(locked_dir)
        File.write!(target, "contents")
        File.chmod!(locked_dir, 0o000)

        assert {:error, {:path_canonicalize_failed, _, :eacces}} = PathSafety.canonicalize(target)
      after
        File.chmod!(Path.join(test_root, "locked"), 0o755)
        File.rm_rf(test_root)
      end
    end
  end
end
