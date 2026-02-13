---
name: shell-commands
description: "Execute shell commands on the device using the exec tool for system interaction"
metadata:
  aeon:
    emoji: "🖥️"
---

# Shell Command Execution

You can execute shell commands on the device using the `exec` tool. This is your most powerful ability for interacting with the system.

## IMPORTANT: Always Report Before Executing

**Before running any command, you MUST inform the user what you're about to do.**

1. **Announce the command** — Tell the user what command you will execute and why
2. **Explain the purpose** — Briefly describe what the command does
3. **Then execute** — Only after informing the user, proceed with the tool call

**Example conversation flow:**

```
User: "Install htop"
Assistant: "I'll install htop using Homebrew:
brew install htop"
[Then call exec tool]
```

This gives the user visibility into what's happening on their system and allows them to interrupt if needed.

## Basic Usage

```json
{
  "name": "exec",
  "arguments": {
    "command": "your shell command here"
  }
}
```

## Common Operations

### System Information

- `uname -a` — OS and kernel info
- `hostname` — Device hostname
- `whoami` — Current user
- `pwd` — Current working directory
- `df -h` — Disk space usage
- `free -h` — Memory usage (Linux)
- `top -l 1` — Process list (macOS)
- `ps aux` — Running processes

### File System

- `ls -la /path` — List directory contents
- `find /path -name "*.txt"` — Find files
- `cat /path/to/file` — Display file contents
- `head -n 20 file` — First 20 lines
- `tail -n 20 file` — Last 20 lines
- `wc -l file` — Count lines
- `du -sh /path` — Directory size

### Network

- `curl -s https://api.example.com` — HTTP requests
- `ping -c 3 google.com` — Test connectivity
- `ifconfig` or `ip addr` — Network interfaces
- `netstat -an` — Network connections

### Package Management

**macOS (Homebrew):**

- `brew list` — Installed packages
- `brew install package` — Install package
- `brew update && brew upgrade` — Update all

**Linux (apt):**

- `apt list --installed` — Installed packages
- `sudo apt install package` — Install package
- `sudo apt update && sudo apt upgrade` — Update all

### Git Operations

- `git status` — Repository status
- `git log --oneline -10` — Recent commits
- `git diff` — Uncommitted changes
- `git branch -a` — List branches
- `git pull origin main` — Pull latest

### Process Management

- `pgrep -l process_name` — Find process
- `kill PID` — Terminate process
- `killall process_name` — Kill by name

## Chaining Commands

Use shell operators to chain commands:

- `cmd1 && cmd2` — Run cmd2 only if cmd1 succeeds
- `cmd1 || cmd2` — Run cmd2 only if cmd1 fails
- `cmd1 ; cmd2` — Run both regardless
- `cmd1 | cmd2` — Pipe output

**Example:** `cd /project && git status && git log --oneline -5`

## Working with Output

Commands return both stdout and stderr. Large outputs are truncated at 10MB.

## Important Notes

1. Commands run via `/bin/sh -c "command"`
2. Commands execute in the aeon process working directory
3. Interactive commands (requiring user input) will hang — avoid them
4. Use `-y` or `--yes` flags for non-interactive operation
5. Sensitive commands may require elevated privileges

## Examples

**Check system health:**

```json
{"command": "uptime && df -h / && free -h 2>/dev/null || vm_stat"}
```

**List project files:**

```json
{"command": "find . -type f -name '*.py' | head -20"}
```

**Run a script:**

```json
{"command": "bash /path/to/script.sh"}
```

**Check service status:**

```json
{"command": "systemctl status nginx 2>/dev/null || launchctl list | grep nginx"}
```
