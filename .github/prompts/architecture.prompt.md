# Plan: Simplified ai assistant

Here's a comprehensive plan for building a simplified, embedded-friendly AI assistant in Zig.

---

## **Core Features Required**

### 1. **Server/Control Plane** (Simplified)
- WebSocket server for client connections
- Simple JSON-RPC protocol (not TypeBox schemas)
- Configuration management (JSON-based, similar to current aeon.json)
- Session management (conversation history per user/dialog)

### 2. **Agent Runtime** (Lightweight)
- Message processing pipeline
- LLM API integration (Anthropic/OpenAI via HTTP)
- Basic streaming support
- Tool execution framework

### 3. **Dialog Providers** (Start Small)
- Telegram (highest priority - simple HTTP bot API)
- WhatsApp (if resources allow - via webhooks)
- Local CLI interface (for testing)

### 4. **Tool System**
- File operations (read/write)
- System commands (exec)
- Basic message sending
- Extensible tool registry

### 5. **Memory/Storage**
- SQLite for session persistence
- Optional: Simple vector search (later phase)
- File-based config storage

---

## **Architecture Design (Zig-Native)**

### **Project Structure**
```
aeon/
├── src/
│   ├── aeon.zig              # Main entry point
│   ├── core/
│   │   ├── server.zig        # WebSocket server + protocol
│   │   ├── session.zig       # Session management
│   │   ├── config.zig        # Configuration (already exists)
│   │   └── logger.zig        # Logging (already exists)
│   ├── agent/
│   │   ├── runtime.zig       # Agent execution pipeline
│   │   ├── llm_client.zig    # HTTP client for LLM APIs
│   │   ├── streaming.zig     # Stream processing
│   │   └── tools.zig         # Tool registry & execution
│   ├── dialogs/
│   │   ├── telegram.zig      # Telegram dialog provider
│   │   ├── cli.zig           # CLI interface (already exists)
│   │   └── provider.zig      # Dialog provider interface definition
│   ├── storage/
│   │   ├── sqlite.zig        # SQLite wrapper
│   │   └── sessions.zig      # Session persistence
│   └── utils/
│       ├── http.zig          # HTTP client utilities
│       ├── json.zig          # JSON parsing helpers
│       └── utils.zig         # General utilities (already exists)
├── build.zig
├── build.zig.zon
└── aeon.json                  # Default config
```

### **Key Architectural Decisions**

1. **Single-Process Design**
   - No microservices - simplifies embedded deployment
   - Event loop for async I/O
   - Session isolation via data structures, not processes

2. **Minimal Dependencies**
   - Zig std library for most operations
   - SQLite (via C binding) for persistence
   - No Node.js runtime required

3. **Memory Efficiency**
   - Arena allocators for request-scoped memory
   - GeneralPurposeAllocator for long-lived objects
   - Fixed-size buffers where possible

4. **Protocol Simplification**
   - JSON-RPC over WebSocket (not TypeBox schemas)
   - Simple frame format: `{ "id", "method", "params" }`
   - Binary protocol option for very constrained devices (future)

---

### **File Naming**
- **snake_case** for files: `llm_client.zig`, `session_store.zig`
- **PascalCase** for types: `Server`, `TelegramDialog`, `SessionStore`
- **camelCase** for functions: `createSession`, `sendMessage`, `executeToolchain`
- **SCREAMING_SNAKE_CASE** for constants: `DEFAULT_PORT`, `MAX_MESSAGE_SIZE`

### **Module Organization**
```zig
// core/server.zig
pub const Server = struct { ... };
pub fn createServer(allocator, config) !*Server { ... }

// dialogs/telegram.zig  
pub const TelegramDialog = struct { ... };
pub fn createTelegramDialog(allocator, config) !*TelegramDialog { ... }

// agent/runtime.zig
pub const AgentRuntime = struct { ... };
pub fn executeAgent(runtime, message) !Response { ... }
```

---

## **Implementation Phases**

### **Phase 1: Foundation**
- [x] CLI argument parsing
- [x] JSON config loading
- [x] Logging system

### **Phase 2: Agent Core**
- [x] HTTP client (for LLM APIs)
- [x] LLM client types and interface
- [x] OpenAI client implementation
- [x] Message processing pipeline
- [x] Basic streaming support
- [x] Tool registry
- [x] Tool execution (file read/write, exec)

### **Phase 2.5: Dialogs**
- [x] Dialog provider interface
- [x] CLI dialog provider

### **Phase 3: Server**
- [ ] Session storage (file-based, SQLite, ability to add different storages)
- [ ] WebSocket server
- [ ] JSON-RPC protocol handler
- [ ] Client connection management
- [ ] Event broadcasting

### **Phase 4: Telegram Integration**
- [ ] Telegram Bot API client
- [ ] Webhook handling
- [ ] Dialog provider implementation
- [ ] Media handling (images/audio)

### **Phase 5: Polish & Testing**
- [ ] Error handling improvements
- [ ] Memory leak fixes
- [ ] Performance optimization
- [ ] Documentation
- [ ] Docker image for deployment


### **Features**
- [ ] Anthropic client implementation

---

## **Configuration Example**

```json
{
  "log_file_path": "~/.aeon/logs/aeon.log",
  "server": {
    "port": 7777,
    "host": "127.0.0.1"
  },
  "agents": {
    "main": {
      "provider": "anthropic",
      "model": "claude-sonnet-4-20250514",
      "api_key": "${ANTHROPIC_API_KEY}",
      "max_tokens": 4096
    }
  },
  "dialogs": {
    "telegram": {
      "enabled": true,
      "bot_token": "${TELEGRAM_BOT_TOKEN}",
      "allowed_users": [123456789]
    }
  },
  "storage": {
    "sessions_db": "~/.aeon/sessions.db"
  }
}
```

---

## **Detailed Component Specifications**

### **Server**

**Responsibilities:**
- Accept WebSocket connections on configured port
- Parse JSON-RPC requests
- Route requests to appropriate handlers
- Broadcast events to connected clients
- Manage client lifecycle

**Protocol Frame Format:**
```json
// Request
{
  "id": "req-uuid-123",
  "method": "agent.send",
  "params": {
    "message": "Hello",
    "sessionKey": "agent:main:telegram:123456"
  }
}

// Response
{
  "id": "req-uuid-123",
  "type": "response",
  "payload": { "ok": true }
}

// Event
{
  "id": "evt-uuid-456",
  "type": "event",
  "event": "agent.delta",
  "data": { "text": "Hello..." }
}

// Error
{
  "id": "req-uuid-123",
  "type": "error",
  "code": "INVALID_REQUEST",
  "message": "Missing required parameter 'message'"
}
```

**Implementation Notes:**
- Use `std.http.Server` for WebSocket upgrade
- Maintain `Map<ClientId, WebSocket>` for broadcasting
- Thread-safe message queue for async operations

---

### **Agent Runtime**

**Execution Pipeline:**
1. **Receive Message** → Parse input, resolve session
2. **Load Context** → Fetch conversation history from DB
3. **Build Prompt** → Construct system prompt + user message + tools
4. **Call LLM** → HTTP request to Anthropic/OpenAI
5. **Process Stream** → Handle text deltas and tool calls
6. **Execute Tools** → Run requested tools, collect results
7. **Save Session** → Persist updated conversation history
8. **Deliver Response** → Send to dialog provider

**LLM Client Interface:**
```zig
pub const LlmClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    base_url: []const u8,
    
    pub fn init(allocator: std.mem.Allocator, config: LlmConfig) !*LlmClient;
    pub fn deinit(self: *LlmClient) void;
    
    pub fn streamCompletion(
        self: *LlmClient,
        request: CompletionRequest,
        callback: StreamCallback,
    ) !void;
};

pub const CompletionRequest = struct {
    model: []const u8,
    messages: []Message,
    tools: ?[]Tool,
    max_tokens: u32,
    temperature: f32 = 1.0,
};

pub const StreamCallback = *const fn(event: StreamEvent) void;

pub const StreamEvent = union(enum) {
    text_delta: []const u8,
    tool_call: ToolCall,
    done: void,
    error: []const u8,
};
```

---

### **Session Management**

**Session Key Format:**
```
agent:<agentId>:<dialog>:<userId>
Examples:
  agent:main:telegram:123456789
  agent:main:cli:local
  agent:support:whatsapp:+1234567890
```

**Session Store Schema (SQLite):**
```sql
CREATE TABLE sessions (
  session_key TEXT PRIMARY KEY,
  agent_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_key TEXT NOT NULL,
  role TEXT NOT NULL, -- 'user', 'assistant', 'tool'
  content TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  metadata TEXT, -- JSON blob
  FOREIGN KEY (session_key) REFERENCES sessions(session_key)
);

CREATE INDEX idx_messages_session ON messages(session_key, timestamp);
```

**Session API:**
```zig
pub const SessionStore = struct {
    db: *sqlite.Database,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) !*SessionStore;
    pub fn deinit(self: *SessionStore) void;
    
    pub fn getSession(self: *SessionStore, key: []const u8) !?Session;
    pub fn saveMessage(self: *SessionStore, key: []const u8, msg: Message) !void;
    pub fn getHistory(self: *SessionStore, key: []const u8, limit: u32) ![]Message;
};
```

---

### **Tool System**

**Tool Interface:**
```zig
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters: ToolParameters,
    execute: *const fn(params: std.json.Value, ctx: ToolContext) anyerror!ToolResult,
};

pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    session_key: []const u8,
    config: *Config,
};

pub const ToolResult = struct {
    success: bool,
    output: []const u8,
    error_msg: ?[]const u8 = null,
};

pub const ToolRegistry = struct {
    tools: std.StringHashMap(Tool),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) !*ToolRegistry;
    pub fn deinit(self: *ToolRegistry) void;
    
    pub fn register(self: *ToolRegistry, tool: Tool) !void;
    pub fn get(self: *ToolRegistry, name: []const u8) ?Tool;
    pub fn list(self: *ToolRegistry) []Tool;
};
```

**Built-in Tools:**
1. **file_read** - Read file contents
2. **file_write** - Write to file
3. **exec** - Execute shell command
4. **message_send** - Send message to dialog

---

### **Dialog Providers**

**Provider Interface:**
```zig
pub const DialogProvider = struct {
    name: []const u8,
    
    // Initialize provider with config
    initFn: *const fn(allocator: std.mem.Allocator, config: std.json.Value) anyerror!*anyopaque,
    
    // Start listening for incoming messages
    startFn: *const fn(self: *anyopaque, handler: MessageHandler) anyerror!void,
    
    // Send message to dialog
    sendFn: *const fn(self: *anyopaque, to: []const u8, message: []const u8) anyerror!void,
    
    // Cleanup
    deinitFn: *const fn(self: *anyopaque) void,
};

pub const InboundMessage = struct {
    dialog: []const u8,
    from: []const u8,
    text: []const u8,
    timestamp: i64,
};

pub const MessageHandler = *const fn(msg: InboundMessage) void;
```

**Telegram Dialog Implementation:**
```zig
pub const TelegramDialog = struct {
    allocator: std.mem.Allocator,
    bot_token: []const u8,
    allowed_users: []i64,
    webhook_url: ?[]const u8,
    
    pub fn init(allocator: std.mem.Allocator, config: TelegramConfig) !*TelegramDialog;
    pub fn deinit(self: *TelegramDialog) void;
    
    pub fn startPolling(self: *TelegramDialog, handler: MessageHandler) !void;
    pub fn sendMessage(self: *TelegramDialog, chat_id: i64, text: []const u8) !void;
};
```

---

## **Memory Budget for Embedded Devices**

**Target Device: Raspberry Pi Zero W**
- RAM: 512MB
- Storage: 8GB SD card
- CPU: 1GHz single-core ARM

**Memory Allocation Strategy:**
```
Total Available: 512MB
├── System/OS: ~200MB
├── Aeon Runtime: ~100MB
│   ├── Server: 20MB
│   ├── Agent Runtime: 30MB
│   ├── Dialog Providers: 15MB
│   ├── Session Store: 20MB
│   └── Tool Registry: 15MB
├── SQLite: ~50MB
└── Buffer/Free: ~162MB
```

**Optimization Techniques:**
1. Use arena allocators for request-scoped memory
2. Limit session history to last 50 messages
3. Stream LLM responses instead of buffering
4. Use fixed-size message buffers (4KB default)
5. Compact sessions periodically

---

## **Next Steps**

1. **Review this plan** - Does this align with your vision?
2. **Choose Phase 1 tasks** - Start with HTTP client or SQLite?
3. **Define protocols** - Finalize WebSocket frame format
4. **LLM API priority** - Anthropic-first or OpenAI-first?

**Recommended Starting Point:**
Implement HTTP client for LLM API calls first, as it's:
- Self-contained and testable
- Required for agent runtime
- Good intro to async I/O in Zig
- Can be tested independently with curl/Postman

**Initial Implementation Order:**
1. HTTP client (with TLS support)
2. Anthropic API client (simpler than OpenAI)
3. Basic streaming parser
4. SQLite integration
5. Session store
6. Simple CLI chat loop (no gateway yet)
