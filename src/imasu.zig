const DT = @import("devicetree.zig");
const Hart = @import("hart.zig");
const Memory = @import("memory.zig");
const MMU = @import("mmu.zig");
const Device = @import("device.zig");
const Disk = @import("devices/virtio_disk.zig");
const CLINT = @import("devices/clint.zig");
const PLIC = @import("devices/plic.zig");
const ROM = @import("devices/rom.zig");
const Syscon = @import("devices/syscon.zig");
const UART = @import("devices/uart.zig");
const riscv = @import("riscv.zig");
const std = @import("std");
const eql = std.mem.eql;

const help_text =
    \\imasu64 is a RISC-V 64-bit System Emulator
    \\
    \\usage: imasu64 [ -i <image> ] [ -d <disk image> ] [ -m, --memory <size> ] [ --dtb ] [ --ctrlc ] [ -h, --help ]
    \\
    \\-i <image>           Provide a binary image to run
    \\-d <disk image>      Provide a hard disk image
    \\-m, --memory <size>  Specify system main memory size in MiB, default is 256
    \\--dtb                Instead of running the emulator, prints the generated devicetree blob for the system,
    \\                     pipe into devicetree compiler to see (dtc -I dtb)
    \\--ctrlc              Allow Ctrl+C to be sent through stdin, instead of terminating the emulator
    \\-h, --help           Print this help text
    \\
;

// zig fmt: off
const clint_mmio_base: u64 =  0x0200_0000;
const plic_mmio_base: u64 =   0x0c00_0000;
const uart_mmio_base: u64 =   0x1000_0000;
const syscon_mmio_base: u64 = 0x1100_0000;
const disk_mmio_base: u64 =   0x2000_0000;
const dtb_mmio_base: u64 =    0x4000_0000;
// zig fmt: on
const dtb_sz = 16 * 1024;

const phys_mem_max_sz_mib: usize =
    ((std.math.maxInt(riscv.xlen) - Memory.mem_base) + 1) / (1024 * 1024) - 1;

fn die(comptime format: []const u8, args: anytype) noreturn {
    const stderr = std.io.getStdErr().writer();
    stderr.print(format ++ "\n", args) catch {};
    std.process.exit(1);
}

fn die_error(comptime format: []const u8, args: anytype, err: anyerror) noreturn {
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
    var disk_path: ?[:0]const u8 = null;
    var mem_sz: usize = 256 * 1024 * 1024;
    var allow_ctrl_c: bool = false;
    var print_dtb: bool = false;

    var idx: usize = 1;
    while (idx < args.len) : (idx += 1) {
        const arg = args[idx];
        const maybe_next = if (idx + 1 < args.len) args[idx + 1] else null;

        // -i <image>
        if (eql(u8, arg, "-i")) {
            if (maybe_next) |next_arg| {
                image_path = next_arg;
            } else die("flag '-i' expects a file path", .{});
            idx += 1;
            continue;
        }

        // -d <disk image>
        if (eql(u8, arg, "-d")) {
            if (maybe_next) |next_arg| {
                disk_path = next_arg;
            } else die("flag '-d' expects a file path", .{});
            idx += 1;
            continue;
        }

        // -m, --memory <memory size>
        if (eql(u8, arg, "-m") or eql(u8, arg, "--memory")) {
            var mem_sz_mib: usize = undefined;
            if (maybe_next) |next_arg| {
                mem_sz_mib = std.fmt.parseInt(usize, next_arg, 10) catch |err| {
                    die_error("could not parse memory size", .{}, err);
                };
            } else die("flag '{s}' expects a memory size\n", .{arg});
            if (mem_sz_mib < 8)
                die("too little memory for system, use at least 8 MiB", .{});
            if (mem_sz_mib > phys_mem_max_sz_mib)
                die("memory size specified is too big to be addressable", .{});
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

    // generate devicetree data
    const dtb_data = try generate_devicetree(mem_sz, (disk_path != null), a);
    defer a.free(dtb_data);
    var dtb_buffer: [dtb_sz]u8 = @splat(0);
    @memcpy(dtb_buffer[0..dtb_data.len], dtb_data);

    if (print_dtb) {
        _ = stdout.write(dtb_data) catch {};
        std.process.exit(0);
    }

    if (image_path == null)
        die("no binary image provided, run with -h or --help for usage", .{});

    const image_file = std.posix.open(image_path.?, .{ .ACCMODE = .RDONLY }, 0) catch |err| {
        die_error("could not open \"{s}\"", .{image_path.?}, err);
    };
    defer std.posix.close(image_file);

    const image_len: usize = @intCast((try std.posix.fstat(image_file)).size);
    if (image_len > mem_sz)
        die("image file \"{s}\" is too big to fit in main memory", .{image_path.?});

    // allocate memory for RAM
    const ram: []align(std.heap.page_size_min) u8 =
        try a.alignedAlloc(u8, std.heap.page_size_min, mem_sz);

    // zero initialise
    @memset(ram, 0);

    // map the image into RAM on top of the allocated memory
    _ = try std.posix.mmap(
        @ptrCast(ram),
        image_len,
        (std.posix.PROT.READ | std.posix.PROT.WRITE | std.posix.PROT.EXEC),
        std.posix.MAP{ .FIXED = true, .TYPE = .PRIVATE },
        image_file,
        0,
    );

    var disk_file: ?std.posix.fd_t = null;
    var disk_sz: ?u64 = null;
    if (disk_path) |path| {
        disk_file = std.posix.open(path, .{ .ACCMODE = .RDWR }, 0) catch |err| {
            die_error("could not open \"{s}\"", .{path}, err);
        };
        const stat = std.posix.fstat(disk_file.?) catch |err| {
            die_error("could not stat \"{s}\"", .{path}, err);
        };
        disk_sz = @intCast(stat.size);
    }

    var mmio_devices = try std.ArrayList(*Device).initCapacity(a, 8);

    // standard input setup
    try terminal_make_raw(allow_ctrl_c);

    // create memory with ram
    var mem = Memory.create(ram);
    // create an MMU from memory
    var mmu = MMU.create(&mem);

    // create a hart
    var hart = Hart.create();

    // create CLINT timer device
    var clint = CLINT.create();
    var clint_dev = Device{
        .kind = .{ .clint = &clint },
        .mmio_base = clint_mmio_base,
        .mmio_len = CLINT.mmio_len,
    };
    try mmio_devices.append(&clint_dev);

    // create PLIC device
    var plic = PLIC.create();
    var plic_dev = Device{
        .kind = .{ .plic = &plic },
        .mmio_base = plic_mmio_base,
        .mmio_len = PLIC.mmio_len,
    };
    try mmio_devices.append(&plic_dev);

    // create UART device
    var uart = UART.create();
    var uart_dev = Device{
        .kind = .{ .uart = &uart },
        .mmio_base = uart_mmio_base,
        .mmio_len = UART.mmio_len,
    };
    try mmio_devices.append(&uart_dev);

    // optionally create disk device
    var disk: Disk = undefined;
    var disk_dev: Device = undefined;
    if (disk_file) |fd| {
        disk = Disk.create(fd, disk_sz.?);
        disk_dev = Device{
            .kind = .{ .disk = &disk },
            .mmio_base = disk_mmio_base,
            .mmio_len = Disk.mmio_len,
        };
        try mmio_devices.append(&disk_dev);
    }

    // create Syscon
    var syscon = Syscon{};
    var syscon_dev = Device{
        .kind = .{ .syscon = &syscon },
        .mmio_base = syscon_mmio_base,
        .mmio_len = Syscon.mmio_len,
    };
    try mmio_devices.append(&syscon_dev);

    // create DTB ROM device with the buffer
    var dtb_rom = ROM{ .mem = &dtb_buffer };
    var dtb_dev = Device{
        .kind = .{ .rom = &dtb_rom },
        .mmio_base = dtb_mmio_base,
        .mmio_len = dtb_sz,
    };
    try mmio_devices.append(&dtb_dev);

    hart.mmu = &mmu;
    hart.csrs.mmu = &mmu;
    hart.csrs.time_csr_timer = &clint;
    clint.hart = &hart;
    plic.hart = &hart;
    uart.ic = &plic;
    disk.ic = &plic;
    if (disk_file != null) disk.mem = &mem;

    // attach devices to main memory
    mem.devices = try mmio_devices.toOwnedSlice();

    // set a1 register to start of dtb rom
    hart.x[11] = dtb_dev.mmio_base;

    // spawn the thread that runs the timer
    var clint_thread = try std.Thread.spawn(.{}, CLINT.task, .{&clint});
    clint_thread.detach();

    // spawn the thread that runs the UART
    var uart_thread = try std.Thread.spawn(.{}, UART.task, .{&uart});
    uart_thread.detach();

    if (disk_file != null) {
        // spawn the thread that runs the VirtIO disk
        var disk_thread = try std.Thread.spawn(.{}, Disk.task, .{&disk});
        disk_thread.detach();
    }

    // run the hart on the main thread
    hart.task();
}

// generate devicetree blob for the system
// if SMP is ever supported, then we must generate nodes for all harts
fn generate_devicetree(
    mem_size: usize, // size of system memory
    disk: bool, // whether we have a disk or not
    a: std.mem.Allocator,
) ![]const u8 {
    var root = DT.create_node("");
    errdefer root.deinit_tree(a);
    var next_phandle: u32 = 1;

    try root.add_u32_prop("#address-cells", 2, a);
    try root.add_u32_prop("#size-cells", 2, a);
    try root.add_string_prop("compatible", "riscv,imasu64", a);
    try root.add_string_prop("model", "riscv,imasu64", a);

    var chosen = DT.create_node("chosen");
    try chosen.add_string_prop("stdout-path", "/soc/serial", a);
    try chosen.add_string_prop(
        "bootargs",
        "earlycon=uart,mmio,0x10000000,9600n console=ttyS0 root=/dev/vda rw",
        a,
    );

    const mem_name = try name_unit_addr("memory", Memory.mem_base, a);
    var mem = DT.create_node(mem_name);
    try mem.add_string_prop("device_type", "memory", a);
    try mem.add_u64_array_prop("reg", &.{ Memory.mem_base, mem_size }, a);

    var soc = DT.create_node("soc");
    try soc.add_u32_prop("#address-cells", 2, a);
    try soc.add_u32_prop("#size-cells", 2, a);
    try soc.add_string_prop("compatible", "simple-bus", a);
    try soc.add_bool_prop("ranges", a);

    var cpus = DT.create_node("cpus");
    try cpus.add_u32_prop("#address-cells", 1, a);
    try cpus.add_u32_prop("#size-cells", 0, a);
    try cpus.add_u32_prop("timebase-frequency", CLINT.timebase_freq, a);

    const cpu0_name = try name_unit_addr("cpu", 0, a);
    var cpu0 = DT.create_node(cpu0_name);
    try cpu0.add_string_prop("compatible", "riscv", a);
    try cpu0.add_string_prop("device_type", "cpu", a);
    try cpu0.add_u32_prop("reg", 0, a);
    try cpu0.add_string_prop(
        "riscv,isa",
        "rv64ima_zicsr_zifencei_svade",
        a,
    );
    try cpu0.add_string_prop("riscv,isa-base", "rv64i", a);
    try cpu0.add_string_array_prop(
        "riscv,isa-extensions",
        &.{ "i", "m", "a", "zicsr", "zifencei", "svade" },
        a,
    );
    try cpu0.add_string_prop("mmu-type", "riscv,sv39", a);
    try cpu0.add_string_prop("status", "okay", a);

    var cpu0_intc = DT.create_node("interrupt-controller");
    const cpu0_intc_phandle = next_phandle;
    next_phandle += 1;
    try cpu0_intc.add_bool_prop("interrupt-controller", a);
    try cpu0_intc.add_u32_prop("#interrupt-cells", 1, a);
    try cpu0_intc.add_string_prop("compatible", "riscv,cpu-intc", a);
    try cpu0_intc.add_u32_prop("phandle", cpu0_intc_phandle, a);

    const clint_name = try name_unit_addr("clint", clint_mmio_base, a);
    var clint = DT.create_node(clint_name);
    try clint.add_string_array_prop(
        "compatible",
        &.{ "sifive,clint0", "riscv,clint0" },
        a,
    );
    try clint.add_u64_array_prop(
        "reg",
        &.{ clint_mmio_base, CLINT.mmio_len },
        a,
    );
    try clint.add_u32_array_prop(
        "interrupts-extended",
        &.{ cpu0_intc_phandle, 0x3, cpu0_intc_phandle, 0x7 },
        a,
    );

    const plic_name = try name_unit_addr(
        "interrupt-controller",
        plic_mmio_base,
        a,
    );
    var plic = DT.create_node(plic_name);
    const plic_phandle = next_phandle;
    next_phandle += 1;
    try plic.add_bool_prop("interrupt-controller", a);
    try plic.add_u32_prop("#address-cells", 2, a);
    try plic.add_u32_prop("#interrupt-cells", 1, a);
    try plic.add_string_prop("compatible", "sifive,plic-1.0.0", a);
    try plic.add_u64_array_prop(
        "reg",
        &.{ plic_mmio_base, PLIC.mmio_len },
        a,
    );
    try plic.add_u32_prop("riscv,ndev", 2, a);
    try plic.add_u32_array_prop(
        "interrupts-extended",
        &.{ cpu0_intc_phandle, 0xb, cpu0_intc_phandle, 0x9 },
        a,
    );
    try plic.add_u32_prop("phandle", plic_phandle, a);

    const uart_name = try name_unit_addr("serial", uart_mmio_base, a);
    var uart = DT.create_node(uart_name);
    try uart.add_string_prop("compatible", "ns16550", a);
    try uart.add_u64_array_prop(
        "reg",
        &.{ uart_mmio_base, UART.mmio_len },
        a,
    );
    try uart.add_u32_array_prop(
        "interrupts-extended",
        &.{ plic_phandle, 0x1 },
        a,
    );
    try uart.add_u32_prop("clock-frequency", 9600 * 16, a);

    const virtio_block_name = try name_unit_addr("virtio_block", disk_mmio_base, a);
    var virtio_block = DT.create_node(virtio_block_name);
    try virtio_block.add_string_prop("compatible", "virtio,mmio", a);
    try virtio_block.add_u64_array_prop(
        "reg",
        &.{ disk_mmio_base, Disk.mmio_len },
        a,
    );
    try virtio_block.add_u32_array_prop(
        "interrupts-extended",
        &.{ plic_phandle, 0x2 },
        a,
    );

    const syscon_name = try name_unit_addr("syscon", syscon_mmio_base, a);
    var syscon = DT.create_node(syscon_name);
    const syscon_phandle = next_phandle;
    next_phandle += 1;
    try syscon.add_string_prop("compatible", "syscon", a);
    try syscon.add_u64_array_prop(
        "reg",
        &.{ syscon_mmio_base, Syscon.mmio_len },
        a,
    );
    try syscon.add_u32_prop("phandle", syscon_phandle, a);

    var syscon_poweroff = DT.create_node("poweroff");
    try syscon_poweroff.add_string_prop("compatible", "syscon-poweroff", a);
    try syscon_poweroff.add_u32_prop("value", Syscon.poweroff, a);
    try syscon_poweroff.add_u32_prop("offset", 0, a);
    try syscon_poweroff.add_u32_prop("regmap", syscon_phandle, a);

    const dtb_name = try name_unit_addr("dtb", dtb_mmio_base, a);
    var dtb = DT.create_node(dtb_name);
    try dtb.add_u64_array_prop("reg", &.{ dtb_mmio_base, dtb_sz }, a);
    try dtb.add_bool_prop("read-only", a);

    try root.add_child(chosen, a);
    try root.add_child(mem, a);
    try root.add_child(dtb, a);

    try cpu0.add_child(cpu0_intc, a);
    try cpus.add_child(cpu0, a);
    try root.add_child(cpus, a);

    try soc.add_child(clint, a);
    try soc.add_child(plic, a);
    try soc.add_child(uart, a);
    if (disk) try soc.add_child(virtio_block, a);
    try soc.add_child(syscon, a);
    try root.add_child(soc, a);

    try root.add_child(syscon_poweroff, a);

    return try root.emit_dtb(a);
}

fn name_unit_addr(
    name: []const u8,
    unit_addr: u64,
    a: std.mem.Allocator,
) ![]u8 {
    // unit_addr when writen as hex can take up at most 16 bytes
    var num_buf: [16]u8 = undefined;
    const num = std.fmt.bufPrintIntToSlice(
        &num_buf,
        unit_addr,
        16,
        .lower,
        .{},
    );
    var buf = try a.alloc(u8, name.len + 1 + num.len);
    const string = std.fmt.bufPrint(
        buf[0..buf.len],
        "{s}@{s}",
        .{ name, num },
    ) catch unreachable;
    std.debug.assert(num.len <= 16);
    std.debug.assert(string.len == buf.len);
    return string;
}

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
