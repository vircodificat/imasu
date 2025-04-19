const std = @import("std");

const Memory = @import("memory.zig");
const Hart = @import("hart.zig");

// entrypoint for testing against riscv-tests,
// run with a path to a riscv-tests test binary
// ELF loading is not implemented yet, so use `objcopy -O binary`

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const a = gpa.allocator();
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);

    if (args.len != 2) {
        std.process.exit(1);
    }

    // 1 MB memory should be enough for riscv-tests binaries
    const mem_sz = 1 * 1024 * 1024;

    const file = try std.fs.cwd().openFileZ(args[1], .{});
    defer file.close();
    const file_bytes = try file.readToEndAlloc(a, mem_sz);

    var ram = try a.alloc(u8, mem_sz);
    @memset(ram, 0);
    @memcpy(ram[0..file_bytes.len], file_bytes);
    var mem = Memory.create(ram);
    var hart = Hart.create();
    hart.mem = &mem;

    var cycle: usize = 0;
    while (cycle < 10000) : (cycle += 1) {
        hart.step();
    }

    // riscv-tests seems to indicate success or failure at 0x8000_1000
    const v = std.mem.readInt(u32, ram[0x1000..0x1004][0..4], .little);
    std.debug.print("tohost: {x:0>8}\n", .{v});
    if (v != 1) std.process.exit(1);
}
