const std = @import("std");
const Allocator = std.mem.Allocator;
const phantom = @import("phantom");
const fio = @import("fio");
const vizops = @import("vizops");
const Self = @This();

pub const Config = extern struct {
    addr: u64 align(1),
    fourcc: u32 align(1),
    flags: u32 align(1),
    width: u32 align(1),
    height: u32 align(1),
    stride: u32 align(1),

    pub fn init(addr: u64, fourcc: u32, flags: u32, size: vizops.vector.UsizeVector2) !Config {
        const colorFormat = try vizops.color.fourcc.Value.decode(fourcc);

        return .{
            .addr = std.mem.nativeTo(u64, addr, .big),
            .fourcc = fourcc,
            .flags = std.mem.nativeTo(u32, flags, .big),
            .width = std.mem.nativeTo(u32, @intCast(size.value[0]), .big),
            .height = std.mem.nativeTo(u32, @intCast(size.value[1]), .big),
            .stride = std.mem.nativeTo(u32, @intCast(size.value[0] * @divExact(colorFormat.width(), 8)), .big),
        };
    }

    pub fn format(self: Config, comptime _: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.writeAll(@typeName(Config));

        try writer.writeAll("{ .addr = 0x");
        try std.fmt.formatInt(std.mem.toNative(u64, self.addr, .big), 16, .lower, options, writer);

        try writer.writeAll(", .fourcc = ");
        try std.fmt.formatType(vizops.color.fourcc.Value.decode(self.fourcc), "!", options, writer, 3);

        try writer.writeAll(", .flags = ");
        try std.fmt.formatInt(std.mem.toNative(u32, self.flags, .big), 10, .lower, options, writer);

        try writer.writeAll(", .width = ");
        try std.fmt.formatInt(std.mem.toNative(u32, self.width, .big), 10, .lower, options, writer);

        try writer.writeAll(", .height = ");
        try std.fmt.formatInt(std.mem.toNative(u32, self.height, .big), 10, .lower, options, writer);

        try writer.writeAll(", .stride = ");
        try std.fmt.formatInt(std.mem.toNative(u32, self.stride, .big), 10, .lower, options, writer);

        try writer.writeAll(" }");
    }
};

pub const Options = struct {
    fwcfg: fio.FwCfg,
    fwcfgName: ?[]const u8 = null,
    displayKind: ?phantom.display.Base.Kind = null,
    res: vizops.vector.UsizeVector2,
    fourcc: vizops.color.fourcc.Value,
    scale: vizops.vector.Float32Vector2 = vizops.vector.Float32Vector2.init(1.0),
};

base: phantom.display.Surface,
fwcfg: fio.FwCfg,
fwcfgName: []const u8,
fb: *phantom.painting.fb.Base,
scale: vizops.vector.Float32Vector2,
scene: ?*phantom.scene.Base,

pub fn new(alloc: Allocator, options: Options) !*phantom.display.Surface {
    const fileAccess = try options.fwcfg.accessFile(options.fwcfgName orelse "etc/ramfb");

    const fb = try phantom.painting.fb.AllocatedFrameBuffer.create(alloc, .{
        .res = options.res,
        .colorspace = .sRGB,
        .colorFormat = try vizops.color.fourcc.Value.decode(options.fourcc),
    });
    errdefer fb.deinit();

    var cfg = try Config.init(try fb.addr(), options.fourcc, 0, options.res);
    try fileAccess.write(std.mem.asBytes(&cfg));
    cfg.addr = 0;
    try fileAccess.read(std.mem.asBytes(&cfg));

    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);

    self.* = .{
        .base = .{
            .ptr = self,
            .vtable = &.{
                .deinit = deinit,
                .destroy = destroy,
                .info = info,
                .updateInfo = updateInfo,
                .createScene = createScene,
            },
            .displayKind = options.displayKind orelse .compositor,
            .type = @typeName(Self),
        },
        .fwcfg = options.fwcfg,
        .fwcfgName = options.fwcfgName orelse "etc/ramfb",
        .fb = fb,
        .scale = options.scale,
        .scene = null,
    };
    return &self.base;
}

fn deinit(ctx: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    const alloc = self.fb.allocator;
    if (self.scene) |scene| scene.deinit();
    self.fb.deinit();
    alloc.destroy(self);
}

fn destroy(ctx: *anyopaque) anyerror!void {
    _ = ctx;
}

fn info(ctx: *anyopaque) anyerror!phantom.display.Surface.Info {
    const self: *Self = @ptrCast(@alignCast(ctx));
    const fbInfo = self.fb.info();
    return .{
        .colorFormat = fbInfo.colorFormat,
        .size = fbInfo.size,
    };
}

fn updateInfo(ctx: *anyopaque, i: phantom.display.Surface.Info, fields: []std.meta.FieldEnum(phantom.display.Surface.Info)) anyerror!void {
    _ = ctx;
    _ = i;
    _ = fields;
    return error.NotImplemented;
}

fn createScene(ctx: *anyopaque, backendType: phantom.scene.BackendType) anyerror!*phantom.scene.Base {
    const self: *Self = @ptrCast(@alignCast(ctx));

    if (self.scene) |scene| return scene;

    const fbInfo = self.fb.info();
    self.scene = try phantom.scene.createBackend(backendType, .{
        .allocator = self.fb.allocator,
        .frame_info = phantom.scene.Node.FrameInfo.init(.{
            .res = fbInfo.res,
            .colorFormat = fbInfo.colorFormat,
            .scale = self.scale,
        }),
        .target = .{ .fb = self.fb },
    });
    return self.scene.?;
}
