pub const HELP_MESSAGE =
    \\Usage: aeon [OPTIONS]
    \\
    \\Options:
    \\  -v, --version  Print version
    \\  -h, --help     Print this help message
    \\  --config=      Path to config file
;

pub const DEFAULT_CONFIG_PATH: []const u8 = "~/.aeon/aeon.json";
pub const DEFAULT_LOG_FILE_PATH: []const u8 = "~/.aeon/logs/aeon.log";
