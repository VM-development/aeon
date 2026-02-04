# Aeon Project Structure

## Overview

Aeon is a Zig-based bot application (version 0.0.1) with CLI argument parsing and JSON-based configuration management.

## Directory Structure

```
aeon/
├── .github/
│   └── prompts/                 # Prompt documentation
├── src/
│   ├── aeon.zig                 # Main application entry point
│   ├── cli.zig                  # CLI argument parsing module
│   ├── config.zig               # JSON configuration file handling
│   └── utils.zig                # Utility functions
├── build.zig                    # Zig build configuration
├── build.zig.zon                # Package manifest and dependencies
├── config.json                  # Example runtime configuration file
└── zig-out/                     # Build output directory (generated)
    ├── bin/aeon                 # Compiled executable
    └── lib/                     # Library artifacts
```

## Core Modules

### [src/aeon.zig](src/aeon.zig)

**Purpose**: Main application entry point

**Key Functionality**:

- Initializes memory allocator (GeneralPurposeAllocator)
- Parses CLI arguments via `cli.parseArgs()`
- Handles `--version` and `--help` flags
- Loads configuration from `config.json` with fallback to defaults
- Prints initialization message with loaded log file path

**Key Code**:

- `pub fn main() !void` - Entry point
- Config loading with error handling and default fallback
- Memory management for allocated config strings

### [src/cli.zig](src/cli.zig)

**Purpose**: CLI argument parsing module

**Key Functionality**:

- Parses command-line arguments
- Supports `--version`/`-v` flag
- Supports `--help`/`-h` flag
- Provides help message constant

**Key Code**:

- `pub fn parseArgs(allocator: std.mem.Allocator) !CliArgs` - Parses CLI args
- `pub const HELP_MESSAGE` - Help text template
- `pub const CliArgs` struct - Stores parsed arguments

### [src/config.zig](src/config.zig)

**Purpose**: JSON configuration file parsing and management

**Key Functionality**:

- Parses JSON configuration files
- Supports loading from file or string
- Provides default configuration values
- Type-safe config struct with `log_file_path` field

**Key Code**:

- `pub const Config` struct with `log_file_path` field (default: "/var/log/aeon.log")
- `pub fn loadFromFile(allocator, path) !Config` - Loads JSON from file
- `pub fn loadFromString(allocator, json_str) !Config` - Parses JSON string
- `pub fn createDefaultConfig() Config` - Returns default instance

### [src/utils.zig](src/utils.zig)

**Purpose**: Utility functions

**Key Functionality**:

- Standard output printing with formatting

**Key Code**:

- `stdout_print()` - Formatted printing to stdout

## Build Configuration

### [build.zig](build.zig)

- Configures executable build for Zig project
- Adds version information via build options
- Defines "run" step for executing the application
- Supports passing arguments to the app at build time

### [build.zig.zon](build.zig.zon)

- Package manifest specifying:
  - Name: `aeon`
  - Version: `0.0.1`
  - Minimum Zig version requirement

## Configuration

### config.json (Example)

```json
{
  "log_file_path": "/tmp/aeon.log"
}
```

**Behavior**:

- Optional file that overrides default configuration
- If missing, application uses default log path: `/var/log/aeon.log`
- Must be valid JSON to be parsed successfully
- Invalid JSON triggers warning but application continues with defaults

## Build and Run

### Building

```bash
zig build
```

### Running

```bash
# Default run
./zig-out/bin/aeon

# With version flag
./zig-out/bin/aeon --version
# Output: aeon version 0.0.1

# With help flag
./zig-out/bin/aeon --help

# With arguments via build
zig build run -- --version
```

## Dependencies

- **Zig Version**: 0.15.2+
- **Standard Library**:
  - `std.json` - JSON parsing
  - `std.fs` - File system operations
  - `std.mem` - Memory management
  - `std.process` - Process/argument handling
  - `std.heap` - Allocator implementations

## Key Implementation Details

### Memory Management

- Uses GeneralPurposeAllocator for lifecycle management
- Config strings allocated via `allocator.dupe()` when loaded from JSON
- Conditional deallocation based on config source (file vs default)

### Error Handling

- File opening failures default to creating default config
- JSON parse errors produce warning messages but don't crash application
- All allocations use defer patterns for cleanup

### Configuration Fallback Strategy

1. Attempt to load `config.json` from current working directory
2. If file missing or JSON invalid, use hardcoded defaults
3. Merge parsed config with defaults
4. Print initialization message with final config

## Extension Points

### Future Enhancements

- Expand `Config` struct with additional fields
- Implement config subcommand for runtime config management
- Add config schema validation
- Support environment variable overrides
- Add configuration file path as CLI argument

### CLI Argument Parsing (TODO)

- Currently supports: `--version`, `--help`
- Deferred: Config subcommand with `--path` option
- Current framework: Manual string matching (ready for expansion)

## Developer Notes

- **Language**: Zig 0.15.2
- **Compilation**: All modules compile without errors
- **Testing**: Manual testing verified config loading, defaults, and CLI flags
- **Status**: Core JSON config system complete and stable
- **Next Steps**: Config system ready for feature expansion or additional fields
