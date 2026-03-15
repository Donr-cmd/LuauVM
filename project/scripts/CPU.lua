--!nocheck
--!nolint
--!optimize 2
--!native

local OPCODES = require(script:WaitForChild("Opcodes"))
local INT_IMPL = OPCODES._INT

local CPU = {}
CPU.__index = CPU

function CPU.new(RAM)
	local self = setmetatable({}, CPU)
	self.RAM = RAM

	-- General purpose registers
	self.EAX = 0
	self.EBX = 0
	self.ECX = 0
	self.EDX = 0
	self.ESI = 0
	self.EDI = 0
	self.ESP = 0
	self.EBP = 0

	-- Segment registers + descriptor caches
	self.CS = 0;  self.CSBase = 0;  self.CSLimit = 0xFFFF;  self.CSAccess = 0x9B;  self.CSD = 0
	self.DS = 0;  self.DSBase = 0;  self.DSLimit = 0xFFFF;  self.DSAccess = 0x93
	self.SS = 0;  self.SSBase = 0;  self.SSLimit = 0xFFFF;  self.SSAccess = 0x93
	self.ES = 0;  self.ESBase = 0;  self.ESLimit = 0xFFFF;  self.ESAccess = 0x93
	self.FS = 0;  self.FSBase = 0;  self.FSLimit = 0xFFFF;  self.FSAccess = 0x93
	self.GS = 0;  self.GSBase = 0;  self.GSLimit = 0xFFFF;  self.GSAccess = 0x93

	-- Task register + LDT register
	self.TR   = 0;  self.TRBase   = 0;  self.TRLimit   = 0;  self.TRAccess   = 0
	self.LDTR = 0;  self.LDTRBase = 0;  self.LDTRLimit = 0;  self.LDTRAccess = 0

	-- Descriptor table registers
	self.GDTRBase = 0;  self.GDTRLimit = 0
	self.IDTRBase = 0;  self.IDTRLimit = 0x3FF

	-- Instruction pointer + flags
	self.EIP    = 0
	self.EFLAGS = 0x00000002

	-- Current privilege level
	self.CPL = 0

	-- Control registers
	self.CR0 = 0
	self.CR2 = 0
	self.CR3 = 0

	-- Debug registers
	self.DR6 = 0xFFFF0FF0
	self.DR7 = 0x00000400

	-- TLB (invalidated on CR3 write / task switch)
	self.TLB = {}

	-- Exception tracking
	self._exception_depth = 0
	self.pf_error_code    = 0

	-- A20 gate
	self.A20 = true

	-- Prefix state
	self.SEG_OVERRIDE      = nil
	self.REP               = nil
	self.OPSIZE_OVERRIDE   = false
	self.ADDRSIZE_OVERRIDE = false

	-- FPU state
	self.FPU_ST  = {[0]=0,0,0,0,0,0,0,0}
	self.FPU_TOP = 0
	self.FPU_SW  = 0
	self.FPU_CW  = 0x037F
	self.FPU_TW  = 0xFFFF

	-- I/O ports
	self.PortsIn = {}
	self.PortsOut = {}
	for i = 0, 0x3FF do
		self.PortsIn[i] = function() return 0xFF end
		self.PortsOut[i] = function() end
	end

	return self
end

local PREFIXES = {
	[0x26] = function(cpu) cpu.SEG_OVERRIDE    = "ES"    end,
	[0x2E] = function(cpu) cpu.SEG_OVERRIDE    = "CS"    end,
	[0x36] = function(cpu) cpu.SEG_OVERRIDE    = "SS"    end,
	[0x3E] = function(cpu) cpu.SEG_OVERRIDE    = "DS"    end,
	[0x64] = function(cpu) cpu.SEG_OVERRIDE    = "FS"    end,
	[0x65] = function(cpu) cpu.SEG_OVERRIDE    = "GS"    end,
	[0x66] = function(cpu) cpu.OPSIZE_OVERRIDE  = true   end,
	[0x67] = function(cpu) cpu.ADDRSIZE_OVERRIDE = true  end,
	[0xF0] = function(cpu)                               end,
	[0xF2] = function(cpu) cpu.REP             = "REPNE" end,
	[0xF3] = function(cpu) cpu.REP             = "REP"   end,
}

function CPU:Step()
	self.SEG_OVERRIDE      = nil
	self.REP               = nil
	self.OPSIZE_OVERRIDE   = false
	self.ADDRSIZE_OVERRIDE = false

	local byte = buffer.readu8(self.RAM, self.CSBase + self.EIP)
	self.EIP += 1

	local pfx = PREFIXES[byte]
	while pfx do
		pfx(self)
		byte = buffer.readu8(self.RAM, self.CSBase + self.EIP)
		self.EIP += 1
		pfx = PREFIXES[byte]
	end

	OPCODES[byte](self)
end

CPU.INT = INT_IMPL

return CPU