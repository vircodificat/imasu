const DeviceTree = @import("devicetree.zig");
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

const help_text =
    \\imasu64 is a RISC-V 64-bit System Emulator
    \\(isa string: rv64imau_zicsr_zifencei)
    \\
    \\usage: imasu64 [ -i <image> ] [ -m, --memory <memory size> ] [ --dtb ] [ --ctrlc ] [ -h, --help ]
    \\
    \\-i <image>                  Provide a binary image for the emulator to run
    \\-m, --memory <memory size>  Specify system main memory size in MiB, default is 256
    \\--dtb                       Instead of running the emulator, prints the generated devicetree blob,
    \\                            can be used to pipe into devicetree compiler (dtc -I dtb)
    \\--ctrlc                     Allow Ctrl+C to be sent through stdin, instead of terminating the emulator
    \\-h, --help                  Print this help text
    \\
;

fn die(comptime format: []const u8, args: anytype) noreturn {
    const stderr = std.io.getStdErr().writer();
    stderr.print(format ++ "\n", args) catch {};
    std.process.exit(1);
}

fn die_with_error(comptime format: []const u8, args: anytype, err: anyerror) noreturn {
    const stderr = std.io.getStdErr().writer();
    stderr.print(format ++ ": {s}\n", args ++ .{@errorName(err)}) catch {};
    std.process.exit(1);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const a = gpa.allocator();
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);

    const stdout = std.io.getStdOut().writer();

    var image_path: ?[:0]const u8 = null;
    var mem_sz: usize = 256 * 1024 * 1024;
    var allow_ctrl_c: bool = false;
    var print_dtb: bool = false;

    var idx: usize = 1;
    while (idx < args.len) : (idx += 1) {
        const arg: [:0]const u8 = args[idx];
        const maybe_next: ?[:0]const u8 = if (idx + 1 < args.len) args[idx + 1] else null;

        // -i <image>
        if (eql(u8, arg, "-i")) {
            if (maybe_next) |next_arg| {
                image_path = next_arg;
            } else die("flag '-i' expects a file path", .{});
            idx += 1;
            continue;
        }

        // -m, --memory <memory size>
        if (eql(u8, arg, "-m") or eql(u8, arg, "--memory")) {
            var mem_sz_mib: usize = undefined;
            if (maybe_next) |next_arg| {
                mem_sz_mib = std.fmt.parseInt(usize, next_arg, 10) catch |err| {
                    die_with_error("could not parse memory size", .{}, err);
                };
            } else die("flag '{s}' expects a memory size\n", .{arg});
            if (mem_sz_mib < 8) die("too little memory for system, use at least 8 MiB", .{});
            if (mem_sz_mib > std.math.maxInt(usize) / 1024 * 1024) die("memory size specified is too big", .{});
            mem_sz = mem_sz_mib * 1024 * 1024;
            idx += 1;
            continue;
        }

        // --dtb
        if (eql(u8, arg, "--dtb")) {
            print_dtb = true;
            continue;
        }

        // --ctrlc
        if (eql(u8, arg, "--ctrlc")) {
            allow_ctrl_c = true;
            continue;
        }

        // -h, --help
        if (eql(u8, arg, "-h") or eql(u8, arg, "--help")) {
            _ = stdout.write(help_text) catch {};
            std.process.exit(0);
        }
    }

    // create empty device tree
    var root = try DeviceTree.create_tree(a);
    errdefer root.deinit_tree(a);
    var next_phandle: u32 = 1;

    try root.add_property_u32("#address-cells", 2, a);
    try root.add_property_u32("#size-cells", 2, a);
    try root.add_property_string("compatible", "riscv,imasu64", a);
    try root.add_property_string("model", "riscv-nommu,imasu64", a);

    var chosen_node = try root.create_child("chosen", a);
    try chosen_node.add_property_string("bootargs", "earlycon=uart,mmio,0x10000000,9600n console=ttyS0", a);

    const mem_node_name = try node_name_with_unit_address("memory", Memory.mem_base, a);
    var mem_node = try root.create_child(mem_node_name, a);
    try mem_node.add_property_string("device_type", "memory", a);
    try mem_node.add_property_u64_array("reg", &.{ Memory.mem_base, mem_sz }, a);

    var soc_node = try root.create_child("soc", a);
    try soc_node.add_property_u32("#address-cells", 2, a);
    try soc_node.add_property_u32("#size-cells", 2, a);
    try soc_node.add_property_string("compatible", "simple-bus", a);
    try soc_node.add_property_bool("ranges", a);

    // create a hart
    var hart = Hart.create();

    var cpus_node = try root.create_child("cpus", a);
    try cpus_node.add_property_u32("#address-cells", 1, a);
    try cpus_node.add_property_u32("#size-cells", 0, a);
    try cpus_node.add_property_u32("timebase-frequency", std.time.ns_per_s, a);
    const cpu0_node_name = try node_name_with_unit_address("cpu", 0, a);
    var cpu0_node = try cpus_node.create_child(cpu0_node_name, a);
    try cpu0_node.add_property_string("compatible", "riscv", a);
    try cpu0_node.add_property_string("device_type", "cpu", a);
    try cpu0_node.add_property_u32("reg", 0, a);
    try cpu0_node.add_property_string("riscv,isa", "rv64imasu_zicsr_zifencei", a);
    try cpu0_node.add_property_string("riscv,isa-base", "rv64i", a);
    try cpu0_node.add_property_string("riscv,extensions", "i\x00m\x00a\x00zicsr\x00zifencei", a);
    try cpu0_node.add_property_string("mmu-type", "riscv,none", a);

    // create CLINT timer device
    const clint_mmio_base: u64 = 0x1100_0000;
    var clint = CLINT.create();
    var clint_dev = Device{
        .kind = .{ .clint = &clint },
        .mmio_base = clint_mmio_base,
        .mmio_len = CLINT.mmio_len,
    };

    var cpu0_intc_node = try cpu0_node.create_child("interrupt-controller", a);
    try cpu0_intc_node.add_property_bool("interrupt-controller", a);
    try cpu0_intc_node.add_property_u32("#interrupt-cells", 1, a);
    try cpu0_intc_node.add_property_string("compatible", "riscv,cpu-intc", a);
    const cpu0_intc_phandle = next_phandle;
    next_phandle += 1;
    try cpu0_intc_node.add_property_u32("phandle", cpu0_intc_phandle, a);

    const clint_node_name = try node_name_with_unit_address("clint", clint_mmio_base, a);
    var clint_node = try soc_node.create_child(clint_node_name, a);
    try clint_node.add_property_string("compatible", "sifive,clint0\x00riscv,clint0", a);
    try clint_node.add_property_u64_array("reg", &.{ clint_mmio_base, CLINT.mmio_len }, a);
    try clint_node.add_property_u32_array("interrupts-extended", &.{ cpu0_intc_phandle, 0x3, cpu0_intc_phandle, 0x7 }, a);

    // create PLIC device
    const plic_mmio_base: u64 = 0x0c00_0000;
    var plic = PLIC.create();
    var plic_dev = Device{
        .kind = .{ .plic = &plic },
        .mmio_base = plic_mmio_base,
        .mmio_len = PLIC.mmio_len,
    };

    const plic_node_name = try node_name_with_unit_address("interrupt-controller", plic_mmio_base, a);
    var plic_node = try root.create_child(plic_node_name, a);
    try plic_node.add_property_bool("interrupt-controller", a);
    try plic_node.add_property_u32("#address-cells", 2, a);
    try plic_node.add_property_u32("#interrupt-cells", 1, a);
    try plic_node.add_property_string("compatible", "sifive,plic-1.0.0", a);
    try plic_node.add_property_u64_array("reg", &.{ plic_mmio_base, PLIC.mmio_len }, a);
    try plic_node.add_property_u32("riscv,ndev", 1, a);
    try plic_node.add_property_u32_array("interrupts-extended", &.{ cpu0_intc_phandle, 0xb }, a);
    const plic_phandle = next_phandle;
    next_phandle += 1;
    try plic_node.add_property_u32("phandle", plic_phandle, a);

    // create UART device
    const uart_mmio_base: u64 = 0x1000_0000;
    var uart = UART.create();
    var uart_dev = Device{
        .kind = .{ .uart = &uart },
        .mmio_base = uart_mmio_base,
        .mmio_len = UART.mmio_len,
    };

    const uart_node_name = try node_name_with_unit_address("serial", uart_mmio_base, a);
    var uart_node = try soc_node.create_child(uart_node_name, a);
    try uart_node.add_property_string("compatible", "ns16550", a);
    try uart_node.add_property_u64_array("reg", &.{ uart_mmio_base, UART.mmio_len }, a);
    try uart_node.add_property_u32_array("interrupts-extended", &.{ plic_phandle, 0x1 }, a);
    try uart_node.add_property_u32("clock-frequency", 9600 * 16, a);
    try chosen_node.add_property_string("stdout-path", "/soc/serial", a);

    // create Syscon
    const syscon_mmio_base: u64 = 0x1110_0000;
    var syscon = Syscon{};
    var syscon_dev = Device{
        .kind = .{ .syscon = &syscon },
        .mmio_base = syscon_mmio_base,
        .mmio_len = Syscon.mmio_len,
    };
    const syscon_node_name = try node_name_with_unit_address("syscon", syscon_mmio_base, a);
    var syscon_node = try soc_node.create_child(syscon_node_name, a);
    try syscon_node.add_property_string("compatible", "syscon", a);
    try syscon_node.add_property_u64_array("reg", &.{ syscon_mmio_base, Syscon.mmio_len }, a);
    const syscon_phandle = next_phandle;
    next_phandle += 1;
    try syscon_node.add_property_u32("phandle", syscon_phandle, a);
    var syscon_poweroff_node = try root.create_child("poweroff", a);
    try syscon_poweroff_node.add_property_string("compatible", "syscon-poweroff", a);
    try syscon_poweroff_node.add_property_u32("value", Syscon.poweroff, a);
    try syscon_poweroff_node.add_property_u32("offset", 0, a);
    try syscon_poweroff_node.add_property_u32("regmap", syscon_phandle, a);

    // create DTB node in devicetree, then finish
    const dtb_mmio_base: u64 = 0x7000_0000;
    const dtb_sz = 16 * 1024;
    const dtb_node_name = try node_name_with_unit_address("dtb", dtb_mmio_base, a);
    var dtb_node = try root.create_child(dtb_node_name, a);
    try dtb_node.add_property_u64_array("reg", &.{ dtb_mmio_base, dtb_sz }, a);
    try dtb_node.add_property_bool("read-only", a);

    const dtb_buffer = dtb: {
        var buffer: [dtb_sz]u8 = @splat(0);
        const dtb_data = try root.emit_dtb(a);
        defer a.free(dtb_data);

        if (print_dtb) {
            _ = stdout.write(dtb_data) catch {};
            std.process.exit(0);
        }

        @memcpy(buffer[0..dtb_data.len], dtb_data);
        break :dtb buffer;
    };

    // create DTB ROM device with the buffer
    var dtb_rom = ROM{ .mem = &dtb_buffer };
    var dtb_dev = Device{
        .kind = .{ .rom = &dtb_rom },
        .mmio_base = dtb_mmio_base,
        .mmio_len = dtb_sz,
    };

    std.debug.assert(print_dtb == false); // should have quit by now!

    if (image_path == null) die("no binary image provided, run with -h or --help for usage", .{});

    const image_file = std.posix.open(image_path.?, .{ .ACCMODE = .RDONLY }, 0) catch |err| {
        die_with_error("could not open \"{s}\"", .{image_path.?}, err);
    };
    defer std.posix.close(image_file);
    const image_len: usize = @intCast((try std.posix.fstat(image_file)).size);

    if (image_len > mem_sz) die("image file \"{s}\" is too big to fit in main memory", .{image_path.?});

    // allocate memory for ram and mmap the image into it
    var ram = try a.alignedAlloc(u8, std.heap.page_size_min, mem_sz);
    @memset(ram, 0);
    _ = std.posix.mmap(
        @ptrCast(@alignCast(&ram[0])),
        image_len,
        (std.posix.PROT.READ | std.posix.PROT.WRITE | std.posix.PROT.EXEC),
        std.posix.MAP{ .FIXED = true, .TYPE = .PRIVATE },
        image_file,
        0,
    ) catch |err| {
        die_with_error("failed to mmap \"{s}\"", .{image_path.?}, err);
    };
    // create memory with ram
    var mem = Memory.create(ram);

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

    // run the hart on the main thread
    hart.task();
}

fn node_name_with_unit_address(name: []const u8, unit_addr: u64, a: std.mem.Allocator) ![]u8 {
    // unit_addr when writen as hex can take up at most 16 bytes
    var num_buf: [16]u8 = undefined;
    const num = std.fmt.bufPrintIntToSlice(&num_buf, unit_addr, 16, .lower, .{});
    var buf = try a.alloc(u8, name.len + 1 + num.len);
    const string = std.fmt.bufPrint(buf[0..buf.len], "{s}@{s}", .{ name, num }) catch unreachable;
    std.debug.assert(num.len <= 16);
    std.debug.assert(string.len == buf.len);
    return string;
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
