// VirtIO VirtQueue and Descriptor types
// https://docs.oasis-open.org/virtio/virtio/v1.0/virtio-v1.0.pdf

const Memory = @import("memory.zig");
const std = @import("std");
const assert = std.debug.assert;

pub const VirtQueue = struct {
    ready: bool,
    size: u16,
    last_avail_idx: u16,
    last_used_idx: u16,
    desc_table_paddr: u64,
    avail_ring_paddr: u64,
    used_ring_paddr: u64,

    // get pointer to descriptor by descriptor index
    pub fn get_desc(vq: *const VirtQueue, mem: *Memory, desc: u16) !*Descriptor {
        assert(vq.size > 0);
        assert(desc < vq.size);
        // get slice into descriptor table
        const desc_table_size = @sizeOf(Descriptor) * vq.size;
        const desc_table = try mem.dma_slice(vq.desc_table_paddr, desc_table_size);

        const desc_offset = @sizeOf(Descriptor) * desc;
        return @as(*Descriptor, @alignCast(@ptrCast(&desc_table[desc_offset])));
    }

    // get the index of the first descriptor from
    // the next available descriptor chain
    pub fn next_avail(vq: *VirtQueue, mem: *Memory) !?u16 {
        assert(vq.size > 0);
        // get slice into avail ring
        const vqavail_size = 6 + (@sizeOf(u16) * vq.size);
        const vqavail = try mem.dma_slice(vq.avail_ring_paddr, vqavail_size);
        // read stored avail idx, if the same as last,
        // there are no new descriptor chains
        const avail_idx = std.mem.readInt(u16, vqavail[2..4], .little);
        if (vq.last_avail_idx == avail_idx) return null;

        const idx = ((vq.last_avail_idx % vq.size) * @sizeOf(u16)) + 4;
        defer vq.last_avail_idx +%= 1;
        return std.mem.readInt(u16, vqavail[idx .. idx + 2][0..2], .little);
    }

    // finish with descriptor chain, adding it to the used ring
    pub fn finish(vq: *VirtQueue, mem: *Memory, head_desc: u16, len_used: u32) !void {
        assert(vq.size > 0);
        const UsedElem = extern struct {
            idx: u32,
            len: u32,
        };
        // get slice into used ring
        const vqused_size = 6 + (@sizeOf(UsedElem) * vq.size);
        const vqused = try mem.dma_slice(vq.used_ring_paddr, vqused_size);
        // write descriptor chain head index to idx,
        // write used length to len
        const idx = ((vq.last_used_idx % vq.size) * @sizeOf(UsedElem)) + 4;
        const elem: *UsedElem = @alignCast(@ptrCast(&vqused[idx]));
        elem.* = .{
            .idx = head_desc,
            .len = len_used,
        };
        // increment used index and write
        vq.last_used_idx +%= 1;
        std.mem.writeInt(u16, vqused[2..4], vq.last_used_idx, .little);
    }

    pub fn new() VirtQueue {
        return VirtQueue{
            .ready = false,
            .size = 0,
            .last_avail_idx = 0,
            .last_used_idx = 0,
            .desc_table_paddr = 0,
            .avail_ring_paddr = 0,
            .used_ring_paddr = 0,
        };
    }
};

pub const Descriptor = extern struct {
    paddr: u64,
    len: u32,
    flags: u16,
    next_desc: u16,

    // descriptor flags
    const f_next: u16 = 1 << 0; // contains 'next' field
    const f_write: u16 = 1 << 1; // device write-only

    pub fn writeable(desc: *const Descriptor) bool {
        return (desc.flags & f_write == f_write);
    }

    pub fn readable(desc: *const Descriptor) bool {
        return !(desc.flags & f_write == f_write);
    }

    pub fn next(desc: *const Descriptor) ?u16 {
        return if (desc.flags & f_next == f_next) desc.next_desc else null;
    }
};

test "Descriptor struct size" {
    std.testing.expect(@sizeOf(Descriptor) == 16);
}
