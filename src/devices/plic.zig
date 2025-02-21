// Platform-Level Interrupt Controller

const Exception = @import("../exception.zig").Exception;
const Hart = @import("../hart.zig");
const std = @import("std");
const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;
const assert = std.debug.assert;

const PLIC = @This();

// number of interrupts supported by the PLIC
// including interrupt source 0 which does not exist
pub const n_interrupts = 2;

// which interrupts are pending
pending: [n_interrupts]bool,
// which interrupts are enabled on context 0 (hart 0 M-mode)
ctx0_enable: [n_interrupts]bool,
// priority threshold for context 0 (hart 0 M-mode)
// an interrupt is masked if <= this threshold
ctx0_priority_threshold: u1,

// hart that this PLIC is connected to
ctx0: *Hart,

// the PLIC is not ran in its own thread,
// devices that signal interrupts and MMIO accesses will assume the role
// of the PLIC and update its state and the state of the external
// interrupt pending bits for each context, operating the PLIC is guarded by this mutex
mutex: Mutex,

// interrupt priority register
// we implement all interrupts with fixed priority of 1
const reg_priority = 0x0;
const reg_priority_last = reg_priority + (4 * (n_interrupts - 1));

const reg_pending = 0x1000;
const reg_ctx0_enable = 0x2000;
const reg_ctx0_threshold = 0x20_0000;
const reg_ctx0_claim = 0x20_0004;

pub const mmio_len = 0x400_0000;

pub fn mmio_reg_read(plic: *PLIC, comptime T: type, reg_addr: u64) !T {
    if (comptime T != u32) return Exception.LoadAccessFault;
    plic.mutex.lock();
    defer plic.mutex.unlock();
    errdefer plic.mutex.unlock();
    switch (reg_addr) {
        reg_priority...reg_priority_last => {
            const interrupt_num = (reg_addr - reg_priority) / 4;
            assert(interrupt_num <= n_interrupts);
            // all priorities are fixed to 1, interrupt source 0 is fixed to 0
            return if (interrupt_num == 0) 0 else 1;
        },
        reg_pending => {
            var v: u32 = 0;
            var interrupt: u32 = 1;
            while (interrupt < n_interrupts) : (interrupt += 1) {
                v |= @as(T, @intFromBool(plic.pending[interrupt])) << @truncate(interrupt);
            }
            return v;
        },
        reg_ctx0_enable => {
            var v: u32 = 0;
            var interrupt: u32 = 1;
            while (interrupt < n_interrupts) : (interrupt += 1) {
                v |= @as(T, @intFromBool(plic.pending[interrupt])) << @truncate(interrupt);
            }
            return v;
        },
        reg_ctx0_threshold => {
            return reg_ctx0_threshold;
        },
        reg_ctx0_claim => {
            defer plic.update();
            var interrupt: u32 = 1;
            while (interrupt < n_interrupts) : (interrupt += 1) {
                if (plic.ctx0_enable[interrupt] and plic.pending[interrupt]) {
                    plic.pending[interrupt] = false;
                    return interrupt;
                }
            }
            return 0;
        },
        else => return Exception.LoadAccessFault,
    }
}

pub fn mmio_reg_write(plic: *PLIC, comptime T: type, reg_addr: u64, v: T) !void {
    if (comptime T != u32) return Exception.StoreAccessFault;
    plic.mutex.lock();
    defer plic.mutex.unlock();
    errdefer plic.mutex.unlock();
    switch (reg_addr) {
        reg_priority...reg_priority_last => {
            const interrupt_num = (reg_addr - reg_priority) / 4;
            assert(interrupt_num < n_interrupts);
            return; // our priorities are fixed
        },
        reg_pending => return Exception.StoreAccessFault,
        reg_ctx0_enable => {
            defer plic.update();
            var interrupt: u32 = 1;
            while (interrupt < n_interrupts) : (interrupt += 1) {
                plic.ctx0_enable[interrupt] = (v >> @truncate(interrupt)) & 0b1 == 0b1;
            }
            return;
        },
        reg_ctx0_threshold => {
            defer plic.update();
            plic.ctx0_priority_threshold = @truncate(v);
            return;
        },
        reg_ctx0_claim => {
            // do nothing successfully?
            return;
        },
        else => return Exception.StoreAccessFault,
    }
}

// update the external interrupt pending bit for each context
// should be called while the PLIC mutex is held and after reads/writes
// that claim or modify pending interrupts
fn update(plic: *PLIC) void {
    var int: u32 = 1;
    var external_interrupt_pending: bool = false;
    defer plic.ctx0.set_interrupt_pending(.External, external_interrupt_pending);

    while (int < n_interrupts) : (int += 1) {
        if (plic.pending[int] and plic.ctx0_enable[int] and 1 > plic.ctx0_priority_threshold) {
            external_interrupt_pending = true;
            break;
        }
    }
}

pub fn set_interrupt_pending(plic: *PLIC, interrupt_num: u32, v: bool) void {
    assert(interrupt_num > 0 and interrupt_num < n_interrupts);

    plic.mutex.lock();
    plic.pending[interrupt_num] = v;
    plic.update();
    plic.mutex.unlock();
}

pub fn create() PLIC {
    return PLIC{
        .pending = .{false} ** n_interrupts,
        .ctx0_enable = .{false} ** n_interrupts,
        .ctx0_priority_threshold = 0,
        .ctx0 = undefined,
        .mutex = Mutex{},
    };
}
