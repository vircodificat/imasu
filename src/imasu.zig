const Device = @import("device.zig");
const CLINT = @import("devices/clint.zig");
const PLIC = @import("devices/plic.zig");
const UART = @import("devices/uart.zig");
const ROM = @import("devices/rom.zig");
const Syscon = @import("devices/syscon.zig");
const Memory = @import("memory.zig");
const Hart = @import("hart.zig");
const std = @import("std");
const eql = std.mem.eql;

const dtb_sz = 64 * 1024;
const devicetree = @embedFile("devicetree/imasu64.dtb");
const dtb_buffer: [dtb_sz]u8 = dtb: {
    var buf: [dtb_sz]u8 = .{0} ** dtb_sz;
    @memcpy(buf[0..devicetree.len], devicetree);
    break :dtb buf;
};

// TODO: accept memory size on command line
const mem_sz = 256 * 1024 * 1024;

const help_text =
    \\imasu64 is a RISC-V 64-bit System Emulator
    \\(isa string: rv64imau_zicsr_zifencei)
    \\
    \\usage: imasu64 <image> [ --ctrlc ] [ -h, --help ]
    \\
    \\image is a binary image to run on the emulator
    \\
    \\--ctrlc     allow Ctrl+C to be sent through stdin,
    \\            instead of terminating the emulator
    \\-h, --help  print this help text
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const a = gpa.allocator();
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);

    const stdout = std.io.getStdOut().writer();

    var image_path: ?[*:0]u8 = null;
    var allow_ctrl_c: bool = false;

    for (args[1..args.len]) |arg| {
        if (eql(u8, arg, "-h") or eql(u8, arg, "--help")) {
            _ = stdout.write(help_text) catch {};
            std.process.exit(0);
        }
        if (eql(u8, arg, "--ctrlc")) {
            allow_ctrl_c = true;
            continue;
        }
        image_path = arg;
    }

    if (image_path == null) {
        const text = "no binary image provided, run with -h or --help for usage\n";
        _ = stdout.write(text) catch {};
        std.process.exit(1);
    }

    const image = blk: {
        const file = try std.fs.cwd().openFileZ(image_path.?, .{});
        defer file.close();
        break :blk try file.readToEndAlloc(a, mem_sz);
    };

    // allocate memory for ram and load image into it
    var ram = try a.alloc(u8, mem_sz);
    @memset(ram, 0);
    @memcpy(ram[0..image.len], image);
    a.free(image);
    // create memory with ram
    var mem = Memory.create(ram);

    // create a hart
    var hart = Hart.create();

    // create CLINT timer device
    var clint = CLINT.create();
    var clint_dev = Device{
        .kind = .{ .clint = &clint },
        .mmio_base = 0x1100_0000,
        .mmio_len = CLINT.mmio_len,
    };

    // create PLIC device
    var plic = PLIC.create();
    var plic_dev = Device{
        .kind = .{ .plic = &plic },
        .mmio_base = 0x0c00_0000,
        .mmio_len = PLIC.mmio_len,
    };

    // create UART device
    var uart = UART.create();
    var uart_dev = Device{
        .kind = .{ .uart = &uart },
        .mmio_base = 0x1000_0000,
        .mmio_len = UART.mmio_len,
    };

    var syscon = Syscon{};
    // create Syscon
    var syscon_dev = Device{
        .kind = .{ .syscon = &syscon },
        .mmio_base = 0x1110_0000,
        .mmio_len = Syscon.mmio_len,
    };

    // create DTB ROM device with dtb bytes
    var dtb_rom = ROM{ .mem = &dtb_buffer };
    var dtb_dev = Device{
        .kind = .{ .rom = &dtb_rom },
        .mmio_base = 0x7000_0000,
        .mmio_len = dtb_sz,
    };

    hart.mem = &mem;
    hart.csrs.time_csr_timer = &clint;
    clint.interrupt_target = &hart;
    plic.ctx0 = &hart;
    uart.interrupt_target = &plic;

    // list of all mmio devices
    var mmio_dev_list = [_]*Device{
        &clint_dev,
        &plic_dev,
        &uart_dev,
        &dtb_dev,
        &syscon_dev,
    };
    // attach them to main memory
    mem.devices = mmio_dev_list[0..mmio_dev_list.len];

    // set a1 register to start of dtb rom
    hart.x[11] = dtb_dev.mmio_base;

    // standard input setup
    try stdin_nonblocking();
    try terminal_make_raw(allow_ctrl_c);

    // spawn the thread that runs the timer
    var clint_thread = try std.Thread.spawn(.{}, CLINT.task, .{&clint});
    clint_thread.detach();

    // spawn the thread that runs the UART
    var uart_thread = try std.Thread.spawn(.{}, UART.task, .{&uart});
    uart_thread.detach();

    hart.mutex.lock();
    // main loop for the hart
    const wfi_timeout = 100 * std.time.ns_per_ms;
    while (true) {
        hart.try_take_interrupt();
        // run at most some amount of cycles before checking for interrupts
        var cycle: usize = 0;
        while (cycle < 1024) : (cycle += 1) inst: {
            hart.step();
            if (hart.wfi) { // on wfi, halt until we receive an interrupt or timeout
                @branchHint(.unlikely);
                hart.cond.timedWait(&hart.mutex, wfi_timeout) catch {};
                break :inst;
            }
        }
    }
}

// zig fmt: off
fn stdin_nonblocking() !void {
    const flags = try std.posix.fcntl(0, std.c.F.GETFL, 0);
    _ = try std.posix.fcntl(0, std.c.F.SETFL,
        flags | @as(u32, @bitCast(std.c.O{ .NONBLOCK = true })),
    );
}
// zig fmt: on

fn terminal_make_raw(allow_ctrl_c: bool) !void {
    var termios = try std.posix.tcgetattr(0);
    termios.iflag.IGNBRK = false;
    termios.iflag.BRKINT = false;
    termios.iflag.PARMRK = false;
    termios.iflag.ISTRIP = false;
    termios.iflag.INLCR = false;
    termios.iflag.IGNCR = false;
    termios.iflag.ICRNL = false;
    termios.iflag.IXON = false;
    termios.oflag.OPOST = false;
    termios.lflag.ECHO = false;
    termios.lflag.ECHONL = false;
    termios.lflag.ICANON = false;
    termios.lflag.IEXTEN = false;
    termios.cflag.PARENB = false;
    termios.cflag.CSIZE = .CS8;
    if (allow_ctrl_c) termios.lflag.ISIG = false;
    try std.posix.tcsetattr(0, .NOW, termios);
}
