const std = @import("std");
const log = std.log.default;
const c = @import("c.zig");

pub fn main() anyerror!void {
    const display = c.wl_display_connect(null) orelse {
        log.err("Unable to connect to Wayland display", .{});
        std.os.exit(1);
    };

    log.info("Connection established!", .{});

    c.wl_display_disconnect(display);
}
