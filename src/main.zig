const std = @import("std");
const log = std.log.default;
const build_options = @import("build_options");
const c = @import("c.zig");

const program_name = build_options.program_name;

const WaylandState = struct {
    wl_display: ?*c.wl_display = null,
    wl_registry: ?*c.wl_registry = null,
    wl_shm: ?*c.wl_shm = null,
    wl_compositor: ?*c.wl_compositor = null,
    xdg_wm_base: ?*c.xdg_wm_base = null,
    wl_surface: ?*c.wl_surface = null,
    xdg_surface: ?*c.xdg_surface = null,
    xdg_toplevel: ?*c.xdg_toplevel = null,
};

fn random_name(buffer: []u8) void {
    var timestamp = std.time.nanoTimestamp();
    for (buffer) |*buf| {
        buf.* = 'A' + @intCast(u8, (timestamp & 0xf) + (timestamp & 0x10) * 2);
        timestamp >>= 5;
    }
}

fn create_shm_file() !i32 {
    const base_path = "/dev/shm/wl_shm-";
    var file_path: [base_path.len + "XXXXXX".len]u8 = undefined;
    std.mem.copy(u8, &file_path, base_path);

    var retries: usize = 100;
    return blk: while (retries > 0) : (retries -= 1) {
        random_name(file_path[base_path.len..]);
        var fd = std.os.open(
            &file_path,
            std.os.O.RDWR | std.os.O.CREAT | std.os.O.EXCL | std.os.O.NOFOLLOW | std.os.O.CLOEXEC,
            0600,
        ) catch |e| {
            if (e == error.PathAlreadyExists) continue;
            break :blk e;
        };

        try std.os.unlink(&file_path);
        break :blk fd;
    } else error.TooManyRetries;
}

fn wlBufferRelease(_: ?*c_void, wl_buffer: ?*c.wl_buffer) callconv(.C) void {
    c.wl_buffer_destroy(wl_buffer);
}

const wl_buffer_listener = c.wl_buffer_listener{
    .release = wlBufferRelease,
};

fn drawFrame(state: *WaylandState) !?*c.wl_buffer {
    const width = 1920;
    const height = 1080;
    const stride = width * 4;
    const size = height * stride;

    const shm_fd = try create_shm_file();
    defer std.os.close(shm_fd);

    try std.os.ftruncate(shm_fd, size);
    var data = try std.os.mmap(
        null,
        size,
        std.os.PROT.READ | std.os.PROT.WRITE,
        std.os.MAP.SHARED,
        shm_fd,
        0,
    );
    defer std.os.munmap(data);

    const pool = c.wl_shm_create_pool(state.wl_shm, shm_fd, size);
    defer c.wl_shm_pool_destroy(pool);

    const buffer = c.wl_shm_pool_create_buffer(
        pool,
        0,
        width,
        height,
        stride,
        c.WL_SHM_FORMAT_ARGB8888,
    );

    var pixels = std.mem.bytesAsSlice(u32, data);
    for (pixels) |*pixel| pixel.* = 0x33ff00ff;

    _ = c.wl_buffer_add_listener(buffer, &wl_buffer_listener, null);

    return buffer;
}

fn xdgSurfaceConfigure(data: ?*c_void, xdg_surface: ?*c.xdg_surface, serial: u32) callconv(.C) void {
    var state = @ptrCast(*WaylandState, @alignCast(@alignOf(WaylandState), data));

    c.xdg_surface_ack_configure(xdg_surface, serial);

    const buffer = drawFrame(state) catch unreachable;
    c.wl_surface_attach(state.wl_surface, buffer, 0, 0);
    c.wl_surface_commit(state.wl_surface);
    // c.wl_surface_damage(surface, 0, 0, width, height);
}

const xdg_surface_listener = c.xdg_surface_listener{
    .configure = xdgSurfaceConfigure,
};

fn xdgWmBasePing(_: ?*c_void, xdg_wm_base: ?*c.xdg_wm_base, serial: u32) callconv(.C) void {
    c.xdg_wm_base_pong(xdg_wm_base, serial);
}

const xdg_wm_base_listener = c.xdg_wm_base_listener{
    .ping = xdgWmBasePing,
};

fn registryHandleGlobal(
    data: ?*c_void,
    registry: ?*c.wl_registry,
    name: u32,
    interface: [*c]const u8,
    version: u32,
) callconv(.C) void {
    if (false)
        log.info("interface: '{s}', version: {d}, name {d}", .{ interface, version, name });

    var state = @ptrCast(*WaylandState, @alignCast(@alignOf(WaylandState), data));

    const interface_slice = std.mem.span(interface);

    const compositor_slice = std.mem.span(c.wl_compositor_interface.name);
    const shm_slice = std.mem.span(c.wl_shm_interface.name);
    const xdg_wm_base_slice = std.mem.span(c.xdg_wm_base_interface.name);

    if (std.mem.eql(u8, interface_slice, compositor_slice)) {
        state.wl_compositor = @ptrCast(*c.wl_compositor, c.wl_registry_bind(
            registry,
            name,
            &c.wl_compositor_interface,
            version,
        ));
    } else if (std.mem.eql(u8, interface_slice, shm_slice)) {
        state.wl_shm = @ptrCast(*c.wl_shm, c.wl_registry_bind(
            registry,
            name,
            &c.wl_shm_interface,
            version,
        ));
    } else if (std.mem.eql(u8, interface_slice, xdg_wm_base_slice)) {
        state.xdg_wm_base = @ptrCast(*c.xdg_wm_base, c.wl_registry_bind(
            registry,
            name,
            &c.xdg_wm_base_interface,
            version,
        ));

        // TODO: See what happens if I put `null` here
        _ = c.xdg_wm_base_add_listener(state.xdg_wm_base, &xdg_wm_base_listener, null);
    }
}

fn registryHandleGlobalRemove(_: ?*c_void, _: ?*c.wl_registry, _: u32) callconv(.C) void {
    // NOTE: Do nothing
}

const wl_registry_listener = c.wl_registry_listener{
    .global = registryHandleGlobal,
    .global_remove = registryHandleGlobalRemove,
};

pub fn main() anyerror!void {
    var state = WaylandState{};

    state.wl_display = c.wl_display_connect(null) orelse {
        log.err("Unable to connect to Wayland display", .{});
        std.os.exit(1);
    };

    state.wl_registry = c.wl_display_get_registry(state.wl_display);
    _ = c.wl_registry_add_listener(state.wl_registry, &wl_registry_listener, &state);
    _ = c.wl_display_roundtrip(state.wl_display);

    if (state.wl_compositor) |_| {} else {
        log.err("Unable to get wl_compositor", .{});
        std.os.exit(1);
    }

    if (state.wl_shm) |_| {} else {
        log.err("Unable to get wl_shm", .{});
        std.os.exit(1);
    }

    if (state.xdg_wm_base) |_| {} else {
        log.err("Unable to get xdg_wm_base", .{});
        std.os.exit(1);
    }

    state.wl_surface = c.wl_compositor_create_surface(state.wl_compositor);
    state.xdg_surface = c.xdg_wm_base_get_xdg_surface(state.xdg_wm_base, state.wl_surface);
    _ = c.xdg_surface_add_listener(state.xdg_surface, &xdg_surface_listener, &state);

    state.xdg_toplevel = c.xdg_surface_get_toplevel(state.xdg_surface);
    c.xdg_toplevel_set_title(state.xdg_toplevel, program_name);
    c.wl_surface_commit(state.wl_surface);

    while (c.wl_display_dispatch(state.wl_display) != 0) {
        // NOTE: Do nothing
    }

    c.wl_display_disconnect(state.wl_display);
}
