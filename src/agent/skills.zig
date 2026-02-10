const std = @import("std");

// ─────────────────────────────────────────────────────────────
// Skill Loader — loads skill documents from the skills directory
// ─────────────────────────────────────────────────────────────

/// Load all skill markdown files and combine into a single prompt section
pub fn loadSkills(allocator: std.mem.Allocator, skills_path: []const u8) ![]const u8 {
    var skills_content: std.ArrayList(u8) = .{};
    defer skills_content.deinit(allocator);

    const writer = skills_content.writer(allocator);

    // Try to open the skills directory
    var dir = std.fs.cwd().openDir(skills_path, .{ .iterate = true }) catch |err| {
        // Directory doesn't exist or can't be opened — return empty
        std.debug.print("Note: Could not open skills directory '{s}': {}\n", .{ skills_path, err });
        return try allocator.dupe(u8, "");
    };
    defer dir.close();

    try writer.writeAll("\n\n# Your Skills\n\n");
    try writer.writeAll("You have the following skills. Use them to help users:\n\n");

    var file_count: u32 = 0;

    // Iterate through all .md files
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;

        // Read the skill file
        const file = dir.openFile(entry.name, .{}) catch continue;
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
        return try allocator.dupe(u8, "");
    }

    try writer.writeAll("---\n");

    return try skills_content.toOwnedSlice(allocator);
}

/// Default skills path relative to executable
pub const DEFAULT_SKILLS_PATH = "skills";
