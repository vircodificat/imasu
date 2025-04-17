// Devicetree structure and binary (dtb/fdt) emitter
// See https://www.devicetree.org/specifications

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const DT = @This();

name: []const u8, // name of the node
children: std.ArrayListUnmanaged(DT), // children nodes
properties: std.StringArrayHashMapUnmanaged(Value),

// devicetree property value types
const Value = union(enum) {
    bool: void, // boolean values are zero-sized (true if present)
    strings: []const []const u8, // array of strings
    u32s: []const u32, // array of u32s
    u64s: []const u64, // array of u64s
};

pub fn create_node(name: []const u8) DT {
    return DT{
        .name = name,
        .children = std.ArrayListUnmanaged(DT).empty,
        .properties = std.StringArrayHashMapUnmanaged(Value).empty,
    };
}

pub fn add_child(
    parent: *DT,
    child: DT,
    a: Allocator,
) !void {
    try parent.children.append(a, child);
}

// recursively deinitialise the tree of nodes from the current node
pub fn deinit_tree(node: *DT, a: Allocator) void {
    for (node.children.items) |*child| {
        child.deinit_tree(a);
    }
    node.children.deinit(a);
    node.properties.deinit(a);
}

pub inline fn add_bool_prop(
    node: *DT,
    name: []const u8,
    a: Allocator,
) !void {
    try node.properties.put(a, name, .{ .bool = {} });
}

pub inline fn add_u32_prop(
    node: *DT,
    name: []const u8,
    v: u32,
    a: Allocator,
) !void {
    try node.properties.put(a, name, .{ .u32s = &.{v} });
}

pub inline fn add_u32_array_prop(
    node: *DT,
    name: []const u8,
    v: []const u32,
    a: Allocator,
) !void {
    try node.properties.put(a, name, .{ .u32s = v });
}

pub inline fn add_u64_prop(
    node: *DT,
    name: []const u8,
    v: u64,
    a: Allocator,
) !void {
    try node.properties.put(a, name, .{ .u64s = &.{v} });
}

pub inline fn add_u64_array_prop(
    node: *DT,
    name: []const u8,
    v: []const u64,
    a: Allocator,
) !void {
    try node.properties.put(a, name, .{ .u64s = v });
}

pub inline fn add_string_prop(
    node: *DT,
    name: []const u8,
    v: []const u8,
    a: Allocator,
) !void {
    try node.properties.put(a, name, .{ .strings = &.{v} });
}

pub inline fn add_string_array_prop(
    node: *DT,
    name: []const u8,
    v: []const []const u8,
    a: Allocator,
) !void {
    try node.properties.put(a, name, .{ .strings = v });
}

const Buffer = std.ArrayList(u8);

// dtb tokens
const TOKEN_BEGIN_NODE: u32 = 0x1;
const TOKEN_END_NODE: u32 = 0x2;
const TOKEN_PROP: u32 = 0x3;
const TOKEN_NOP: u32 = 0x4;
const TOKEN_END: u32 = 0x9;

// emit u32, big-endian
inline fn emit_u32(value: u32, buffer: *Buffer) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..bytes.len], value, .big);
    try buffer.appendSlice(bytes[0..bytes.len]);
}

// emit u32, big-endian
inline fn emit_u64(value: u64, buffer: *Buffer) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..bytes.len], value, .big);
    try buffer.appendSlice(bytes[0..bytes.len]);
}

// emit array of u32s, big-endian
inline fn emit_u32s(values: []const u32, buffer: *Buffer) !void {
    for (values) |v| {
        try emit_u32(v, buffer);
    }
}

// emit array of u64s, big-endian
inline fn emit_u64s(values: []const u64, buffer: *Buffer) !void {
    for (values) |v| {
        try emit_u64(v, buffer);
    }
}

// emit array of null-terminated strings
inline fn emit_strings(values: []const []const u8, buffer: *Buffer) !void {
    for (values) |v| {
        try buffer.appendSlice(v);
        try buffer.append(0); // null-terminate
    }
}

// pad buffer to a multiple of 4 bytes
inline fn pad_to_4bytes(buffer: *Buffer) !void {
    if (buffer.items.len % 4 == 0) return;
    try buffer.appendNTimes(0, 4 - (buffer.items.len % 4));
    assert(buffer.items.len % 4 == 0);
}

inline fn property_value_len(v: *const Value) u32 {
    return @intCast(switch (v.*) {
        .bool => 0,
        .strings => |arr| blk: {
            var len: usize = 0;
            for (arr) |*str| len += str.len + 1;
            break :blk len;
        },
        .u32s => |arr| 4 * arr.len,
        .u64s => |arr| 8 * arr.len,
    });
}

// emit a property value
inline fn emit_property_value(v: *const Value, buffer: *Buffer) !void {
    switch (v.*) {
        .bool => {},
        .strings => |str| try emit_strings(str, buffer),
        .u32s => |arr| try emit_u32s(arr, buffer),
        .u64s => |arr| try emit_u64s(arr, buffer),
    }
}

// emit a property
// starts with a PROP token, then
// the length of the property value in bytes,
// an offset into the string table for the property name,
// the bytes of the value of the property,
// and then padded to the next multiple of 4 bytes
inline fn emit_property(nameoff: u32, value: Value, buffer: *Buffer) !void {
    try emit_u32(TOKEN_PROP, buffer);
    try emit_u32(property_value_len(&value), buffer);
    try emit_u32(nameoff, buffer);
    try emit_property_value(&value, buffer);
    try pad_to_4bytes(buffer);
}

// traverse the tree and collect all the property strings present
fn collect_property_names(node: *const DT, a: Allocator) ![][]const u8 {
    var string_set = std.StringHashMap(void).init(a);
    var queue = std.ArrayList(*const DT).init(a);
    errdefer string_set.deinit();
    errdefer queue.deinit();
    defer string_set.deinit();
    defer queue.deinit();

    try queue.append(node);
    while (queue.pop()) |n| {
        for (n.children.items) |*child| {
            try queue.append(child);
        }
        for (n.properties.keys()) |str| {
            try string_set.put(str, {});
        }
    }

    var string_list = std.ArrayList([]const u8).init(a);
    var iter = string_set.keyIterator();
    while (iter.next()) |str| {
        try string_list.append(str.*);
    }

    return try string_list.toOwnedSlice();
}

// emit a node and its children recursively
// nodes begin with a BEGIN_NODE token,
// null-terminated string name padded to a multiple of 4 bytes,
// followed by all the node's properties,
// and then recursive calls for all the children of the node,
// and an END_NODE token
fn emit_node(
    node: *const DT,
    buffer: *Buffer,
    prop_map: *const std.StringHashMap(u32),
) !void {
    try emit_u32(TOKEN_BEGIN_NODE, buffer);
    try buffer.appendSlice(node.name);
    try buffer.append(0);
    try pad_to_4bytes(buffer);
    var iter = node.properties.iterator();
    while (iter.next()) |prop| {
        try emit_property(
            prop_map.get(prop.key_ptr.*) orelse unreachable,
            prop.value_ptr.*,
            buffer,
        );
    }
    for (node.children.items) |child| {
        try child.emit_node(buffer, prop_map);
    }
    try emit_u32(TOKEN_END_NODE, buffer);
}

pub fn emit_dtb(root_node: *const DT, a: Allocator) ![]u8 {
    assert(root_node.name.len == 0);
    // get all the property names used in the tree
    const property_names = try collect_property_names(root_node, a);
    defer a.free(property_names);
    errdefer a.free(property_names);
    // stores property name -> index into string block
    var property_name_index_map = std.StringHashMap(u32).init(a);
    defer property_name_index_map.clearAndFree();
    errdefer property_name_index_map.clearAndFree();
    // string block data
    var string_block_buffer = Buffer.init(a);

    // build property name to index map and string block buffer
    for (property_names) |prop_str| {
        try property_name_index_map.putNoClobber(
            prop_str,
            @intCast(string_block_buffer.items.len),
        );
        try string_block_buffer.appendSlice(prop_str);
        try string_block_buffer.append(0); // null-terminate
    }

    // structure block data
    var structure_block_buffer = Buffer.init(a);
    // recursively emit nodes, with the property to index map
    try root_node.emit_node(&structure_block_buffer, &property_name_index_map);
    // terminate
    try emit_u32(TOKEN_END, &structure_block_buffer);

    // collect
    const string_block = try string_block_buffer.toOwnedSlice();
    defer a.free(string_block);
    errdefer a.free(string_block);
    const structure_block = try structure_block_buffer.toOwnedSlice();
    defer a.free(structure_block);
    errdefer a.free(structure_block);

    // whole dtb data
    var dtb_buffer = Buffer.init(a);

    // the dtb header is 40 bytes long,
    // we emit an empty memory reservation block (16 zero bytes),
    // then the structure block and string blocks
    const header_sz: u32 = 40;
    const empty_rsv_sz: u32 = 16;
    const structure_sz: u32 = @intCast(structure_block.len);
    const strings_sz: u32 = @intCast(string_block.len);
    // emit header
    try emit_u32(0xd00dfeed, &dtb_buffer); // magic
    // total size
    try emit_u32(header_sz + empty_rsv_sz + structure_sz + strings_sz, &dtb_buffer);
    // offset of structure block
    try emit_u32(header_sz + empty_rsv_sz, &dtb_buffer);
    // offset of string block
    try emit_u32(header_sz + empty_rsv_sz + structure_sz, &dtb_buffer);
    // offset of memory reservation block
    try emit_u32(header_sz, &dtb_buffer);
    try emit_u32(17, &dtb_buffer); // version
    try emit_u32(16, &dtb_buffer); // min compatible version
    try emit_u32(0, &dtb_buffer); // boot cpu id
    try emit_u32(strings_sz, &dtb_buffer); // string block length
    try emit_u32(structure_sz, &dtb_buffer); // structure block length
    // emit empty memory reservation block
    try emit_u64s(&.{ 0, 0 }, &dtb_buffer);
    // emit the structure and string blocks
    try dtb_buffer.appendSlice(structure_block);
    try dtb_buffer.appendSlice(string_block);

    return try dtb_buffer.toOwnedSlice();
}
