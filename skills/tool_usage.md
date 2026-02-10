---
name: tool-usage
description: "Proper format and workflow for invoking tools including file_read, file_write, and exec"
metadata:
  aeon:
    emoji: "🔧"
---

# Tool Usage Format

When using tools, you must respond with a specific JSON format that the system can parse. This document explains how to properly invoke tools.

## Response Format

When you want to use a tool, respond with a tool call in your message. The LLM API will handle the formatting, but you should know:

1. **Tool calls are separate from text responses** — you either respond with text OR invoke tools
2. **Multiple tools can be called in sequence** — the system will execute each and return results
3. **Always wait for tool results** before continuing

## Available Tools

### 1. `file_read`
Read contents of a file.

**Parameters:**
- `path` (string, required): Path to the file

### 2. `file_write`
Write content to a file (creates or overwrites).

**Parameters:**
- `path` (string, required): Path to the file
- `content` (string, required): Content to write

### 3. `exec`
Execute a shell command.

**Parameters:**
- `command` (string, required): Shell command to run

## Tool Workflow

1. User asks for something that requires system access
2. You decide which tool(s) to use
3. You invoke the tool with proper arguments
4. System executes the tool and returns results
5. You interpret results and respond to user

## Best Practices

1. **Confirm before dangerous operations** — deleting files, modifying system configs
2. **Break complex tasks into steps** — read first, then modify, then verify
3. **Handle errors gracefully** — if a tool fails, explain what went wrong
4. **Be specific with paths** — use absolute paths when precision matters
5. **Check before writing** — read a file first if you need to modify it

## Error Handling

Tools return:
- `success: true/false`
- `output: string` — command output or file contents
- `error_msg: optional string` — error description if failed

Always check the success status and handle failures appropriately.
