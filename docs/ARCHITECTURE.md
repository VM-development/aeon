# Aeon — System Architecture

This document provides visual diagrams explaining the system architecture, module interactions, and message flow through the application.

---

## Table of Contents

1. [High-Level System Architecture](#high-level-system-architecture)
2. [Module Dependency Graph](#module-dependency-graph)
3. [Message Flow: User → LLM → User](#message-flow-user--llm--user)
4. [Streaming Data Flow](#streaming-data-flow)
5. [Tool Execution Flow](#tool-execution-flow)
6. [Module Reference](#module-reference)

---

## High-Level System Architecture

This diagram shows all major components and how they relate to each other:

```mermaid
graph TB
    subgraph "Entry Point"
        MAIN[aeon.zig<br/>Main Entry Point]
    end

    subgraph "Dialog Layer"
        DP[DialogProvider<br/>Interface]
        CLI[CliDialog<br/>Terminal UI]
        TG[TelegramDialog<br/>🚧 Future]
    end

    subgraph "Agent Layer"
        RT[AgentRuntime<br/>Message Pipeline]
        TR[ToolRegistry<br/>Tool Management]
        SC[StreamCollector<br/>Streaming Accumulator]
    end

    subgraph "LLM Layer"
        LC[LlmClient<br/>vtable Interface]
        OAI[OpenAIClient<br/>API Implementation]
        ANT[AnthropicClient<br/>🚧 Future]
    end

    subgraph "Infrastructure"
        HTTP[HttpClient<br/>HTTP/TLS]
        SSE[SseLineBuffer<br/>SSE Parser]
        ENV[env.zig<br/>Environment Vars]
        CFG[config.zig<br/>JSON Config]
        LOG[logger.zig<br/>Logging]
    end

    subgraph "Built-in Tools"
        T1[file_read]
        T2[file_write]
        T3[exec]
    end

    %% Entry point connections
    MAIN --> CLI
    MAIN --> RT
    MAIN --> OAI
    MAIN --> CFG
    MAIN --> LOG
    MAIN --> ENV

    %% Dialog layer
    CLI --> DP
    TG -.-> DP
    DP --> RT

    %% Agent layer
    RT --> LC
    RT --> TR
    RT --> SC
    TR --> T1
    TR --> T2
    TR --> T3

    %% LLM layer
    OAI --> LC
    ANT -.-> LC
    OAI --> HTTP
    OAI --> SSE

    %% Styling
    classDef future fill:#f9f,stroke:#333,stroke-dasharray: 5 5
    classDef interface fill:#bbf,stroke:#333
    classDef core fill:#bfb,stroke:#333
    class TG,ANT future
    class DP,LC interface
    class RT,TR core
```

### Component Descriptions

| Component | File | Purpose |
|-----------|------|---------|
| **aeon.zig** | `src/aeon.zig` | Application entry point. Parses CLI args, loads config, initializes all components, starts the dialog loop. |
| **DialogProvider** | `src/dialogs/provider.zig` | vtable interface for dialog backends. Defines `start()`, `send()`, `deinit()`. |
| **CliDialog** | `src/dialogs/cli.zig` | Interactive terminal chat. Reads stdin, prints responses, handles `/commands`. |
| **AgentRuntime** | `src/agent/runtime.zig` | Core message processing pipeline. Manages conversation history, orchestrates LLM calls, handles tool loop. |
| **ToolRegistry** | `src/agent/tools.zig` | Stores and executes tools. Provides tool definitions to LLM requests. |
| **StreamCollector** | `src/agent/runtime.zig` | Accumulates text deltas and tool calls during streaming. |
| **LlmClient** | `src/agent/llm_client.zig` | vtable interface for LLM providers. Defines `streamCompletion()`, `completion()`. |
| **OpenAIClient** | `src/agent/openai.zig` | OpenAI API implementation. Handles request building, SSE parsing, response extraction. |
| **HttpClient** | `src/utils/http.zig` | Wrapper around `std.http.Client`. Supports both full-response and streaming requests. |
| **SseLineBuffer** | `src/agent/llm_client.zig` | Parses SSE (Server-Sent Events) streams line by line. |

---

## Module Dependency Graph

This shows the import relationships between all source files:

```mermaid
graph LR
    subgraph "Main"
        A[aeon.zig]
    end

    subgraph "Core"
        C1[cli.zig]
        C2[config.zig]
        C3[constants.zig]
        C4[logger.zig]
    end

    subgraph "Agent"
        AG1[runtime.zig]
        AG2[tools.zig]
        AG3[llm_client.zig]
        AG4[openai.zig]
    end

    subgraph "Dialogs"
        D1[provider.zig]
        D2[cli.zig]
    end

    subgraph "Utils"
        U1[http.zig]
        U2[utils.zig]
        U3[env.zig]
    end

    %% Main imports
    A --> C1
    A --> C2
    A --> C3
    A --> C4
    A --> AG1
    A --> AG4
    A --> D1
    A --> D2
    A --> U2
    A --> U3

    %% Agent imports
    AG1 --> AG2
    AG1 --> AG3
    AG1 --> U2
    AG2 --> AG3
    AG4 --> AG3
    AG4 --> U1

    %% Dialog imports
    D2 --> D1
    D2 --> U2
```

---

## Message Flow: User → LLM → User

This sequence diagram shows the complete journey of a user message through the system:

```mermaid
sequenceDiagram
    participant User
    participant CliDialog
    participant aeon.zig
    participant AgentRuntime
    participant LlmClient
    participant OpenAIClient
    participant HttpClient
    participant OpenAI API

    User->>CliDialog: Types "hello" + Enter
    CliDialog->>CliDialog: readLine(stdin)
    CliDialog->>CliDialog: Trim whitespace
    CliDialog->>CliDialog: Print "assistant> "
    
    CliDialog->>aeon.zig: handleMessage(InboundMessage)
    aeon.zig->>AgentRuntime: processMessageStreaming("hello", callback)
    
    Note over AgentRuntime: Append user message to conversation
    
    AgentRuntime->>AgentRuntime: buildMessages()
    Note over AgentRuntime: Prepend system prompt
    
    AgentRuntime->>AgentRuntime: getToolDefinitions()
    Note over AgentRuntime: Get file_read, file_write, exec
    
    AgentRuntime->>AgentRuntime: Create StreamCollector
    AgentRuntime->>AgentRuntime: Set g_stream_collector global
    
    AgentRuntime->>LlmClient: streamCompletion(request, callback)
    LlmClient->>OpenAIClient: vtable dispatch
    
    OpenAIClient->>OpenAIClient: buildRequestBody()
    Note over OpenAIClient: JSON with messages + tools
    
    OpenAIClient->>HttpClient: streamRequest(POST, url, body)
    HttpClient->>OpenAI API: HTTP POST /chat/completions
    
    OpenAI API-->>HttpClient: SSE stream chunks
    
    loop For each SSE chunk
        HttpClient->>OpenAIClient: streamChunkHandler(chunk)
        OpenAIClient->>OpenAIClient: SseLineBuffer.feed()
        OpenAIClient->>OpenAIClient: handleSseLine()
        OpenAIClient->>AgentRuntime: callback(.text_delta)
        AgentRuntime->>AgentRuntime: StreamCollector.callback()
        AgentRuntime->>aeon.zig: on_text("Hi")
        aeon.zig->>User: Print "Hi" to terminal
    end
    
    Note over AgentRuntime: Stream complete
    AgentRuntime->>AgentRuntime: getContent() from StreamCollector
    AgentRuntime->>AgentRuntime: Append assistant message to conversation
    AgentRuntime->>AgentRuntime: Check for tool calls
    
    alt No tool calls
        AgentRuntime-->>aeon.zig: Return full response
        aeon.zig-->>CliDialog: Return response
        CliDialog->>User: Print newlines
    else Has tool calls
        Note over AgentRuntime: Execute tools, loop back
    end
```

---

## Streaming Data Flow

This diagram shows how streaming data flows through the callback chain:

```mermaid
flowchart TB
    subgraph "OpenAI API Response"
        SSE["SSE Stream<br/>data: {choices:[{delta:{content:'Hi'}}]}"]
    end

    subgraph "HTTP Layer"
        HC[HttpClient.streamRequest]
        CHUNK["4KB Chunks"]
    end

    subgraph "SSE Parsing"
        SCH[streamChunkHandler]
        SLB[SseLineBuffer.feed]
        HSL[handleSseLine]
    end

    subgraph "Event Dispatch"
        CB1["callback(.text_delta)"]
        CB2["callback(.tool_call)"]
        CB3["callback(.done)"]
    end

    subgraph "Stream Collection"
        SC[StreamCollector.callback]
        GSC[g_stream_collector<br/>Global Pointer]
        TB[text_buf<br/>ArrayList]
        TC[tool_calls<br/>ArrayList]
    end

    subgraph "User Callback"
        OT[on_text callback]
        STD[streamTextDelta]
        OUT[stdout print]
    end

    SSE --> HC
    HC --> CHUNK
    CHUNK --> SCH
    SCH --> SLB
    SLB -->|Complete line| HSL
    
    HSL -->|text delta| CB1
    HSL -->|tool call| CB2
    HSL -->|[DONE]| CB3
    
    CB1 --> SC
    CB2 --> SC
    CB3 --> SC
    
    SC --> GSC
    GSC --> TB
    GSC --> TC
    
    SC -->|text_delta| OT
    OT --> STD
    STD --> OUT

    style GSC fill:#ff9,stroke:#333
    style OUT fill:#9f9,stroke:#333
```

### Why the Global Pointer?

Zig function pointers cannot capture context (no closures). The streaming chain requires passing data through several layers:

```
OpenAI SSE → HttpClient → streamChunkHandler → handleSseLine → callback → StreamCollector
```

Each step uses bare function pointers. To give `StreamCollector.callback` access to its `self`, we use:

```zig
var g_stream_collector: ?*StreamCollector = null;
```

**Critical:** This pointer must be set in the **caller** after `init()` returns, not inside `init()`, because `init()` returns by value and the local's stack address becomes invalid.

---

## Tool Execution Flow

When the LLM decides to call a tool, this flow executes:

```mermaid
flowchart TB
    subgraph "LLM Response"
        RESP[Assistant message with tool_calls]
    end

    subgraph "Detection"
        SC[StreamCollector]
        PTC[PendingToolCall<br/>id, name, arguments]
    end

    subgraph "Execution Loop"
        CHECK{tool_calls.len > 0?}
        EXEC[executeToolCallsFromStream]
        TR[ToolRegistry.executeTool]
        PARSE[Parse JSON arguments]
    end

    subgraph "Built-in Tools"
        FR[file_read<br/>Read file contents]
        FW[file_write<br/>Write to file]
        EX[exec<br/>Shell command]
    end

    subgraph "Result Handling"
        RES[ToolResult<br/>success, output]
        MSG[Create tool message<br/>role: .tool]
        CONV[Append to conversation]
    end

    subgraph "Next Round"
        BUILD[buildMessages]
        LLM[Call LLM again]
    end

    RESP --> SC
    SC --> PTC
    PTC --> CHECK
    
    CHECK -->|Yes| EXEC
    CHECK -->|No| DONE[Return response]
    
    EXEC --> TR
    TR --> PARSE
    
    PARSE --> FR
    PARSE --> FW
    PARSE --> EX
    
    FR --> RES
    FW --> RES
    EX --> RES
    
    RES --> MSG
    MSG --> CONV
    CONV --> BUILD
    BUILD --> LLM
    LLM --> RESP

    style DONE fill:#9f9,stroke:#333
```

### Tool Loop Limits

The `max_tool_rounds` field (default: 10) prevents infinite loops. If the LLM keeps calling tools beyond this limit, the runtime returns `"[Max tool rounds exceeded]"`.

---

## Conversation State Machine

This shows how conversation history evolves:

```mermaid
stateDiagram-v2
    [*] --> Empty: Init
    
    Empty --> HasUser: User message
    
    HasUser --> HasAssistant: LLM responds (no tools)
    HasUser --> HasToolCall: LLM requests tool
    
    HasToolCall --> HasToolResult: Execute tool
    HasToolResult --> HasAssistant: LLM responds (no more tools)
    HasToolResult --> HasToolCall: LLM requests another tool
    
    HasAssistant --> HasUser: Next user message
    
    HasUser --> Empty: /clear command
    HasAssistant --> Empty: /clear command
    HasToolCall --> Empty: /clear command
    HasToolResult --> Empty: /clear command

    note right of HasToolCall
        conversation contains:
        - system (prepended)
        - user messages
        - assistant messages
        - tool call markers
        - tool results
    end note
```

### Message Roles

| Role | Description |
|------|-------------|
| `.system` | System prompt (prepended at each LLM call, not stored in conversation) |
| `.user` | User input from dialog |
| `.assistant` | LLM text response |
| `.tool` | Tool execution result (includes `tool_call_id` and `name`) |

---

## Module Reference

### Entry Point

```
┌─────────────────────────────────────────────────────────────┐
│ aeon.zig                                                    │
├─────────────────────────────────────────────────────────────┤
│ Responsibilities:                                           │
│ • Parse CLI arguments (--version, --help, --config=)        │
│ • Load JSON configuration                                   │
│ • Initialize logger                                         │
│ • Read OPENAI_API_KEY from environment                      │
│ • Create OpenAIClient → LlmClient                           │
│ • Create AgentRuntime with system prompt                    │
│ • Create CliDialog → DialogProvider                         │
│ • Start dialog loop (blocking)                              │
├─────────────────────────────────────────────────────────────┤
│ Globals:                                                    │
│ • g_runtime: ?*AgentRuntime — for handleMessage callback    │
│ • SYSTEM_PROMPT — compile-time string                       │
├─────────────────────────────────────────────────────────────┤
│ Functions:                                                  │
│ • main() — entry point                                      │
│ • handleMessage(InboundMessage) ![]const u8                 │
│ • streamTextDelta([]const u8) !void                         │
└─────────────────────────────────────────────────────────────┘
```

### Dialog Layer

```
┌─────────────────────────────────────────────────────────────┐
│ provider.zig                                                │
├─────────────────────────────────────────────────────────────┤
│ Types:                                                      │
│ • InboundMessage — dialog, from, text, timestamp            │
│ • MessageHandler — fn(InboundMessage) ![]const u8           │
│ • DialogProvider — vtable interface                         │
│ • DialogProvider.VTable — start, send, deinit               │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ cli.zig                                                     │
├─────────────────────────────────────────────────────────────┤
│ Types:                                                      │
│ • CliDialog — allocator, running                            │
├─────────────────────────────────────────────────────────────┤
│ Features:                                                   │
│ • ASCII banner on startup                                   │
│ • "you> " prompt                                            │
│ • Slash commands: /quit, /exit, /clear, /help               │
│ • Byte-by-byte stdin reading (no readUntilDelimiter)        │
│ • Streaming response output                                 │
└─────────────────────────────────────────────────────────────┘
```

### Agent Layer

```
┌─────────────────────────────────────────────────────────────┐
│ runtime.zig                                                 │
├─────────────────────────────────────────────────────────────┤
│ Types:                                                      │
│ • AgentRuntime — main orchestrator                          │
│ • StreamCollector — accumulates stream data                 │
│ • PendingToolCall — buffers for streaming tool calls        │
├─────────────────────────────────────────────────────────────┤
│ AgentRuntime fields:                                        │
│ • allocator, client, tool_registry                          │
│ • conversation (ArrayList of messages)                      │
│ • system_prompt, model, max_tool_rounds                     │
├─────────────────────────────────────────────────────────────┤
│ Key methods:                                                │
│ • processMessage() — non-streaming                          │
│ • processMessageStreaming() — streaming with callback       │
│ • clearHistory() — reset conversation                       │
│ • buildMessages() — prepend system prompt                   │
│ • executeToolCalls() — run tools, append results            │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ tools.zig                                                   │
├─────────────────────────────────────────────────────────────┤
│ Types:                                                      │
│ • ToolRegistry — HashMap of name → RegisteredTool           │
│ • RegisteredTool — definition + execute function            │
│ • ToolResult — success, output, error_msg                   │
│ • ToolContext — allocator, working_dir                      │
│ • ParamDef — helper for parameter definitions               │
├─────────────────────────────────────────────────────────────┤
│ Built-in tools:                                             │
│ • file_read(path) → file contents                           │
│ • file_write(path, content) → success message               │
│ • exec(command) → stdout + stderr                           │
└─────────────────────────────────────────────────────────────┘
```

### LLM Layer

```
┌─────────────────────────────────────────────────────────────┐
│ llm_client.zig                                              │
├─────────────────────────────────────────────────────────────┤
│ Shared Types:                                               │
│ • MessageRole — system, user, assistant, tool               │
│ • Message — role, content, name, tool_call_id               │
│ • Tool, ToolParameter, ToolCall                             │
│ • StreamEvent — text_delta, tool_call, done, error          │
│ • CompletionRequest, CompletionResponse                     │
│ • StreamCallback — fn(StreamEvent) !void                    │
├─────────────────────────────────────────────────────────────┤
│ Interface:                                                  │
│ • LlmClient — vtable-based polymorphic interface            │
│ • LlmClient.VTable — deinit, streamCompletion, completion   │
├─────────────────────────────────────────────────────────────┤
│ Utilities:                                                  │
│ • SseLineBuffer — SSE stream parser                         │
│ • parseSseDataLine() — extract "data: " payload             │
│ • writeJsonEscaped() — JSON string escaping                 │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ openai.zig                                                  │
├─────────────────────────────────────────────────────────────┤
│ Types:                                                      │
│ • OpenAIClient — allocator, api_key, base_url, http_client  │
│ • OpenAIRequest, OpenAIMessage, OpenAITool                  │
├─────────────────────────────────────────────────────────────┤
│ Key methods:                                                │
│ • asLlmClient() — return vtable interface                   │
│ • streamCompletion() — streaming API call                   │
│ • completion() — non-streaming API call                     │
│ • buildRequestBody() — JSON serialization                   │
├─────────────────────────────────────────────────────────────┤
│ SSE handling:                                               │
│ • StreamContext — callback + line buffer                    │
│ • streamChunkHandler() — process HTTP chunks                │
│ • handleSseLine() — parse OpenAI SSE format                 │
└─────────────────────────────────────────────────────────────┘
```

### Infrastructure

```
┌─────────────────────────────────────────────────────────────┐
│ http.zig                                                    │
├─────────────────────────────────────────────────────────────┤
│ Types:                                                      │
│ • HttpClient — wrapper around std.http.Client              │
│ • Response — status, body, allocator                        │
├─────────────────────────────────────────────────────────────┤
│ Methods:                                                    │
│ • post(url, headers, body) → Response                       │
│ • get(url, headers) → Response                              │
│ • streamRequest(method, url, headers, body, ctx, cb) → Status│
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ env.zig                                                     │
├─────────────────────────────────────────────────────────────┤
│ Functions:                                                  │
│ • get(key) → ?[]const u8                                    │
│ • getOrDefault(key, default) → []const u8                   │
│ • getRequired(key) → []const u8 or error                    │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ config.zig                                                  │
├─────────────────────────────────────────────────────────────┤
│ Types:                                                      │
│ • Config — log_file_path, ...                               │
├─────────────────────────────────────────────────────────────┤
│ Methods:                                                    │
│ • loadFromFile(allocator, path) → Config                    │
└─────────────────────────────────────────────────────────────┘
```

---

## Future Architecture (Phase 3+)

```mermaid
graph TB
    subgraph "Dialog Providers"
        CLI[CliDialog]
        TG[TelegramDialog]
        WA[WhatsAppDialog]
    end

    subgraph "Server Layer"
        WS[WebSocket Server]
        RPC[JSON-RPC Handler]
        BC[Event Broadcaster]
    end

    subgraph "Session Layer"
        SM[Session Manager]
        SS[SessionStore]
        DB[(SQLite)]
    end

    subgraph "Agent Layer"
        RT[AgentRuntime]
        TR[ToolRegistry]
    end

    subgraph "LLM Providers"
        OAI[OpenAI]
        ANT[Anthropic]
    end

    CLI --> SM
    TG --> SM
    WA --> SM
    
    WS --> RPC
    RPC --> SM
    RPC --> BC
    
    SM --> SS
    SS --> DB
    SM --> RT
    
    RT --> TR
    RT --> OAI
    RT --> ANT

    classDef future fill:#f9f,stroke:#333,stroke-dasharray: 5 5
    class TG,WA,WS,RPC,BC,SM,SS,DB,ANT future
```

This shows planned components for Phase 3 (Server/Sessions) and Phase 4 (Telegram).
