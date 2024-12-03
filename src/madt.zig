const sdt = @import("sdt.zig");
const util = @import("util");
const checksum = util.checksum;
const WindowStructIndexer = util.WindowStructIndexer;

const apic = @import("../apic/apic.zig");
const log = @import("acpi.zig").log;
const std = @import("std");

const PhysAddr = @import("cmn").types.PhysAddr;

const assert = std.debug.assert;

pub const MadtFlags = packed struct(u32) {
    pcat_compat: bool,
    _: u31,
};

pub const Madt = extern struct {
    header: sdt.SystemDescriptorTableHeader,
    lapic_addr: u32,
    flags: MadtFlags,

    pub usingnamespace checksum.add_acpi_checksum(Madt);
};

const MadtEntryType = enum(u8) {
    local_apic = 0,
    io_apic,
    interrupt_source_override,
    nmi_source,
    local_nmi,
    local_apic_addr_override,
    io_sapic,
    local_sapic,
    platform_interrupt_sources,
    proc_local_x2apic,
    local_x2apic_nmi,
    gic_cpu_interface,
    gic_msi_frame,
    gic_redistributor,
    gic_interrupt_translation_service,
    multiprocessor_wakeup,
    _,
};

const MadtEntryHeader = extern struct {
    type: MadtEntryType,
    length: u8,
};

pub const MadtInterruptSourceFlags = packed struct(u16) {
    polarity: apic.AcpiPolarity,
    trigger: apic.AcpiTrigger,
    _: u12 = 0,
};

fn MadtEntryPayload(comptime t: MadtEntryType) type {
    return switch (t) {
        .local_apic => extern struct {
            header: MadtEntryHeader,
            processor_uid: u8,
            local_apic_id: u8,
            flags: packed struct(u32) {
                enabled: bool,
                online_capable: bool,
                _: u30,
            },
        },
        .local_nmi => extern struct {
            header: MadtEntryHeader align(4),
            processor_uid: u8,
            flags: MadtInterruptSourceFlags align(1),
            pin: u8,
        },
        .local_apic_addr_override => extern struct {
            header: MadtEntryHeader align(4),
            lapic_addr: PhysAddr align(4),
        },
        .io_apic => extern struct {
            header: MadtEntryHeader,
            ioapic_id: u8,
            ioapic_addr: u32 align(4),
            gsi_base: u32 align(4),
        },
        .interrupt_source_override => extern struct {
            header: MadtEntryHeader,
            bus: u8,
            source: u8,
            gsi: u32,
            flags: MadtInterruptSourceFlags align(1),
        },
        else => void,
    };
}

pub fn read_madt(ptr: *align(1) const Madt) !void {
    apic.lapics = try apic.Lapics.init(0);
    var uid_nmi_pins: [256]apic.LapicNmiPin = undefined;
    log.info("APIC MADT table loaded at {*}", .{ptr});
    var lapic_ptr: PhysAddr = @enumFromInt(ptr.lapic_addr);
    const entries_base_ptr = @as([*]const u8, @ptrCast(ptr))[@sizeOf(Madt)..ptr.header.length];
    var indexer = WindowStructIndexer(MadtEntryHeader){ .buf = entries_base_ptr };
    while (indexer.offset < entries_base_ptr.len) {
        const hdr = indexer.current();
        defer indexer.advance(hdr.length);

        switch (hdr.type) {
            .local_apic => {
                const payload = @as(*align(1) const MadtEntryPayload(.local_apic), @ptrCast(hdr));
                assert(hdr.length == 8);
                const idx = try apic.lapics.append(.{
                    .id = payload.local_apic_id,
                    .enabled = payload.flags.enabled,
                    .online_capable = payload.flags.online_capable,
                    .uid = payload.processor_uid,
                    .nmi_pins = .{
                        .pin = .none,
                        .polarity = .default,
                        .trigger = .default,
                    },
                });
                apic.lapic_indices[payload.local_apic_id] = idx;
            },
            .io_apic => {
                const payload = @as(*align(1) const MadtEntryPayload(.io_apic), @ptrCast(hdr));
                assert(hdr.length == 12);

                log.debug("IOApic: gsi base {x}", .{payload.gsi_base});
                apic.ioapic.ioapics_buf[@atomicRmw(u8, &apic.ioapic.ioapics_count, .Add, 1, .monotonic)] = .{
                    .id = payload.ioapic_id,
                    .phys_addr = @import("../arch/arch.zig").ptr_from_physaddr([*]volatile u32, @enumFromInt(payload.ioapic_addr)),
                    .gsi_base = payload.gsi_base,
                };
            },
            .interrupt_source_override => {
                const payload = @as(*align(1) const MadtEntryPayload(.interrupt_source_override), @ptrCast(hdr));
                assert(payload.bus == 0);
                log.debug("ISA IRQ Redirect: IRQ#{d} -> GSI#{d}, polarity {} trigger {}", .{ payload.source, payload.gsi, payload.flags.polarity, payload.flags.trigger });
                apic.ioapic.isa_irqs[payload.source] = .{
                    .gsi = payload.gsi,
                    .polarity = switch (payload.flags.polarity) {
                        .default, .active_high => .active_high,
                        .active_low => .active_low,
                        else => unreachable,
                    },
                    .trigger = switch (payload.flags.trigger) {
                        .default, .edge_triggered => .edge,
                        .level_triggered => .level,
                        else => unreachable,
                    },
                };
            },
            .local_apic_addr_override => {
                const payload = @as(*align(1) const MadtEntryPayload(.local_apic_addr_override), @ptrCast(hdr));
                assert(hdr.length == 12);

                lapic_ptr = payload.lapic_addr;
            },
            .local_nmi => {
                const payload = @as(*align(1) const MadtEntryPayload(.local_nmi), @ptrCast(hdr));
                assert(hdr.length == 6);
                const info: apic.LapicNmiPin = .{
                    .pin = switch (payload.pin) {
                        0 => .lint0,
                        1 => .lint1,
                        else => .none,
                    },
                    .trigger = payload.flags.trigger,
                    .polarity = payload.flags.polarity,
                };
                if (payload.processor_uid == 0xFF) {
                    @memset(&uid_nmi_pins, info);
                } else {
                    uid_nmi_pins[payload.processor_uid] = info;
                }
            },
            else => {
                log.debug("Found MADT payload {x}", .{hdr.type});
            },
        }
    }
    for (apic.lapics.items(.uid), apic.lapics.items(.nmi_pins)) |uid, *pins| {
        pins.* = uid_nmi_pins[uid];
    }
    log.info("LAPIC base at phys {x}", .{@intFromEnum(lapic_ptr)});
    apic.lapic_ptr = @import("../arch/arch.zig").ptr_from_physaddr([*]volatile u32, lapic_ptr);
}

test {
    _ = Madt;
    _ = MadtEntryPayload;
    _ = read_madt;
}
