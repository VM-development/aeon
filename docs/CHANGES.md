# Aeon — Uncommitted Changes Documentation

This document explains all uncommitted changes, how every struct works, and the complete message flow between the user and the LLM.

---

## Table of Contents

1. [Summary of Changes](#summary-of-changes)
2. [New Files](#new-files)
3. [Modified Files](#modified-files)
4. [Struct Reference](#struct-reference)
5. [Message Flow](#message-flow)
6. [Streaming Internals](#streaming-internals)
7. [Tool Execution Loop](#tool-execution-loop)
8. [Key Zig 0.15 Patterns](#key-zig-015-patterns)

---

## Summary of Changes

These changes implement **Phase 2 (Agent Core)** and **Phase 2.5 (Dialogs)** from the architecture plan. Before these changes, the app was a simple demo that sent a hardcoded `"Count to 3!"` message to OpenAI and printed streamed chunks. After these changes, Aeon is a fully interactive CLI chat assistant with:

- An interactive terminal chat loop with commands (`/quit`, `/clear`, `/help`)
- A message processing pipeline with conversation history
- Streaming responses printed token-by-token in real-time
- A tool registry with built-in tools (`file_read`, `file_write`, `exec`)
- A tool execution loop (LLM can call tools, get results, and continue reasoning)
- A vtable-based dialog provider interface (ready for Telegram, etc.)

---

## New Files

### `src/agent/runtime.zig` — Agent Runtime (Message Processing Pipeline)

The brain of the system. Manages conversation state, sends requests to the LLM, and handles the tool-call loop.

**Structs defined:**

- `AgentRuntime` — Main orchestrator
- `StreamCollector` — Accumulates streaming text + tool calls
- `StreamCollector.PendingToolCall` — Buffers for a single tool call being streamed

### `src/agent/tools.zig` — Tool Registry & Built-in Tools

Defines how tools are registered, stored, looked up, and executed. Ships with three built-in tools.

**Structs defined:**

- `ToolRegistry` — HashMap of name → RegisteredTool
- `RegisteredTool` — Pairs a tool definition with its execute function
- `ToolResult` — Output of running a tool (success, output, error_msg)
- `ToolContext` — Context passed to tool executors (allocator, working dir)
- `ParamDef` — Helper for defining parameters inline

**Built-in tools:**

- `file_read` — Reads a file at a given path, returns its contents
- `file_write` — Writes content to a file (create or overwrite)
- `exec` — Runs a shell command via `/bin/sh -c`, returns stdout+stderr

### `src/dialogs/provider.zig` — Dialog Provider Interface

Defines the vtable-based polymorphic interface that all dialog providers implement (CLI, future Telegram, etc.).

**Structs defined:**

- `InboundMessage` — A message arriving from any dialog (dialog name, from, text, timestamp)
- `DialogProvider` — vtable interface with `start()`, `send()`, `deinit()`
- `DialogProvider.VTable` — The function pointer table

**Type alias:**

- `MessageHandler` — `*const fn(InboundMessage) anyerror![]const u8` — callback that processes a message and returns the response

### `src/dialogs/cli.zig` — CLI Dialog Provider

The interactive terminal chat interface. Implements `DialogProvider`.

**Structs defined:**

- `CliDialog` — The CLI-specific dialog implementation

**Features:**

- ASCII banner on startup
- `you>` prompt for input
- `assistant>` prefix for responses
- Slash commands: `/quit`, `/exit`, `/clear`, `/help`
- Reads stdin byte-by-byte (Zig 0.15 has no `readUntilDelimiter`)
- Calls `MessageHandler` for each user message, streams response in real-time

---

## Modified Files

### `src/aeon.zig` — Main Entry Point (heavily rewritten)

**Before:** Hardcoded demo — sent `"Count to 3!"` to OpenAI, printed chunks via a simple `streamCallback`.

**After:** Full application wiring:

1. Parses CLI args, loads config, initializes logger
2. Reads `OPENAI_API_KEY` from environment (via `env.zig`)
3. Creates `OpenAIClient` → wraps it as a `LlmClient` vtable interface
4. Creates `AgentRuntime` with the LLM client, model name, and system prompt
5. Creates `CliDialog` → wraps it as a `DialogProvider` vtable interface
6. Calls `dialog.start(handleMessage)` which blocks in the interactive loop

**New globals:**

- `g_runtime: ?*AgentRuntime` — needed because `handleMessage` is a plain function pointer (no closures in Zig)
- `SYSTEM_PROMPT` — compile-time string defining Aeon's personality

**New functions:**

- `handleMessage(InboundMessage) ![]const u8` — routes user messages to `AgentRuntime.processMessageStreaming()`, handles `/clear`
- `streamTextDelta(text) !void` — callback that prints each text delta to stdout in real-time

### `src/agent/openai.zig` — OpenAI Client (bug fix)

**Fix:** `ObjectMap` use-after-free in `buildRequestBody()`.

**Problem:** When building the `tools` JSON array, each tool's properties were constructed as `std.json.ObjectMap` instances. The code had `defer props_map.deinit()` and `defer prop_obj.deinit()` *inside the loop*. When the loop iteration ended, these defers freed the hash map internals — but `tools_list` still held shallow copies of those ObjectMaps with now-dangling internal pointers. Later, during serialization, accessing those pointers caused a segfault in `encodeJsonStringChars`.

**Fix:** Removed the in-loop defers. Added a single `defer` block *after* `toOwnedSlice()` that iterates through the finalized `openai_tools` slice after serialization is complete, deiniting each nested ObjectMap and then freeing the slice.

### `.github/prompts/architecture.prompt.md` — Architecture Plan (checkboxes updated)

Updated Phase 2 and Phase 2.5 items from `[ ]` to `[x]` to reflect completed work.

---

## Struct Reference

### `AgentRuntime` (runtime.zig)

```
AgentRuntime
├── allocator: std.mem.Allocator        — Shared allocator (GPA from main)
├── client: *llm.LlmClient             — Pointer to the LLM vtable interface
├── tool_registry: tools.ToolRegistry   — Registry of available tools
├── conversation: ArrayList(llm.Message)— Full conversation history (owned)
├── system_prompt: ?[]const u8          — System prompt text (borrowed)
├── model: []const u8                   — Model name, e.g. "gpt-4o-mini" (borrowed)
└── max_tool_rounds: u32                — Max tool-call iterations (default 10)
```

**Key methods:**

- `init()` — Creates the runtime, registers built-in tools
- `deinit()` — Frees all owned message content + conversation list + tool registry
- `processMessage()` — Non-streaming: send to LLM, handle tool loop, return final text
- `processMessageStreaming()` — Streaming: same loop, but text deltas are emitted via callback in real-time
- `clearHistory()` — Empties conversation (frees all message content)
- `buildMessages()` — Prepends system prompt to conversation history for each LLM call
- `executeToolCalls()` — Runs tools from non-streaming response, appends results as `role: .tool` messages
- `executeToolCallsFromStream()` — Same but from `StreamCollector.PendingToolCall` buffers

### `StreamCollector` (runtime.zig)

```
StreamCollector
├── allocator: std.mem.Allocator
├── text_buf: ArrayList(u8)                    — Accumulates all text deltas
├── tool_calls: ArrayList(PendingToolCall)      — Accumulates tool call data
└── on_text: *const fn([]const u8) !void       — User's streaming callback
```

**Why a global pointer?** Zig function pointers can't capture context (no closures). The LLM streaming API takes a bare `*const fn(StreamEvent) !void` callback. To give that callback access to the `StreamCollector`, we use a file-level global `g_stream_collector: ?*StreamCollector`. This pointer is set *in the caller* (`processMessageStreaming`) after `init()` returns — never inside `init()` itself, because `init()` returns by value and the local's address would be invalid after return.

**PendingToolCall:**

```
PendingToolCall
├── id: ArrayList(u8)        — Tool call ID (accumulated from deltas)
├── name: ArrayList(u8)      — Tool name (accumulated from deltas)
└── arguments: ArrayList(u8) — JSON arguments string (accumulated from deltas)
```

### `ToolRegistry` (tools.zig)

```
ToolRegistry
├── allocator: std.mem.Allocator
└── tools: StringHashMap(RegisteredTool)   — name → (definition + execute fn)
```

**Key methods:**

- `register(name, description, params, executeFn)` — Adds a tool
- `get(name)` — Looks up a tool
- `getToolDefinitions()` — Returns `[]llm.Tool` array for LLM requests
- `executeTool(name, arguments_json, ctx)` — Parses JSON args, calls the tool's execute function
- `registerBuiltins()` — Registers file_read, file_write, exec

### `DialogProvider` (provider.zig)

```
DialogProvider
├── name: []const u8              — e.g. "cli", "telegram"
├── vtable: *const VTable         — Function pointer table
└── impl: *anyopaque              — Pointer to concrete implementation

VTable
├── start: fn(impl, handler) !void   — Start the event loop (blocking)
├── send: fn(impl, to, message) !void — Send a message to a user
└── deinit: fn(impl) void             — Cleanup
```

This is the polymorphic interface. Any dialog backend implements these three functions. The `impl` pointer is cast back to the concrete type (`CliDialog`, future `TelegramDialog`, etc.) inside each vtable function.

### `CliDialog` (cli.zig)

```
CliDialog
├── allocator: std.mem.Allocator
└── running: bool                 — Controls the main loop
```

**Key methods:**

- `init()` / `deinit()` — Lifecycle
- `asDialogProvider()` — Returns a `DialogProvider` vtable wrapping this instance
- `run(handler)` — Main loop: print banner, read lines, dispatch to handler, print responses
- `handleCommand(cmd)` — Processes `/quit`, `/clear`, `/help`

### `OpenAIClient` (openai.zig)

```
OpenAIClient
├── allocator: std.mem.Allocator
├── api_key: []const u8          — Duped, owned
├── base_url: []const u8         — "https://api.openai.com/v1"
└── http_client: HttpClient      — Wrapper around std.http.Client
```

**Key methods:**

- `asLlmClient()` — Returns a `LlmClient` vtable interface
- `streamCompletion(request, callback)` — Sends a streaming request to `/chat/completions`, parses SSE chunks
- `completion(request)` — Non-streaming request
- `buildRequestBody(request, stream)` — Serializes `CompletionRequest` to OpenAI JSON format using `std.json.Stringify`

### `LlmClient` (llm_client.zig)

```
LlmClient
├── allocator: std.mem.Allocator
├── api_key: []const u8
├── base_url: []const u8
├── vtable: *const VTable        — Points to provider-specific functions
└── impl: *anyopaque             — Points to concrete client (e.g. OpenAIClient)

VTable
├── deinit: fn(impl) void
├── streamCompletion: fn(impl, allocator, request, callback) !void
└── completion: fn(impl, allocator, request) !CompletionResponse
```

### `HttpClient` (http.zig)

```
HttpClient
├── client: std.http.Client      — The std library HTTP client
└── allocator: std.mem.Allocator
```

**Key methods:**

- `post(url, headers, body)` → `Response` — Full response read
- `streamRequest(method, url, headers, body, context, callback)` → `Status` — Reads full body via `allocRemaining`, then feeds it to the callback in 4KB chunks

---

## Message Flow

Here's the complete journey of a user message, from typing in the terminal to receiving the LLM's response:

```
┌─────────────────────────────────────────────────────────────────┐
│                        USER TYPES "hello"                       │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  1. CliDialog.run()                                             │
│     • Prints "you> " prompt                                     │
│     • readLine(stdin) reads bytes one at a time until \n        │
│     • Trims whitespace                                          │
│     • Checks for slash commands (none here)                     │
│     • Prints "assistant> " prefix                               │
│     • Calls handler(InboundMessage{text: "hello", ...})        │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  2. aeon.handleMessage(msg)                                     │
│     • Gets AgentRuntime from g_runtime global                   │
│     • Checks if text is "/clear" (no)                           │
│     • Calls agent.processMessageStreaming("hello", streamTextDelta)
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  3. AgentRuntime.processMessageStreaming()                       │
│     • Appends {role: .user, content: "hello"} to conversation   │
│     • Enters tool loop (round 0 of max 10):                     │
│       a. buildMessages() — prepends system prompt to history    │
│       b. getToolDefinitions() — gets file_read, file_write, exec│
│       c. Creates StreamCollector, sets g_stream_collector global │
│       d. Calls client.streamCompletion(request, StreamCollector.callback)
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  4. LlmClient.streamCompletion() — vtable dispatch              │
│     • Calls vtable.streamCompletion → OpenAIClient.streamCompletion
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  5. OpenAIClient.streamCompletion()                             │
│     a. buildRequestBody() — serialize to JSON:                  │
│        {                                                         │
│          "model": "gpt-4o-mini",                                │
│          "messages": [                                           │
│            {"role": "system", "content": "You are Aeon..."},    │
│            {"role": "user", "content": "hello"}                 │
│          ],                                                      │
│          "tools": [                                              │
│            {"type":"function","function":{"name":"file_read",...}│
│            ...                                                   │
│          ],                                                      │
│          "max_tokens": 4096,                                     │
│          "temperature": 1.0,                                     │
│          "stream": true                                          │
│        }                                                         │
│     b. HTTP POST to https://api.openai.com/v1/chat/completions  │
│     c. Passes StreamContext + streamChunkHandler to http client  │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  6. HttpClient.streamRequest()                                  │
│     • Opens connection, sends POST with JSON body               │
│     • Reads FULL response via allocRemaining()                  │
│     • Feeds it to streamChunkHandler in 4KB chunks              │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  7. streamChunkHandler() → SseLineBuffer.feed()                 │
│     • Appends chunk to line buffer                              │
│     • Splits on \n, yields complete lines                       │
│     • Each line goes to handleSseLine()                         │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  8. handleSseLine()                                             │
│     • Strips "data: " prefix                                    │
│     • Skips "[DONE]"                                            │
│     • Parses JSON: {"choices":[{"delta":{"content":"Hi"}}]}     │
│     • Extracts content from delta                               │
│     • Calls callback(.{.text_delta = "Hi"})                     │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  9. StreamCollector.callback() (via g_stream_collector global)  │
│     • .text_delta → appends to text_buf + calls on_text("Hi")  │
│     • .tool_call → creates PendingToolCall entry                │
│     • .tool_call_delta → accumulates into last pending call     │
│     • .done → no-op                                             │
│     • .error → prints to stderr                                 │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  10. aeon.streamTextDelta("Hi")                                 │
│      • stdout_print("{s}", .{"Hi"})                             │
│      • User sees "Hi" appear in the terminal IMMEDIATELY        │
│        (token-by-token as each SSE event arrives)               │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                     (repeats for each SSE event)
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  11. Back in processMessageStreaming() after stream completes   │
│      • stream_collector.getContent() → full accumulated text    │
│      • Appends {role: .assistant, content: "Hi! ..."} to conv  │
│      • Checks stream_collector.getToolCalls()                   │
│        - If tool calls present → execute tools, loop back to 3  │
│        - If no tool calls → return the full response text       │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  12. Back in CliDialog.run()                                    │
│      • response already printed via streaming callback          │
│      • Prints trailing \n\n                                     │
│      • Frees the response string                                │
│      • Loops back to "you> " prompt                             │
└─────────────────────────────────────────────────────────────────┘
```

---

## Streaming Internals

The streaming path has an important architectural constraint: **Zig function pointers cannot capture context** (no closures). This creates a chain of globals/context pointers:

```
OpenAI SSE chunks
       │
       ▼
streamChunkHandler(context: *StreamContext, chunk)
       │  context carries: allocator, callback, line_buffer
       ▼
handleSseLine(line, ctx: *anyopaque)
       │  ctx is cast back to *StreamContext
       │  calls context.callback(StreamEvent)
       ▼
StreamCollector.callback(event: StreamEvent)     ← bare function pointer!
       │  accesses StreamCollector via g_stream_collector global
       │  calls self.on_text(text)
       ▼
aeon.streamTextDelta(text)                       ← bare function pointer!
       │  prints to stdout
       ▼
terminal output
```

**The dangling pointer fix:** `StreamCollector.init()` used to set `g_stream_collector = &sc` where `sc` was the local being returned by value. After return, `sc` no longer exists but the global still pointed to its old stack address. The fix: set the global in the *caller* after `init()` returns, pointing to the caller's copy of the struct.

---

## Tool Execution Loop

When the LLM decides to call a tool, here's what happens:

```
processMessageStreaming() round N
       │
       ▼ LLM response includes tool_calls
       │
       ▼ StreamCollector accumulates: PendingToolCall{name: "exec", args: "{\"command\":\"ls\"}"}
       │
       ▼ executeToolCallsFromStream()
       │     │
       │     ▼ ToolRegistry.executeTool("exec", "{\"command\":\"ls\"}", ctx)
       │     │     │
       │     │     ▼ Parse JSON arguments
       │     │     ▼ Call execExecute(allocator, parsed_value, ctx)
       │     │     ▼ Spawn /bin/sh -c "ls", read stdout+stderr
       │     │     ▼ Return ToolResult{success: true, output: "file1\nfile2\n"}
       │     │
       │     ▼ Append to conversation: {role: .tool, content: "file1\nfile2\n", tool_call_id: "..."}
       │
       ▼ continue → round N+1
       │
       ▼ buildMessages() now includes: system + user + assistant(tool_call) + tool(result)
       │
       ▼ LLM sees the tool result and generates final text response
       │
       ▼ No more tool calls → return response
```

The loop runs up to `max_tool_rounds` (10) times. If the LLM keeps calling tools beyond that, it returns `"[Max tool rounds exceeded]"`.

---

## Key Zig 0.15 Patterns

These patterns are used throughout the codebase due to Zig 0.15 API specifics:

| Pattern | Why |
|---------|-----|
| `var list: std.ArrayList(T) = .{};` + `list.deinit(allocator)` | ArrayLists are unmanaged in 0.15 — allocator is passed to every method |
| `std.json.Stringify.value(val, .{}, &out.writer)` | No `std.json.stringify()` function in 0.15 — use the Stringify struct |
| `std.io.Writer.Allocating` | Growable writer backed by an allocator, used with Stringify |
| `var reader = file.reader(&buf); reader.interface.allocRemaining(...)` | Must be `var` (not `const`) because `allocRemaining` mutates the reader |
| `std.fs.File.stdin()` | No `std.io.getStdIn()` in 0.15 |
| Manual byte-by-byte `readLine()` | No `readUntilDelimiter` on `Io.Reader` in 0.15 |
| `.Pipe` not `.pipe` | PascalCase for std enum values in 0.15 |
| `g_stream_collector` global pointer | Zig function pointers can't capture context — use a global |
| `std.json.ObjectMap` (= `StringArrayHashMap(Value)`) | The JSON object type in 0.15's `std.json` |
