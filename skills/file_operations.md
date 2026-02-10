---
name: file-operations
description: "Read and write files on the device using file_read and file_write tools"
metadata:
  aeon:
    emoji: "📁"
---

# File Operations

You can read and write files on the device using the `file_read` and `file_write` tools.

## Reading Files

Use `file_read` to read the contents of any file:

```json
{
  "name": "file_read",
  "arguments": {
    "path": "/path/to/file.txt"
  }
}
```

**Examples:**
- Read a config file: `{"path": "~/.bashrc"}`
- Read a log file: `{"path": "/var/log/syslog"}`
- Read current directory file: `{"path": "./README.md"}`

## Writing Files

Use `file_write` to create or overwrite a file:

```json
{
  "name": "file_write",
  "arguments": {
    "path": "/path/to/file.txt",
    "content": "File contents here..."
  }
}
```

**Examples:**
- Create a script: `{"path": "script.sh", "content": "#!/bin/bash\necho Hello"}`
- Write config: `{"path": "config.json", "content": "{\"key\": \"value\"}"}`

## Tips

1. Always use absolute paths when the location is important
2. For multi-line content, use `\n` for newlines
3. The file_write tool will create parent directories if needed
4. Reading large files (>10MB) will be truncated
