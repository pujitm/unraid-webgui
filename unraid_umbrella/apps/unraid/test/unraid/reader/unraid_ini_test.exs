defmodule Unraid.Reader.UnraidIniTest do
  @moduledoc """
  Tests demonstrating expected parsing behavior and result formats.

  AST: `{:ok, [{:global, kvs} | {:section, orig, norm, kvs}]}`
  Normalized: `%{:global | section_name => %{key => string | [string]}}`
  """

  use ExUnit.Case, async: true
  alias Unraid.Reader.UnraidIni, as: Reader

  describe "sections" do
    test "bare section parses" do
      text = """
      [eth0]
      BONDING="yes"
      """

      # Expected AST format: section tuple with original name, normalized name, and kv list
      assert {:ok, [{:section, "eth0", "eth0", [{:kv, "BONDING", nil, "yes"}]}]} =
               Reader.parse(text)
    end

    test "quoted section parses" do
      text = """
      ["disk1"]
      fsType="xfs"
      """

      # Quoted sections: original keeps quotes, normalized strips them
      assert {:ok, [{:section, ~s("disk1"), "disk1", [{:kv, "fsType", nil, "xfs"}]}]} =
               Reader.parse(text)
    end

    test "errors on unclosed section" do
      assert {:error, {1, "Unclosed section header"}} = Reader.parse("[section")
    end

    test "trailing chars after section error" do
      assert {:error, {1, "Trailing characters after section header"}} =
               Reader.parse("[eth0] junk")
    end

    test "periods in section names are treated as regular characters" do
      # Bare section with periods
      text_bare = """
      [disk1.1]
      fsType="xfs"
      """

      assert {:ok, [{:section, "disk1.1", "disk1.1", [{:kv, "fsType", nil, "xfs"}]}]} =
               Reader.parse(text_bare)

      # Quoted section with periods
      text_quoted = """
      ["cache.2"]
      name="nvme_cache"
      """

      assert {:ok, [{:section, ~s("cache.2"), "cache.2", [{:kv, "name", nil, "nvme_cache"}]}]} =
               Reader.parse(text_quoted)
    end
  end

  describe "kv parsing" do
    test "scalar key/value" do
      # Global section with scalar key (index = nil)
      assert {:ok, [{:global, [{:kv, "FOO", nil, "bar"}]}]} = Reader.parse(~s(FOO="bar"))
    end

    test "indexed key/value" do
      # Global section with indexed key (index = 0)
      assert {:ok, [{:global, [{:kv, "IPADDR", 0, "192.168.1.10"}]}]} =
               Reader.parse(~s(IPADDR:0="192.168.1.10"))
    end

    test "spaces around '=' are fine" do
      assert {:ok, [{:global, [{:kv, "X", nil, "y"}]}]} = Reader.parse(~s(X = "y"))
    end

    test "unclosed quoted value error" do
      assert {:error, {1, "Unclosed quoted value"}} = Reader.parse(~s(FOO="bar))
    end

    test "value must be quoted" do
      assert {:error, {1, "Value must be a quoted string"}} = Reader.parse("FOO=bar")
    end

    test "invalid key" do
      assert {:error, {1, "Invalid key"}} = Reader.parse(~s(-BAD="x"))
    end

    test "invalid indexed key" do
      assert {:error, {1, "Invalid indexed key"}} = Reader.parse(~s(FOO:x="y"))
    end

    test "escapes: \", \\, \\n, \\t, \\r" do
      bin = ~s(FOO="a\\\"b\\\\c\\nd\\te\\r")
      assert {:ok, [{:global, [{:kv, "FOO", nil, "a\"b\\c\nd\te\r"}]}]} = Reader.parse(bin)
    end

    test "trailing after quoted value" do
      assert {:error, {1, "Trailing characters after quoted value"}} = Reader.parse(~s(FOO="x"x))
    end
  end

  describe "normalize" do
    test "global only" do
      {:ok, ast} = Reader.parse(~s(NGINX_LANIP="192.168.1.150"))
      norm = Reader.normalize(ast)
      # normalize() creates map with :global key containing scalar values
      assert norm[:global]["NGINX_LANIP"] == "192.168.1.150"
    end

    test "section + scalars" do
      text = """
      [eth0]
      BONDING="yes"
      MTU="1500"
      """

      {:ok, ast} = Reader.parse(text)
      norm = Reader.normalize(ast)
      # normalize() creates map with section name as key, scalar values preserved
      assert norm["eth0"]["BONDING"] == "yes"
      assert norm["eth0"]["MTU"] == "1500"
    end

    test "indexed keys collapse into lists" do
      text = """
      [eth0]
      IPADDR:0="192.168.1.10"
      IPADDR:1="192.168.1.11"
      """

      {:ok, ast} = Reader.parse(text)
      norm = Reader.normalize(ast)
      # normalize() converts indexed keys into ordered lists
      assert norm["eth0"]["IPADDR"] == ["192.168.1.10", "192.168.1.11"]
    end

    test "mix of scalar then indexed promotes scalar" do
      text = """
      [sec]
      NAME="alpha"
      NAME:1="beta"
      NAME:3="delta"
      """

      {:ok, ast} = Reader.parse(text)
      norm = Reader.normalize(ast)

      # normalize() promotes scalar to indexed: scalar "alpha" appended at max_index+1 (position 2)
      # Result ordered by index: [index_1, index_2, index_3] = ["beta", "alpha", "delta"]
      assert norm["sec"]["NAME"] == ["beta", "alpha", "delta"]
    end

    test "duplicate scalar last write wins" do
      text = """
      [x]
      A="one"
      A="two"
      """

      {:ok, ast} = Reader.parse(text)
      norm = Reader.normalize(ast)
      # normalize() handles duplicate scalars: last write wins
      assert norm["x"]["A"] == "two"
    end

    test "periods in section names are normalized correctly" do
      text = """
      [disk1.1]
      fsType="xfs"
      device="/dev/sdc1"

      ["cache.2"]
      name="nvme_cache"
      """

      {:ok, ast} = Reader.parse(text)
      norm = Reader.normalize(ast)
      # normalize() preserves periods in section names as regular characters
      assert norm["disk1.1"]["fsType"] == "xfs"
      assert norm["disk1.1"]["device"] == "/dev/sdc1"
      assert norm["cache.2"]["name"] == "nvme_cache"
    end

    test "comments and blanks are skipped" do
      text = """
      # comment
      ; another
      ["parity"]

      KEY="val"
      """

      {:ok, ast} = Reader.parse(text)
      assert [{:section, ~s("parity"), "parity", [{:kv, "KEY", nil, "val"}]}] = ast
    end
  end

  describe "error reporting" do
    test "unknown garbage line" do
      assert {:error, {1, "Unrecognized line"}} = Reader.parse("^^^")
    end
  end
end
