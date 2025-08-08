# Unraid

Core Elixir Lib

## Unraid INI Parser

A robust parser for Unraid's custom INI/CFG configuration file format that handles all the non-standard idiosyncrasies found in Unraid's state files.

### Features

- **Quoted section headers**: `["section_name"]` instead of standard `[section_name]`
- **Mixed value quoting**: Handles both quoted (`"value"`) and unquoted (`value`) values
- **Array-style indexing**: Supports keys like `IPADDR:0`, `USE_DHCP:0` with colons and indices
- **Empty values**: Gracefully handles empty strings and missing values
- **Global sections**: Supports key-value pairs before any section definition
- **Comment support**: Ignores lines starting with `#` or `;`
- **Error handling**: Robust parsing with graceful error recovery

### Usage

#### Parse from string

```elixir
content = """
version="6.11.2"
NAME="Tower"
["disk1"]
name="disk1"
device="sdf"
"""

{:ok, config} = Unraid.IniParser.parse(content)
# => {:ok, %{
#      global: %{"version" => "6.11.2", "NAME" => "Tower"},
#      "disk1" => %{"name" => "disk1", "device" => "sdf"}
#    }}
```

### Examples with Real Unraid Files

#### var.ini format (global configuration)
```elixir
content = File.read!("var.ini")
{:ok, config} = Unraid.IniParser.parse(content)
version = config.global["version"]  # "6.11.2"
name = config.global["NAME"]        # "Tower"
```

#### disks.ini format (sectioned data)
```elixir
content = File.read!("disks.ini")
{:ok, config} = Unraid.IniParser.parse(content)
parity_info = config["parity"]      # %{"idx" => "0", "name" => "parity", ...}
disk1_info = config["disk1"]        # %{"idx" => "1", "name" => "disk1", ...}
```

#### network.ini format (array-style indexing)
```elixir
content = File.read!("network.ini")
{:ok, config} = Unraid.IniParser.parse(content)
eth0_config = config["eth0"]
ip_address = eth0_config["IPADDR:0"]    # "192.168.1.150"
use_dhcp = eth0_config["USE_DHCP:0"]    # "yes"
```

#### myservers.cfg format (standard sections)
```elixir
content = File.read!("myservers.cfg")
{:ok, config} = Unraid.IniParser.parse(content)
api_config = config["api"]              # %{"version" => "4.4.1", ...}
local_config = config["local"]          # %{"sandbox" => "yes"}
```

### Error Handling

The parser returns `{:ok, result}` on success or `{:error, reason}` on failure:

```elixir
case Unraid.IniParser.parse(malformed_content) do
  {:ok, config} -> 
    # Process config
  {:error, reason} -> 
    IO.puts("Failed to parse: #{reason}")
end
```

### Format Idiosyncrasies Handled

1. **Non-standard section headers**: `["quoted_section"]` vs standard `[section]`
2. **Mixed quoting**: Some values quoted, others not
3. **Array notation**: Keys with colons like `KEY:0`, `KEY:1`
4. **Empty values**: Handles `key=""` and `key=` gracefully
5. **No top-level section**: Global key-value pairs before any `[section]`
6. **Special characters**: Handles complex values with URLs, paths, etc.
7. **Comment variations**: Supports both `#` and `;` comment styles
8. **Whitespace preservation**: Maintains spacing in quoted values

### Testing

Run the comprehensive test suite:

```bash
mix test apps/unraid/test/unraid/ini_parser_test.exs
```

The tests cover all edge cases and real-world Unraid configuration scenarios.