// Devicetree structure and binary (dtb/fdt) emitter
// See https://www.devicetree.org/specifications

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const DeviceTreeNode = @This();

name: []const u8,
children: std.ArrayListUnmanaged(DeviceTreeNode),
properties: std.StringArrayHashMapUnmanaged(PropertyValue),

// the root node of the Devicetree has an empty name
pub fn create_tree(a: Allocator) !DeviceTreeNode {
    return create_node("", a);
}

// creates a new child node for a node and returns it
pub fn create_child(parent_node: *DeviceTreeNode, name: []const u8, a: Allocator) !*DeviceTreeNode {
    const node = try create_node(name, a);
    try parent_node.children.append(a, node);
    return &parent_node.children.items[parent_node.children.items.len - 1];
}

fn create_node(name: []const u8, a: Allocator) !DeviceTreeNode {
    return DeviceTreeNode{
        .name = name,
        .children = try std.ArrayListUnmanaged(DeviceTreeNode).initCapacity(a, 4),
        .properties = std.StringArrayHashMapUnmanaged(PropertyValue).empty,
    };
}

// recursively deinitialise the tree of nodes from the current node
pub fn deinit_tree(node: *DeviceTreeNode, a: Allocator) void {
    for (node.children.items) |*child| {
        child.deinit_tree(a);
    }
    node.children.deinit(a);
    node.properties.deinit(a);
}

pub inline fn add_property_bool(node: *DeviceTreeNode, property_name: []const u8, a: Allocator) !void {
    try node.properties.put(a, property_name, .{ .bool = {} });
}

pub inline fn add_property_string(node: *DeviceTreeNode, property_name: []const u8, value: []const u8, a: Allocator) !void {
    try node.properties.put(a, property_name, .{ .string = value });
}

pub inline fn add_property_u32(node: *DeviceTreeNode, property_name: []const u8, value: u32, a: Allocator) !void {
    try node.properties.put(a, property_name, .{ .u32_array = &.{value} });
}

pub inline fn add_property_u64(node: *DeviceTreeNode, property_name: []const u8, value: u64, a: Allocator) !void {
    try node.properties.put(a, property_name, .{ .u64_array = &.{value} });
}

pub inline fn add_property_u32_array(node: *DeviceTreeNode, property_name: []const u8, value: []const u32, a: Allocator) !void {
    try node.properties.put(a, property_name, .{ .u32_array = value });
}

pub inline fn add_property_u64_array(node: *DeviceTreeNode, property_name: []const u8, value: []const u64, a: Allocator) !void {
    try node.properties.put(a, property_name, .{ .u64_array = value });
}

// dtb tokens
const TOKEN_BEGIN_NODE: u32 = 0x1;
const TOKEN_END_NODE: u32 = 0x2;
const TOKEN_PROP: u32 = 0x3;
const TOKEN_NOP: u32 = 0x4;
const TOKEN_END: u32 = 0x9;

// emit u32, big-endian
inline fn emit_u32(value: u32, buffer: *std.ArrayList(u8)) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..bytes.len], value, .big);
    try buffer.appendSlice(bytes[0..bytes.len]);
}

// emit u32, big-endian
inline fn emit_u64(value: u64, buffer: *std.ArrayList(u8)) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..bytes.len], value, .big);
    try buffer.appendSlice(bytes[0..bytes.len]);
}

// emit array of u32s, big-endian
inline fn emit_u32s(values: []const u32, buffer: *std.ArrayList(u8)) !void {
    for (values) |v| {
        try emit_u32(v, buffer);
    }
}

// emit array of u64s, big-endian
inline fn emit_u64s(values: []const u64, buffer: *std.ArrayList(u8)) !void {
    for (values) |v| {
        try emit_u64(v, buffer);
    }
}

// emit a null-terminated string
inline fn emit_string(value: []const u8, buffer: *std.ArrayList(u8)) !void {
    try buffer.appendSlice(value);
    try buffer.append(0); // null-terminate
}

// pad buffer to a multiple of 4 bytes
inline fn pad_to_4bytes(buffer: *std.ArrayList(u8)) !void {
    if (buffer.items.len % 4 == 0) return;
    try buffer.appendNTimes(0, 4 - (buffer.items.len % 4));
    assert(buffer.items.len % 4 == 0);
}

const PropertyValue = union(enum) {
    bool: void, // boolean values are zero-sized (true if present)
    string: []const u8, // string value
    u32_array: []const u32, // array of u32s
    u64_array: []const u64, // array of u64s
};

inline fn property_value_len(v: PropertyValue) u32 {
    return @intCast(switch (v) {
        .bool => 0,
        .string => |str| str.len + 1,
        .u32_array => |arr| 4 * arr.len,
        .u64_array => |arr| 8 * arr.len,
    });
}

// emit a property value
inline fn emit_property_value(v: PropertyValue, buffer: *std.ArrayList(u8)) !void {
    switch (v) {
        .bool => {},
        .string => |str| try emit_string(str, buffer),
        .u32_array => |arr| try emit_u32s(arr, buffer),
        .u64_array => |arr| try emit_u64s(arr, buffer),
    }
}

// emit a property
// starts with a PROP token, then
// the length of the property value in bytes,
// an offset into the string table for the property name,
// the bytes of the value of the property,
// and then padded to the next multiple of 4 bytes
inline fn emit_property(prop_nameoff: u32, prop_value: PropertyValue, buffer: *std.ArrayList(u8)) !void {
    try emit_u32(TOKEN_PROP, buffer);
    try emit_u32(property_value_len(prop_value), buffer);
    try emit_u32(prop_nameoff, buffer);
    try emit_property_value(prop_value, buffer);
    try pad_to_4bytes(buffer);
}

// traverse the tree and collect all the property strings present
fn collect_property_names(node: *const DeviceTreeNode, a: Allocator) ![][]const u8 {
    var string_set = std.StringHashMap(void).init(a);
    var queue = std.ArrayList(*const DeviceTreeNode).init(a);
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
fn emit_node(node: *const DeviceTreeNode, buffer: *std.ArrayList(u8), prop_map: *std.StringHashMap(u32)) !void {
    try emit_u32(TOKEN_BEGIN_NODE, buffer);
    try emit_string(node.name, buffer);
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

pub fn emit_dtb(root_node: *const DeviceTreeNode, a: Allocator) ![]u8 {
    // get all the property names used in the tree
    const property_names = try collect_property_names(root_node, a);
    defer a.free(property_names);
    errdefer a.free(property_names);
    // stores property name -> index into string block
    var property_name_index_map = std.StringHashMap(u32).init(a);
    defer property_name_index_map.clearAndFree();
    errdefer property_name_index_map.clearAndFree();
    // string block data
    var string_block_buffer = std.ArrayList(u8).init(a);

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
    var structure_block_buffer = std.ArrayList(u8).init(a);
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
    var dtb_buffer = std.ArrayList(u8).init(a);

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
