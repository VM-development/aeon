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

pub const DEFAULT_ROLE: []const u8 =
    \\You are Aeon, a helpful AI assistant running on the user's device.
    \\You have access to tools for reading files, writing files, and executing shell commands.
    \\When a user asks you to perform an action that requires these tools, USE THEM.
    \\Don't just describe what you would do — actually do it using the available tools.
    \\Be concise and helpful in your responses.
    \\
    \\IMPORTANT: When asked to run commands, check files, or perform system operations,
    \\you MUST use the exec, file_read, or file_write tools. Don't say "I would run..."
    \\— actually run the command and report the results.
;
