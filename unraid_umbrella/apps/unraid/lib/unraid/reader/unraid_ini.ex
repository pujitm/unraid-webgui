defmodule Unraid.Reader.UnraidIni do
  @moduledoc """
  Read-only parser for Unraid's slightly non-standard INI/CFG files.

  ## Public API

  * `parse/1` - Parse text into AST with error handling
  * `normalize/1` - Convert AST to normalized map
  * `parse_and_normalize/1` - Parse and normalize with error handling
  * `parse_and_normalize!/1` - Parse and normalize (raises on error)

  ## Supported Features

    * Quoted or bare sections: [eth0] or ["disk1"]
    * Files with only global keys (no sections) → :global
    * Indexed keys like NAME:0, NAME:1 → become lists in normalize/1
    * Values are quoted strings; minimal unescaping: \", \\, \n, \t, \r

  ## Non-goals

    * Writing/pretty-printing (codec is read-only by design)
    * Inline/trailing comment preservation (blank/comment lines are skipped)
  """

  @type kv :: {:kv, key :: String.t(), idx :: non_neg_integer() | nil, val :: String.t()}
  @type section :: {:section, original :: String.t(), normalized :: String.t(), [kv]}
  @type global :: {:global, [kv]}
  @type ast_node :: section | global
  @type ast :: [ast_node]

  @doc """
  Parse full text into an AST. Returns {:ok, ast} or {:error, {line, reason}}.

  ## AST Format

  Returns `{:ok, ast}` where `ast` is a list of:
  - `{:global, [kv]}` - Key-value pairs before any section
  - `{:section, original_name, normalized_name, [kv]}` - Section contents

  Each `kv` is `{:kv, key, index_or_nil, value}` where all values are strings.

  ## Examples

  ```
  FOO="bar"           → [{:global, [{:kv, "FOO", nil, "bar"}]}]
  [eth0]              → [{:section, "eth0", "eth0", [...]}]
  ["disk1"]           → [{:section, "\"disk1\"", "disk1", [...]}]
  KEY:0="val"         → {:kv, "KEY", 0, "val"}
  ```
  """
  @spec parse(String.t()) :: {:ok, ast} | {:error, {non_neg_integer(), String.t()}}
  def parse(text) when is_binary(text) do
    lines = String.split(text, ~r/\r?\n/, trim: false)

    {result, last_line} =
      Enum.reduce_while(Enum.with_index(lines, 1), {{[], {:global, []}}, 0}, fn {line, n},
                                                                                {{acc, cur}, _} ->
        line = strip_cr(line)

        case classify_line(line) do
          :skip ->
            {:cont, {{acc, cur}, n}}

          {:section, original, normalized} ->
            acc = push_section(acc, cur)
            {:cont, {{acc, {:section, original, normalized, []}}, n}}

          {:kv, key, idx, val} ->
            cur2 =
              case cur do
                {:global, kvs} -> {:global, [{:kv, key, idx, val} | kvs]}
                {:section, o, norm, kvs} -> {:section, o, norm, [{:kv, key, idx, val} | kvs]}
              end

            {:cont, {{acc, cur2}, n}}

          {:error, reason} ->
            {:halt, {{:error, {n, reason}}, n}}
        end
      end)

    case result do
      {:error, _} = err ->
        err

      {acc, cur} ->
        ast = acc |> push_section(cur) |> Enum.reverse() |> Enum.map(&reverse_kvs/1)
        {:ok, ast}

      other ->
        # defensive
        {:error, {last_line, "Internal parser state error: #{inspect(other)}"}}
    end
  end

  @doc """
  Convert AST to a normalized map:

      %{
        :global => %{"NGINX_LANIP" => "192.168.1.150"},
        "eth0"  => %{"BONDING" => "yes", "IPADDR" => ["192.168.1.150"]},
        "disk1" => %{"fsType" => "xfs", ...}
      }

  Rules:
    * NAME:0, NAME:1 ... → NAME => list ordered by index
    * Unindexed keys stay as scalar strings
    * If both scalar and indexed appear for same key, the indexed list wins; the scalar is appended at max_index+1
    * Duplicate scalars: last write wins
  """
  @spec normalize(ast) :: map()
  def normalize(ast) do
    Enum.reduce(ast, %{}, fn
      {:global, kvs}, acc -> Map.put(acc, :global, kvs_to_map(kvs))
      {:section, _orig, name, kvs}, acc -> Map.put(acc, name, kvs_to_map(kvs))
    end)
  end

  @doc """
  Parse text and return normalized map, with error handling.
  """
  @spec parse_and_normalize(String.t()) ::
          {:ok, map()} | {:error, {non_neg_integer(), String.t()}}
  def parse_and_normalize(text) do
    case parse(text) do
      {:ok, ast} -> {:ok, normalize(ast)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Parse text and return normalized map (raises on error).
  """
  @spec parse_and_normalize!(String.t()) :: map()
  def parse_and_normalize!(text) do
    {:ok, ast} = parse(text)
    normalize(ast)
  end

  # ------------ internals ------------

  # Skip empty and comment lines. Only whole-line comments are supported (leading ';' or '#').
  defp classify_line(""), do: :skip
  defp classify_line(<<c, _::binary>>) when c in [?#, ?;], do: :skip

  # Section line: ["name"] or [bare]
  defp classify_line(<<"[\"", rest::binary>>) do
    case :binary.match(rest, "\"]") do
      {pos, 2} ->
        # rest = name <> "\"]" <> after
        <<name::binary-size(pos), "\"]", tail::binary>> = rest

        if String.trim(tail) == "" do
          {:section, ~s("#{name}"), name}
        else
          {:error, "Trailing characters after section header"}
        end

      :nomatch ->
        {:error, "Unclosed quoted section header"}
    end
  end

  defp classify_line(<<"[", rest::binary>>) do
    case :binary.match(rest, "]") do
      {pos, 1} ->
        <<name::binary-size(pos), "]", tail::binary>> = rest
        name = String.trim(name)

        cond do
          name == "" -> {:error, "Empty section name"}
          String.contains?(name, ~s(")) -> {:error, "Bare section must not contain quotes"}
          String.trim(tail) != "" -> {:error, "Trailing characters after section header"}
          true -> {:section, name, name}
        end

      :nomatch ->
        {:error, "Unclosed section header"}
    end
  end

  # KV line: KEY[:index]="value" with optional spaces around '='
  defp classify_line(line) do
    case split_once_trim(line, "=") do
      :nomatch ->
        {:error, "Unrecognized line"}

      {lhs, rhs} ->
        with {:ok, key, idx} <- parse_lhs(lhs),
             {:ok, val} <- parse_quoted_value(rhs) do
          {:kv, key, idx, val}
        else
          {:error, _} = e -> e
        end
    end
  end

  # LHS: KEY or KEY:idx ; KEY = [A-Za-z0-9_]+ ; idx = integer
  defp parse_lhs(lhs) do
    lhs = trim_space(lhs)

    case :binary.split(lhs, ":", [:global]) do
      [key] ->
        with true <- valid_key?(key) do
          {:ok, key, nil}
        else
          _ -> {:error, "Invalid key"}
        end

      [key, idxbin] ->
        with true <- valid_key?(key),
             {idx, ""} <- Integer.parse(idxbin) do
          {:ok, key, idx}
        else
          _ -> {:error, "Invalid indexed key"}
        end

      _ ->
        {:error, "Invalid key syntax"}
    end
  end

  # RHS: a quoted string with minimal escapes
  defp parse_quoted_value(rhs) do
    rhs = trim_space(rhs)

    case rhs do
      <<"\"", rest::binary>> ->
        parse_quoted_chars(rest, [])

      _ ->
        {:error, "Value must be a quoted string"}
    end
  end

  # Parse until the closing unescaped quote
  defp parse_quoted_chars(<<"\\", ?n, tail::binary>>, acc),
    do: parse_quoted_chars(tail, [?\n | acc])

  defp parse_quoted_chars(<<"\\", ?t, tail::binary>>, acc),
    do: parse_quoted_chars(tail, [?\t | acc])

  defp parse_quoted_chars(<<"\\", ?r, tail::binary>>, acc),
    do: parse_quoted_chars(tail, [?\r | acc])

  defp parse_quoted_chars(<<"\\", ?", tail::binary>>, acc),
    do: parse_quoted_chars(tail, [?" | acc])

  defp parse_quoted_chars(<<"\\", ?\\, tail::binary>>, acc),
    do: parse_quoted_chars(tail, [?\\ | acc])

  defp parse_quoted_chars(<<"\"", rest::binary>>, acc) do
    # only trailing whitespace allowed
    if String.trim(rest) == "" do
      {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
    else
      {:error, "Trailing characters after quoted value"}
    end
  end

  defp parse_quoted_chars(<<char, tail::binary>>, acc), do: parse_quoted_chars(tail, [char | acc])
  defp parse_quoted_chars(<<>>, _acc), do: {:error, "Unclosed quoted value"}

  # ---------- normalize helpers ----------

  defp kvs_to_map(kvs) do
    grouped =
      Enum.reduce(kvs, %{}, fn {:kv, key, idx, val}, m ->
        case {Map.get(m, key), idx} do
          {nil, nil} ->
            Map.put(m, key, {:scalar, val})

          {nil, i} ->
            Map.put(m, key, {:indexed, %{i => val}})

          {{:scalar, s}, i} when is_integer(i) ->
            # promote scalar to indexed; keep BOTH deterministically
            Map.put(m, key, {:indexed, Map.new([{i, val}, {i + 1, s}])})

          {{:scalar, _s}, nil} ->
            # duplicate scalar → last write wins (deterministic)
            Map.put(m, key, {:scalar, val})

          {{:indexed, mp}, nil} ->
            next = (mp |> Map.keys() |> Enum.max(fn -> -1 end)) + 1
            Map.put(m, key, {:indexed, Map.put_new(mp, next, val)})

          {{:indexed, mp}, i} ->
            Map.put(m, key, {:indexed, Map.put(mp, i, val)})
        end
      end)

    grouped
    |> Enum.map(fn {k, v} ->
      case v do
        {:scalar, s} ->
          {k, s}

        {:indexed, mp} ->
          {k,
           mp
           |> Enum.sort_by(fn {i, _} -> i end)
           |> Enum.map(&elem(&1, 1))}
      end
    end)
    |> Map.new()
  end

  # ---------- small utils ----------

  defp strip_cr(<<c::binary-size(1), rest::binary>>) do
    # tolerate stray \r characters
    if c == "\r", do: strip_cr(rest), else: c <> strip_cr(rest)
  end

  defp strip_cr(<<>>), do: <<>>

  defp split_once_trim(bin, sep) do
    case :binary.split(bin, sep, [:global]) do
      [a, b] -> {String.trim_trailing(a), String.trim_leading(b)}
      _ -> :nomatch
    end
  end

  defp valid_key?(<<>>), do: false

  defp valid_key?(bin) do
    bin
    |> :binary.bin_to_list()
    |> Enum.all?(fn c ->
      (c >= ?A and c <= ?Z) or (c >= ?a and c <= ?z) or (c >= ?0 and c <= ?9) or c == ?_
    end)
  end

  defp trim_space(bin), do: bin |> String.trim()
  defp push_section(acc, {:global, []}), do: acc
  defp push_section(acc, {:global, kvs}), do: [{:global, Enum.reverse(kvs)} | acc]

  defp push_section(acc, {:section, orig, name, kvs}),
    do: [{:section, orig, name, Enum.reverse(kvs)} | acc]

  defp reverse_kvs({:global, kvs}), do: {:global, kvs}
  defp reverse_kvs({:section, o, n, kvs}), do: {:section, o, n, kvs}
end
