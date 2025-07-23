// VirtIO disk
// https://docs.oasis-open.org/virtio/virtio/v1.0/virtio-v1.0.pdf

const riscv = @import("../riscv.zig");
const PLIC = @import("plic.zig");
const Memory = @import("../memory.zig");
const Descriptor = @import("../virtio.zig").Descriptor;
const VirtQueue = @import("../virtio.zig").VirtQueue;
const std = @import("std");
const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;

const Disk = @This();

// device status field
status: struct {
    acknowledge: bool,
    driver: bool,
    driver_ok: bool,
    features_ok: bool,
    needs_reset: bool,
    failed: bool,
},

// device interrupt status
used_ring_interrupt: bool,
config_change_interrupt: bool,

device_feature_sel: u32,
driver_feature_sel: u32,

features: struct {
    virtio_v1: bool, // bit 32
},

// queue select (this device only implements one queue)
queue_sel: u32,

queue: VirtQueue,

fd: std.posix.fd_t,
sz_sectors: u32,

mutex: Mutex,
cond: Condition,

// handle to memory
mem: *Memory,
// interrupt controller through which to route the interrupt
ic: *PLIC,
// interrupt number on the interrupt controller
const interrupt_num = 2;

const queue_size_max = 0x100;

fn status_read(disk: *Disk) u32 {
    // zig fmt: off
    return set_bit(disk.status.acknowledge, 0)
        | set_bit(disk.status.driver, 1)
        | set_bit(disk.status.driver_ok, 2)
        | set_bit(disk.status.features_ok, 3)
        | set_bit(disk.status.needs_reset, 6)
        | set_bit(disk.status.failed, 7);
    // zig fmt: on
}

fn status_write(disk: *Disk, v: u32) void {
    defer disk.cond.signal();
    // reset the device if 0 is written
    if (v == 0) {
        disk.reset();
        return;
    }
    // if the device has failed, ignore writes apart from reset
    if (disk.status.failed or disk.status.needs_reset) return;

    if (get_bit(v, 0)) disk.status.acknowledge = true;
    if (get_bit(v, 1)) disk.status.driver = true;
    if (get_bit(v, 6)) disk.status.needs_reset = true;
    if (get_bit(v, 7)) disk.status.failed = true;
    if (!(disk.status.failed or disk.status.needs_reset)) {
        if (get_bit(v, 3) and disk.check_features()) {
            disk.status.features_ok = true;
        }
        if (get_bit(v, 2) and disk.status.features_ok) {
            disk.status.driver_ok = true;
        }
    }
}

fn features_read(disk: *Disk) u32 {
    return switch (disk.device_feature_sel) {
        0 => set_bit(true, 2), // seg max
        1 => set_bit(true, 0), // virtio version 1
        else => 0,
    };
}

fn features_write(disk: *Disk, v: u32) void {
    if (disk.status.features_ok) return;
    switch (disk.driver_feature_sel) {
        0 => {},
        1 => {
            disk.features.virtio_v1 = get_bit(v, 0);
        },
        else => {},
    }
}

fn check_queue_size(v: u16) bool {
    return (v > 0 and v <= queue_size_max and std.math.isPowerOfTwo(v));
}

// the only implemented feature bit so far is
// VirtIO version 1, but we do not choose to
// enforce this as U-boot does not negotiate it
// and works fine without it
fn check_features(disk: *Disk) bool {
    _ = disk;
    return true;
}

// zig fmt: off
const reg_device_features     = 0x10;
const reg_device_features_sel = 0x14;
const reg_driver_features     = 0x20;
const reg_driver_features_sel = 0x24;
const reg_queue_sel           = 0x30;
const reg_queue_size_max      = 0x34;
const reg_queue_size          = 0x38;
const reg_queue_ready         = 0x44;
const reg_queue_notify        = 0x50;
const reg_interrupt_status    = 0x60;
const reg_interrupt_ack       = 0x64;
const reg_status              = 0x70;
const reg_queue_desc_lo       = 0x80;
const reg_queue_desc_hi       = 0x84;
const reg_queue_avail_lo      = 0x90;
const reg_queue_avail_hi      = 0x94;
const reg_queue_used_lo       = 0xa0;
const reg_queue_used_hi       = 0xa4;
const reg_generation          = 0xfc;
// zig fmt: on

pub const mmio_len = 0x200;

pub fn mmio_reg_read(disk: *Disk, comptime T: type, reg_addr: u64) ?T {
    if (comptime T != u32) return null;
    return switch (reg_addr) {
        0x0 => 0x74726976, // magic
        0x4 => 2, // version
        0x8 => 2, // type (block device)
        0xc => 0, // vendor ID
        reg_device_features => disk.features_read(),
        reg_queue_size_max => {
            return switch (disk.queue_sel) {
                0 => queue_size_max,
                else => 0,
            };
        },
        reg_queue_ready => {
            return switch (disk.queue_sel) {
                0 => set_bit(disk.queue.ready, 0),
                else => 0,
            };
        },
        reg_interrupt_status => {
            // zig fmt: off
            return set_bit(disk.used_ring_interrupt, 0)
                | set_bit(disk.config_change_interrupt, 1);
            // zig fmt: on
        },
        reg_status => disk.status_read(),
        reg_generation => 0,
        0x100 => disk.sz_sectors,
        0x104 => 0,
        0x10c => 1, // maximum request segments
        else => return null,
    };
}

pub fn mmio_reg_write(disk: *Disk, comptime T: type, reg_addr: u64, v: T) ?void {
    if (comptime T != u32) return null;
    defer disk.cond.signal();
    switch (reg_addr) {
        reg_device_features_sel => disk.device_feature_sel = v,
        reg_driver_features => disk.features_write(v),
        reg_driver_features_sel => disk.driver_feature_sel = v,
        reg_queue_sel => disk.queue_sel = v,
        reg_queue_size => {
            if (disk.queue_sel != 0) return;
            const sz: u16 = @truncate(v);
            if (check_queue_size(sz)) disk.queue.size = sz;
        },
        reg_queue_ready => {
            switch (disk.queue_sel) {
                0 => disk.queue.ready = get_bit(v, 0),
                else => {},
            }
        },
        reg_queue_notify => if (v == 0) disk.cond.signal(),
        reg_interrupt_ack => {
            if (get_bit(v, 0)) disk.used_ring_interrupt = false;
            if (get_bit(v, 1)) disk.config_change_interrupt = false;
        },
        reg_status => disk.status_write(v),
        reg_queue_desc_lo => {
            switch (disk.queue_sel) {
                0 => disk.queue.desc_table_paddr =
                    (disk.queue.desc_table_paddr & mask_hi) | v,
                else => {},
            }
        },
        reg_queue_desc_hi => {
            switch (disk.queue_sel) {
                0 => disk.queue.desc_table_paddr =
                    (disk.queue.desc_table_paddr & mask_lo) | @as(u64, v) << 32,
                else => {},
            }
        },
        reg_queue_avail_lo => {
            switch (disk.queue_sel) {
                0 => disk.queue.avail_ring_paddr =
                    (disk.queue.avail_ring_paddr & mask_hi) | v,
                else => {},
            }
        },
        reg_queue_avail_hi => {
            switch (disk.queue_sel) {
                0 => disk.queue.avail_ring_paddr =
                    (disk.queue.avail_ring_paddr & mask_lo) | @as(u64, v) << 32,
                else => {},
            }
        },
        reg_queue_used_lo => {
            switch (disk.queue_sel) {
                0 => disk.queue.used_ring_paddr =
                    (disk.queue.used_ring_paddr & mask_hi) | v,
                else => {},
            }
        },
        reg_queue_used_hi => {
            switch (disk.queue_sel) {
                0 => disk.queue.used_ring_paddr =
                    (disk.queue.used_ring_paddr & mask_lo) | @as(u64, v) << 32,
                else => {},
            }
        },
        else => return null,
    }
}

fn update_interrupts(disk: *Disk) void {
    if (disk.used_ring_interrupt or disk.config_change_interrupt) {
        disk.ic.set_interrupt_pending(interrupt_num, true);
        return;
    }
    disk.ic.set_interrupt_pending(interrupt_num, false);
}

fn fail(disk: *Disk) void {
    disk.status.needs_reset = true;
    disk.config_change_interrupt = true;
    disk.update_interrupts();
}

// returns true on successful disk request,
// false if no new requests are pending,
// and error on memory access or request failure
fn do_req(disk: *Disk) !bool {
    var req_type: u32 = undefined;
    var req_sector: u64 = undefined;
    var req_data: []u8 = undefined;
    var req_status: []u8 = undefined;

    const head_desc_idx = try disk.queue.next_avail(disk.mem) orelse {
        // no new descriptor chains available
        return false;
    };

    var desc_idx: u16 = head_desc_idx;
    var desc: *Descriptor = undefined;
    for (0..3) |n| {
        desc = try disk.queue.get_desc(disk.mem, desc_idx);
        const desc_data = try disk.mem.dma_slice(desc.paddr, desc.len);
        switch (n) {
            0 => {
                if (desc.len != 16 or !desc.readable()) return error.Invalid;
                req_type = std.mem.readInt(u32, desc_data[0..4], .little);
                req_sector = std.mem.readInt(u64, desc_data[8..16], .little);
            },
            1 => {
                if (desc.len % 512 != 0) return error.lol;
                if (req_type == 0 and !desc.writeable()) return error.Invalid;
                if (req_type == 1 and !desc.readable()) return error.Invalid;
                req_data = desc_data;
            },
            2 => {
                if (desc.len != 1 or !desc.writeable()) return error.Invalid;
                req_status = desc_data;
            },
            else => unreachable,
        }
        if (n != 2) desc_idx = desc.next() orelse return error.Invalid;
    }
    if (desc.next() != null) return error.Invalid;

    var status: u8 = 0;
    switch (req_type) {
        0 => blk: { // read
            std.posix.lseek_SET(disk.fd, req_sector *% 512) catch {
                status = 1;
                break :blk;
            };
            _ = std.posix.read(disk.fd, req_data) catch {
                status = 1;
                break :blk;
            };
        },
        1 => blk: { // write
            std.posix.lseek_SET(disk.fd, req_sector *% 512) catch {
                status = 1;
                break :blk;
            };
            _ = std.posix.write(disk.fd, req_data) catch {
                status = 1;
                break :blk;
            };
        },
        else => { // others (unsupported)
            status = 2;
        },
    }
    std.mem.writeInt(u8, req_status[0..1], status, .little);
    try disk.queue.finish(disk.mem, head_desc_idx, 0);
    return true;
}

pub fn task(disk: *Disk) void {
    while (true) {
        disk.mutex.lock();
        defer disk.mutex.unlock();
        disk.cond.wait(&disk.mutex);

        if (disk.status.failed or disk.status.needs_reset) continue;
        if (!disk.status.features_ok or !disk.status.driver_ok) continue;
        if (!disk.queue.ready) continue;

        while (disk.do_req() catch blk: {
            disk.fail();
            break :blk false;
        }) {
            disk.used_ring_interrupt = true;
            disk.update_interrupts();
        }
    }
}

fn reset(disk: *Disk) void {
    disk.status = .{
        .acknowledge = false,
        .driver = false,
        .driver_ok = false,
        .features_ok = false,
        .needs_reset = false,
        .failed = false,
    };
    disk.used_ring_interrupt = false;
    disk.config_change_interrupt = false;
    disk.features = .{
        .virtio_v1 = false,
    };
    disk.device_feature_sel = 0;
    disk.driver_feature_sel = 0;
    disk.queue_sel = 0;
    disk.queue = VirtQueue.new();
}

pub fn create(fd: std.posix.fd_t, sz: usize) Disk {
    return Disk{
        .fd = fd,
        .sz_sectors = @truncate(sz / 512),
        .status = .{
            .acknowledge = false,
            .driver = false,
            .driver_ok = false,
            .features_ok = false,
            .needs_reset = false,
            .failed = false,
        },
        .used_ring_interrupt = false,
        .config_change_interrupt = false,
        .features = .{
            .virtio_v1 = false,
        },
        .device_feature_sel = 0,
        .driver_feature_sel = 0,
        .queue_sel = 0,
        .queue = VirtQueue.new(),
        .mem = undefined,
        .ic = undefined,
        .mutex = Mutex{},
        .cond = Condition{},
    };
}

inline fn get_bit(v: u32, bit: u5) bool {
    return ((v >> bit) & 0b1) != 0;
}

inline fn set_bit(v: bool, bit: u5) u32 {
    return @as(u32, @intFromBool(v)) << bit;
}

const mask_lo: u64 = 0xffffffff;
const mask_hi: u64 = ~(@as(u64, 0xffffffff));
