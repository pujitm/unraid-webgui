defmodule Unraid.Parse do
  @moduledoc """
  Global parsing utilities for the Unraid application.

  Provides consistent, pattern-matched functions for parsing common data types
  from various input formats (strings, integers, nil, etc.).

  ## Design Principle: Distinguish Empty vs Invalid

  Each parsing function has variants:
  - **Base function** (e.g., `integer/1`): Returns `{:ok, value}`, `{:error, :empty}`, or `{:error, :invalid}`
  - **Bang variant** (e.g., `integer!/1`): Returns value or raises on invalid (nil for empty)
  - **Lenient variant** (e.g., `integer_or_nil/1`): Returns value or nil for empty/invalid

  ## Examples

      iex> Unraid.Parse.integer("42")
      {:ok, 42}

      iex> Unraid.Parse.integer(nil)
      {:error, :empty}

      iex> Unraid.Parse.integer("abc")
      {:error, :invalid}

      iex> Unraid.Parse.integer_or_nil("42")
      42

      iex> Unraid.Parse.integer_or_default(nil, 0)
      0
  """

  # ---------------------------------------------------------------------------
  # Integer Parsing
  # ---------------------------------------------------------------------------

  @doc """
  Parses a value to an integer.

  Returns `{:ok, integer}` on success, `{:error, :empty}` for nil/empty string,
  or `{:error, :invalid}` for unparseable values.

  ## Examples

      iex> Unraid.Parse.integer("42")
      {:ok, 42}

      iex> Unraid.Parse.integer(42)
      {:ok, 42}

      iex> Unraid.Parse.integer(nil)
      {:error, :empty}

      iex> Unraid.Parse.integer("")
      {:error, :empty}

      iex> Unraid.Parse.integer("abc")
      {:error, :invalid}
  """
  @spec integer(term()) :: {:ok, integer()} | {:error, :empty | :invalid}
  def integer(nil), do: {:error, :empty}
  def integer(""), do: {:error, :empty}
  def integer(value) when is_integer(value), do: {:ok, value}

  def integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {num, _} -> {:ok, num}
      :error -> {:error, :invalid}
    end
  end

  def integer(_), do: {:error, :invalid}

  @doc """
  Parses a value to an integer, raising on invalid input.

  Returns the integer on success, nil for empty input, or raises `ArgumentError` for invalid input.

  ## Examples

      iex> Unraid.Parse.integer!("42")
      42

      iex> Unraid.Parse.integer!(nil)
      nil

      iex> Unraid.Parse.integer!("abc")
      ** (ArgumentError) cannot parse "abc" as integer
  """
  @spec integer!(term()) :: integer() | nil
  def integer!(value) do
    case integer(value) do
      {:ok, num} -> num
      {:error, :empty} -> nil
      {:error, :invalid} -> raise ArgumentError, "cannot parse #{inspect(value)} as integer"
    end
  end

  @doc """
  Parses a value to an integer, returning nil for empty or invalid input.

  This is the lenient variant for backwards-compatible behavior.

  ## Examples

      iex> Unraid.Parse.integer_or_nil("42")
      42

      iex> Unraid.Parse.integer_or_nil(nil)
      nil

      iex> Unraid.Parse.integer_or_nil("abc")
      nil
  """
  @spec integer_or_nil(term()) :: integer() | nil
  def integer_or_nil(value) do
    case integer(value) do
      {:ok, num} -> num
      {:error, _} -> nil
    end
  end

  @doc """
  Parses a value to an integer, returning a default for empty or invalid input.

  ## Examples

      iex> Unraid.Parse.integer_or_default("42", 0)
      42

      iex> Unraid.Parse.integer_or_default(nil, 0)
      0

      iex> Unraid.Parse.integer_or_default("abc", -1)
      -1
  """
  @spec integer_or_default(term(), term()) :: integer() | term()
  def integer_or_default(value, default) do
    case integer(value) do
      {:ok, num} -> num
      {:error, _} -> default
    end
  end

  # ---------------------------------------------------------------------------
  # Float Parsing
  # ---------------------------------------------------------------------------

  @doc """
  Parses a value to a float.

  Returns `{:ok, float}` on success, `{:error, :empty}` for nil/empty string,
  or `{:error, :invalid}` for unparseable values.

  ## Examples

      iex> Unraid.Parse.float("3.14")
      {:ok, 3.14}

      iex> Unraid.Parse.float("42")
      {:ok, 42.0}

      iex> Unraid.Parse.float(nil)
      {:error, :empty}

      iex> Unraid.Parse.float("abc")
      {:error, :invalid}
  """
  @spec float(term()) :: {:ok, float()} | {:error, :empty | :invalid}
  def float(nil), do: {:error, :empty}
  def float(""), do: {:error, :empty}
  def float(value) when is_float(value), do: {:ok, value}
  def float(value) when is_integer(value), do: {:ok, value * 1.0}

  def float(value) when is_binary(value) do
    case Float.parse(value) do
      {num, _} -> {:ok, num}
      :error -> {:error, :invalid}
    end
  end

  def float(_), do: {:error, :invalid}

  @doc """
  Parses a value to a float, raising on invalid input.

  Returns the float on success, 0.0 for empty input, or raises `ArgumentError` for invalid input.

  ## Examples

      iex> Unraid.Parse.float!("3.14")
      3.14

      iex> Unraid.Parse.float!(nil)
      0.0

      iex> Unraid.Parse.float!("abc")
      ** (ArgumentError) cannot parse "abc" as float
  """
  @spec float!(term()) :: float()
  def float!(value) do
    case float(value) do
      {:ok, num} -> num
      {:error, :empty} -> 0.0
      {:error, :invalid} -> raise ArgumentError, "cannot parse #{inspect(value)} as float"
    end
  end

  @doc """
  Parses a value to a float, returning a default for empty or invalid input.

  ## Examples

      iex> Unraid.Parse.float_or_default("3.14", 0.0)
      3.14

      iex> Unraid.Parse.float_or_default(nil, 0.0)
      0.0

      iex> Unraid.Parse.float_or_default("abc", 1.5)
      1.5
  """
  @spec float_or_default(term(), float()) :: float()
  def float_or_default(value, default) when is_number(default) do
    case float(value) do
      {:ok, num} -> num
      {:error, _} -> default * 1.0
    end
  end

  # ---------------------------------------------------------------------------
  # Percent Parsing
  # ---------------------------------------------------------------------------

  @doc """
  Parses a percentage string (e.g., "45.5%") to a float.

  Returns `{:ok, float}` on success, `{:error, :empty}` for nil/empty string,
  or `{:error, :invalid}` for unparseable values.

  ## Examples

      iex> Unraid.Parse.percent("45.5%")
      {:ok, 45.5}

      iex> Unraid.Parse.percent("45.5")
      {:ok, 45.5}

      iex> Unraid.Parse.percent(nil)
      {:error, :empty}

      iex> Unraid.Parse.percent("abc%")
      {:error, :invalid}
  """
  @spec percent(term()) :: {:ok, float()} | {:error, :empty | :invalid}
  def percent(nil), do: {:error, :empty}
  def percent(""), do: {:error, :empty}
  def percent(value) when is_number(value), do: {:ok, value * 1.0}

  def percent(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_trailing("%")
    |> float()
  end

  def percent(_), do: {:error, :invalid}

  @doc """
  Parses a percentage string, returning a default for empty or invalid input.

  ## Examples

      iex> Unraid.Parse.percent_or_default("45.5%", 0.0)
      45.5

      iex> Unraid.Parse.percent_or_default(nil, 0.0)
      0.0

      iex> Unraid.Parse.percent_or_default("abc", 0.0)
      0.0
  """
  @spec percent_or_default(term(), float()) :: float()
  def percent_or_default(value, default) when is_number(default) do
    case percent(value) do
      {:ok, num} -> num
      {:error, _} -> default * 1.0
    end
  end

  # ---------------------------------------------------------------------------
  # Boolean Parsing
  # ---------------------------------------------------------------------------

  @truthy_values ~w(true True TRUE 1 yes Yes YES on On ON)

  @doc """
  Parses a value to a boolean.

  Returns `{:ok, boolean}` on success, or `{:error, :empty}` for nil/empty string.
  Unknown values are treated as false (not invalid).

  Truthy values: `true`, `"true"`, `"True"`, `"TRUE"`, `"1"`, `"yes"`, `"on"`, `1`

  ## Examples

      iex> Unraid.Parse.boolean("true")
      {:ok, true}

      iex> Unraid.Parse.boolean("false")
      {:ok, false}

      iex> Unraid.Parse.boolean(nil)
      {:error, :empty}

      iex> Unraid.Parse.boolean("random")
      {:ok, false}
  """
  @spec boolean(term()) :: {:ok, boolean()} | {:error, :empty}
  def boolean(nil), do: {:error, :empty}
  def boolean(""), do: {:error, :empty}
  def boolean(true), do: {:ok, true}
  def boolean(false), do: {:ok, false}
  def boolean(1), do: {:ok, true}
  def boolean(0), do: {:ok, false}

  def boolean(value) when is_binary(value) do
    if value in @truthy_values do
      {:ok, true}
    else
      {:ok, false}
    end
  end

  def boolean(_), do: {:ok, false}

  @doc """
  Parses a value to a boolean, returning a default for empty input.

  ## Examples

      iex> Unraid.Parse.boolean_or_default("true", false)
      true

      iex> Unraid.Parse.boolean_or_default(nil, false)
      false

      iex> Unraid.Parse.boolean_or_default("", true)
      true
  """
  @spec boolean_or_default(term(), boolean()) :: boolean()
  def boolean_or_default(value, default) when is_boolean(default) do
    case boolean(value) do
      {:ok, bool} -> bool
      {:error, :empty} -> default
    end
  end

  # ---------------------------------------------------------------------------
  # Positive Integer Parsing
  # ---------------------------------------------------------------------------

  @doc """
  Parses a value to a positive integer (greater than 0).

  Returns `{:ok, pos_integer}` on success, `{:error, :empty}` for nil/empty string,
  `{:error, :invalid}` for unparseable values, or `{:error, :not_positive}` for
  zero or negative numbers.

  ## Examples

      iex> Unraid.Parse.positive_integer("42")
      {:ok, 42}

      iex> Unraid.Parse.positive_integer("0")
      {:error, :not_positive}

      iex> Unraid.Parse.positive_integer("-5")
      {:error, :not_positive}

      iex> Unraid.Parse.positive_integer(nil)
      {:error, :empty}
  """
  @spec positive_integer(term()) :: {:ok, pos_integer()} | {:error, :empty | :invalid | :not_positive}
  def positive_integer(value) do
    case integer(value) do
      {:ok, num} when num > 0 -> {:ok, num}
      {:ok, _} -> {:error, :not_positive}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Parses a value to a positive integer, returning nil for empty, invalid, or non-positive.

  ## Examples

      iex> Unraid.Parse.positive_integer_or_nil("42")
      42

      iex> Unraid.Parse.positive_integer_or_nil("0")
      nil

      iex> Unraid.Parse.positive_integer_or_nil(nil)
      nil
  """
  @spec positive_integer_or_nil(term()) :: pos_integer() | nil
  def positive_integer_or_nil(value) do
    case positive_integer(value) do
      {:ok, num} -> num
      {:error, _} -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Nil/Empty Normalization
  # ---------------------------------------------------------------------------

  @doc """
  Converts empty strings to nil. Other values pass through unchanged.

  ## Examples

      iex> Unraid.Parse.nilify("")
      nil

      iex> Unraid.Parse.nilify("hello")
      "hello"

      iex> Unraid.Parse.nilify(nil)
      nil

      iex> Unraid.Parse.nilify(42)
      42
  """
  @spec nilify(term()) :: term() | nil
  def nilify(""), do: nil
  def nilify(value), do: value

  @doc """
  Checks if a value is empty (nil or empty string).

  ## Examples

      iex> Unraid.Parse.empty?(nil)
      true

      iex> Unraid.Parse.empty?("")
      true

      iex> Unraid.Parse.empty?("hello")
      false

      iex> Unraid.Parse.empty?(0)
      false
  """
  @spec empty?(term()) :: boolean()
  def empty?(nil), do: true
  def empty?(""), do: true
  def empty?(_), do: false

  @doc """
  Checks if a value is present (not nil and not empty string).

  ## Examples

      iex> Unraid.Parse.present?("hello")
      true

      iex> Unraid.Parse.present?(nil)
      false

      iex> Unraid.Parse.present?("")
      false

      iex> Unraid.Parse.present?(0)
      true
  """
  @spec present?(term()) :: boolean()
  def present?(value), do: not empty?(value)

  @doc """
  Returns the default value if the input is nil or empty string.

  ## Examples

      iex> Unraid.Parse.default(nil, "default")
      "default"

      iex> Unraid.Parse.default("", "default")
      "default"

      iex> Unraid.Parse.default("value", "default")
      "value"
  """
  @spec default(term(), term()) :: term()
  def default(nil, default_value), do: default_value
  def default("", default_value), do: default_value
  def default(value, _default_value), do: value

  # ---------------------------------------------------------------------------
  # Port Type Normalization
  # ---------------------------------------------------------------------------

  @doc """
  Normalizes a port type/protocol string.

  Returns `{:ok, protocol}` (lowercase) on success, or `{:error, :empty}` for nil/empty string.

  ## Examples

      iex> Unraid.Parse.port_type("TCP")
      {:ok, "tcp"}

      iex> Unraid.Parse.port_type("udp")
      {:ok, "udp"}

      iex> Unraid.Parse.port_type(nil)
      {:error, :empty}
  """
  @spec port_type(term()) :: {:ok, String.t()} | {:error, :empty}
  def port_type(nil), do: {:error, :empty}
  def port_type(""), do: {:error, :empty}
  def port_type(mode) when is_binary(mode), do: {:ok, String.downcase(mode)}
  def port_type(_), do: {:error, :empty}

  @doc """
  Normalizes a port type/protocol string, returning a default for empty input.

  ## Examples

      iex> Unraid.Parse.port_type_or_default("TCP", "tcp")
      "tcp"

      iex> Unraid.Parse.port_type_or_default(nil, "tcp")
      "tcp"

      iex> Unraid.Parse.port_type_or_default("", "udp")
      "udp"
  """
  @spec port_type_or_default(term(), String.t()) :: String.t()
  def port_type_or_default(value, default) when is_binary(default) do
    case port_type(value) do
      {:ok, type} -> type
      {:error, :empty} -> default
    end
  end
end
