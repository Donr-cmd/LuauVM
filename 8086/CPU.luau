local OPCODES = require("./Opcodes")
local Types = require("./Types")
type CPU = Types.CPU


local CPU: any = {}
CPU.__index = CPU

function CPU.new(RAM)
    local self = setmetatable({}, CPU)
    self.RAM = RAM
    self.Registers = buffer.create(16)

    self.IP = 0
    self.ES = 0
    self.CS = 0xFFFF
    self.SS = 0
    self.DS = 0
    self.SI = 0
    self.DI = 0
    self.BP = 0

    self.SegmentOverride = nil
    self.REPNE = false
    self.REP = false

    self.FLAGS = 0b10

    self.Halted = false
    self.PendingIRQ = nil
    self.PendingNMI = false

    self.PortIn  = {}
    self.PortOut = {}

    return self
end

local PREFIXES = {
    [0x26] = function(cpu: CPU) cpu.SegmentOverride = cpu.ES end,
    [0x2E] = function(cpu: CPU) cpu.SegmentOverride = cpu.CS end,
    [0x36] = function(cpu: CPU) cpu.SegmentOverride = cpu.SS end,
    [0x3E] = function(cpu: CPU) cpu.SegmentOverride = cpu.DS end,
    [0xF0] = function(cpu: CPU) end,
    [0xF2] = function(cpu: CPU) cpu.REPNE = true end,
    [0xF3] = function(cpu: CPU) cpu.REP = true end,
}

function CPU:Step()
    if self.PendingNMI then
        self.PendingNMI = false
        self.Halted = false
        local sp = bit32.band(buffer.readu16(self.Registers, 8) - 2, 0xFFFF)
        buffer.writeu16(self.RAM, bit32.band(self.SS * 16 + sp, 0xFFFFF), self.FLAGS)
        sp = bit32.band(sp - 2, 0xFFFF)
        buffer.writeu16(self.RAM, bit32.band(self.SS * 16 + sp, 0xFFFFF), self.CS)
        sp = bit32.band(sp - 2, 0xFFFF)
        buffer.writeu16(self.RAM, bit32.band(self.SS * 16 + sp, 0xFFFFF), self.IP)
        buffer.writeu16(self.Registers, 8, sp)
        self.FLAGS = bit32.band(self.FLAGS, 0xFCFF)
        self.IP = buffer.readu16(self.RAM, 2 * 4)      -- INT 2 = NMI
        self.CS = buffer.readu16(self.RAM, 2 * 4 + 2)
    end

    if self.PendingIRQ and bit32.extract(self.FLAGS, 9) == 1 then
        local n: number = self.PendingIRQ :: number
        self.PendingIRQ = nil
        self.Halted = false
        local sp = bit32.band(buffer.readu16(self.Registers, 8) - 2, 0xFFFF)
        buffer.writeu16(self.RAM, bit32.band(self.SS * 16 + sp, 0xFFFFF), self.FLAGS)
        sp = bit32.band(sp - 2, 0xFFFF)
        buffer.writeu16(self.RAM, bit32.band(self.SS * 16 + sp, 0xFFFFF), self.CS)
        sp = bit32.band(sp - 2, 0xFFFF)
        buffer.writeu16(self.RAM, bit32.band(self.SS * 16 + sp, 0xFFFFF), self.IP)
        buffer.writeu16(self.Registers, 8, sp)
        self.FLAGS = bit32.band(self.FLAGS, 0xFCFF)
        self.IP = buffer.readu16(self.RAM, n * 4)
        self.CS = buffer.readu16(self.RAM, n * 4 + 2)
    end

    if self.Halted then return end

    local tf = bit32.extract(self.FLAGS, 8) == 1

    self.SegmentOverride = nil
    self.REPNE = false
    self.REP = false
    while true do
        local addr = bit32.band(self.CS * 16 + self.IP, 0xFFFFF)
        local byte = buffer.readu8(self.RAM, addr)
        self.IP = bit32.band(self.IP + 1, 0xFFFF)
        local prefix = PREFIXES[byte]
        if prefix then
            prefix(self)
        else
            OPCODES[byte](self)
            break
        end
    end

    if tf then
        local sp = bit32.band(buffer.readu16(self.Registers, 8) - 2, 0xFFFF)
        buffer.writeu16(self.RAM, bit32.band(self.SS * 16 + sp, 0xFFFFF), self.FLAGS)
        sp = bit32.band(sp - 2, 0xFFFF)
        buffer.writeu16(self.RAM, bit32.band(self.SS * 16 + sp, 0xFFFFF), self.CS)
        sp = bit32.band(sp - 2, 0xFFFF)
        buffer.writeu16(self.RAM, bit32.band(self.SS * 16 + sp, 0xFFFFF), self.IP)
        buffer.writeu16(self.Registers, 8, sp)
        self.FLAGS = bit32.band(self.FLAGS, 0xFCFF)
        self.IP = buffer.readu16(self.RAM, 1 * 4)
        self.CS = buffer.readu16(self.RAM, 1 * 4 + 2)
    end
end

function CPU:RaiseIRQ(n)
    self.PendingIRQ = n
end

function CPU:TriggerNMI()
    self.PendingNMI = true
end

return CPU