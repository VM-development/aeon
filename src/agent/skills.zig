const std = @import("std");

// ─────────────────────────────────────────────────────────────
// Skill Loader — loads skill documents from the skills directory
// ─────────────────────────────────────────────────────────────

/// Result of loading skills - contains content and whether it was allocated
pub const SkillsResult = struct {
    content: []const u8,
    allocated: bool,

    pub fn deinit(self: *const SkillsResult, allocator: std.mem.Allocator) void {
        if (self.allocated and self.content.len > 0) {
            allocator.free(self.content);
        }
    }
};

/// Load all skill markdown files and combine into a single prompt section
/// Returns a SkillsResult indicating if content was allocated
pub fn loadSkills(allocator: std.mem.Allocator, skills_path: []const u8) !SkillsResult {
    // Try to open the skills directory
    var dir = std.fs.cwd().openDir(skills_path, .{ .iterate = true }) catch |err| {
        // Directory doesn't exist or can't be opened — return empty (not allocated)
        std.debug.print("Note: Could not open skills directory '{s}': {}\n", .{ skills_path, err });
        return .{ .content = "", .allocated = false };
    };
    defer dir.close();

    // Collect and sort file names for deterministic order
    var file_names: std.ArrayList([]const u8) = .{};
    defer {
        for (file_names.items) |name| {
            allocator.free(name);
        }
        file_names.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        try file_names.append(allocator, try allocator.dupe(u8, entry.name));
    }

    if (file_names.items.len == 0) {
        return .{ .content = "", .allocated = false };
    }

    // Sort file names for deterministic order
    std.mem.sort([]const u8, file_names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var skills_content: std.ArrayList(u8) = .{};
    defer skills_content.deinit(allocator);

    const writer = skills_content.writer(allocator);

    try writer.writeAll("\n\n# Your Skills\n\n");
    try writer.writeAll("You have the following skills. Use them to help users:\n\n");

    var file_count: u32 = 0;

    for (file_names.items) |name| {
        // Read the skill file
        const file = dir.openFile(name, .{}) catch continue;
        defer file.close();

        const stat = file.stat() catch continue;
        if (stat.size > 50 * 1024) continue; // Skip files > 50KB

        const content = allocator.alloc(u8, stat.size) catch continue;
        defer allocator.free(content);

        const bytes_read = file.readAll(content) catch continue;

        // Add separator and content
        try writer.writeAll("---\n\n");
        try writer.writeAll(content[0..bytes_read]);
        try writer.writeAll("\n\n");

        file_count += 1;
    }

    if (file_count == 0) {
        return .{ .content = "", .allocated = false };
    }

    try writer.writeAll("---\n");

    return .{ .content = try skills_content.toOwnedSlice(allocator), .allocated = true };
}

/// Default skills path relative to executable
pub const DEFAULT_SKILLS_PATH = "skills";
