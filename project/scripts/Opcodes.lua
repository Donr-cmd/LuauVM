--!optimize 2
--!nocheck
--!native

-- SEG_BASE: eliminates seg.."Base" string concat on every memory access
local SEG_BASE = {
	ES="ESBase", CS="CSBase", SS="SSBase",
	DS="DSBase", FS="FSBase", GS="GSBase",
}

-- PARITY_LUT: precomputed 8-bit parity (1 = even parity, PF set), avoids 3-XOR chain per flag update
local PARITY_LUT = {}
do
	local p
	for _i = 0, 255 do
		p = _i
		p = bit32.bxor(p, bit32.rshift(p, 4))
		p = bit32.bxor(p, bit32.rshift(p, 2))
		p = bit32.bxor(p, bit32.rshift(p, 1))
		PARITY_LUT[_i] = bit32.bnot(p) % 2
	end
end


-- REG_GET/SET: eliminates REG_MAP[reg] double table lookup on every reg access
local REG_GET = {
	[0]=function(cpu,b) return bit32.extract(cpu.EAX,0,b) end,
	[1]=function(cpu,b) return bit32.extract(cpu.ECX,0,b) end,
	[2]=function(cpu,b) return bit32.extract(cpu.EDX,0,b) end,
	[3]=function(cpu,b) return bit32.extract(cpu.EBX,0,b) end,
	[4]=function(cpu,b) return bit32.extract(cpu.ESP,0,b) end,
	[5]=function(cpu,b) return bit32.extract(cpu.EBP,0,b) end,
	[6]=function(cpu,b) return bit32.extract(cpu.ESI,0,b) end,
	[7]=function(cpu,b) return bit32.extract(cpu.EDI,0,b) end,
}
local REG_GET8H = {
	[4]=function(cpu) return bit32.extract(cpu.EAX,8,8) end,
	[5]=function(cpu) return bit32.extract(cpu.ECX,8,8) end,
	[6]=function(cpu) return bit32.extract(cpu.EDX,8,8) end,
	[7]=function(cpu) return bit32.extract(cpu.EBX,8,8) end,
}
local REG_SET = {
	[0]=function(cpu,v,b) cpu.EAX=bit32.replace(cpu.EAX,bit32.band(v,bit32.lshift(1,b)-1),0,b) end,
	[1]=function(cpu,v,b) cpu.ECX=bit32.replace(cpu.ECX,bit32.band(v,bit32.lshift(1,b)-1),0,b) end,
	[2]=function(cpu,v,b) cpu.EDX=bit32.replace(cpu.EDX,bit32.band(v,bit32.lshift(1,b)-1),0,b) end,
	[3]=function(cpu,v,b) cpu.EBX=bit32.replace(cpu.EBX,bit32.band(v,bit32.lshift(1,b)-1),0,b) end,
	[4]=function(cpu,v,b) cpu.ESP=bit32.replace(cpu.ESP,bit32.band(v,bit32.lshift(1,b)-1),0,b) end,
	[5]=function(cpu,v,b) cpu.EBP=bit32.replace(cpu.EBP,bit32.band(v,bit32.lshift(1,b)-1),0,b) end,
	[6]=function(cpu,v,b) cpu.ESI=bit32.replace(cpu.ESI,bit32.band(v,bit32.lshift(1,b)-1),0,b) end,
	[7]=function(cpu,v,b) cpu.EDI=bit32.replace(cpu.EDI,bit32.band(v,bit32.lshift(1,b)-1),0,b) end,
}
local REG_SET8H = {
	[4]=function(cpu,v) cpu.EAX=bit32.replace(cpu.EAX,v,8,8) end,
	[5]=function(cpu,v) cpu.ECX=bit32.replace(cpu.ECX,v,8,8) end,
	[6]=function(cpu,v) cpu.EDX=bit32.replace(cpu.EDX,v,8,8) end,
	[7]=function(cpu,v) cpu.EBX=bit32.replace(cpu.EBX,v,8,8) end,
}
local REG_READ32 = {
	[0]=function(cpu) return cpu.EAX end,
	[1]=function(cpu) return cpu.ECX end,
	[2]=function(cpu) return cpu.EDX end,
	[3]=function(cpu) return cpu.EBX end,
	[4]=function(cpu) return cpu.ESP end,
	[5]=function(cpu) return cpu.EBP end,
	[6]=function(cpu) return cpu.ESI end,
	[7]=function(cpu) return cpu.EDI end,
}
local REG_BSWAP = {
	[0]=function(cpu,v) cpu.EAX=v end,
	[1]=function(cpu,v) cpu.ECX=v end,
	[2]=function(cpu,v) cpu.EDX=v end,
	[3]=function(cpu,v) cpu.EBX=v end,
	[4]=function(cpu,v) cpu.ESP=v end,
	[5]=function(cpu,v) cpu.EBP=v end,
	[6]=function(cpu,v) cpu.ESI=v end,
	[7]=function(cpu,v) cpu.EDI=v end,
}

local function phys(cpu, addr)
	return cpu.A20 and addr or bit32.band(addr, 0xFFEFFFFF)
end

local ADDR16_LOOKUP = {
	[0] = function(cpu) return (cpu.EBX + cpu.ESI) % 0x10000 end,
	[1] = function(cpu) return (cpu.EBX + cpu.EDI) % 0x10000 end,
	[2] = function(cpu) return (cpu.EBP + cpu.ESI) % 0x10000 end,
	[3] = function(cpu) return (cpu.EBP + cpu.EDI) % 0x10000 end,
	[4] = function(cpu) return cpu.ESI % 0x10000 end,
	[5] = function(cpu) return cpu.EDI % 0x10000 end,
	[6] = function(cpu) return cpu.EBP % 0x10000 end,
	[7] = function(cpu) return cpu.EBX % 0x10000 end,
}

local function EA16(cpu, mod, rm)
	local ea
	if mod == 0 and rm == 6 then
		ea = buffer.readu16(cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
		cpu.EIP += 2
	else
		ea = ADDR16_LOOKUP[rm](cpu)
	end

	if mod == 0b01 then
		local disp = buffer.readi8(cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
		cpu.EIP += 1
		ea += disp
	elseif mod == 0b10 then
		local disp = buffer.readi16(cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
		cpu.EIP += 2
		ea += disp
	end

	return bit32.extract(ea, 0, 16)
end

local function LA16(cpu, mod, rm)
	local offset = EA16(cpu, mod, rm)
	local defaultSeg = (rm == 2 or rm == 3 or (rm == 6 and mod ~= 0)) and "SSBase" or "DSBase"
	local seg = cpu.SEG_OVERRIDE
	local base = seg and cpu[SEG_BASE[seg]] or cpu[defaultSeg]
	return phys(cpu, base + offset)
end

local BUF_READ  = { [8] = buffer.readu8,  [16] = buffer.readu16, [32] = buffer.readu32 }
local BUF_WRITE = { [8] = buffer.writeu8, [16] = buffer.writeu16, [32] = buffer.writeu32 }

local function readR(cpu, reg, bits)
	if bits == 8 and reg >= 4 then return REG_GET8H[reg](cpu) end
	return REG_GET[reg](cpu, bits)
end

local function writeR(cpu, reg, val, bits)
	if bits == 8 and reg >= 4 then REG_SET8H[reg](cpu, val)
	else REG_SET[reg](cpu, val, bits) end
end

local function readRM(cpu, mod, rm, bits)
	if mod == 3 then return readR(cpu, rm, bits) end
	return BUF_READ[bits](cpu.RAM, LA16(cpu, mod, rm))
end

local function writeRM(cpu, mod, rm, val, bits)
	if mod == 3 then writeR(cpu, rm, val, bits); return end
	BUF_WRITE[bits](cpu.RAM, LA16(cpu, mod, rm), bit32.band(val, bit32.lshift(1, bits) - 1))
end

local function ModRM(cpu)
	local modrm = buffer.readu8(cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += 1
	local mod = bit32.extract(modrm, 6, 2)
	local reg = bit32.extract(modrm, 3, 3)
	local rm  = bit32.extract(modrm, 0, 3)
	return mod, reg, rm
end

local function fetchRMR(cpu, bits)
	local mod, reg, rm = ModRM(cpu)
	return mod, reg, rm, readRM(cpu, mod, rm, bits), readR(cpu, reg, bits)
end

local function fetchRRM(cpu, bits)
	local mod, reg, rm = ModRM(cpu)
	return mod, reg, rm, readR(cpu, reg, bits), readRM(cpu, mod, rm, bits)
end

local function fetchAccImm(cpu, bits)
	local b = BUF_READ[bits](cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += bits // 8
	return readR(cpu, 0, bits), b
end

local function OS(cpu)
	local d = cpu.CSD == 1
	return (d ~= cpu.OPSIZE_OVERRIDE) and 32 or 16
end

local OPCODES = {}
local OPCODES_0F = {}


local function setFlagsAdd(cpu, a, b, result, bits)
	local mask = bit32.lshift(1, bits) - 1
	local r  = bit32.band(result, mask)
	local cf = result > mask and 1 or 0
	local zf = r == 0 and 1 or 0
	local sf = bit32.extract(r, bits - 1, 1)
	local af = bit32.extract(bit32.bxor(a, b, r), 4, 1)
	local of = bit32.extract(bit32.band(bit32.bxor(a, r), bit32.bxor(b, r)), bits - 1, 1)
	local p  = PARITY_LUT[bit32.band(r, 0xFF)]
	cpu.EFLAGS = bit32.bor(
		bit32.band(cpu.EFLAGS, 0xFFFFF72E),
		cf, bit32.lshift(p, 2), bit32.lshift(af, 4),
		bit32.lshift(zf, 6), bit32.lshift(sf, 7), bit32.lshift(of, 11))
end

local function addRMR(cpu, bits)
	local mod, _reg, rm, a, b = fetchRMR(cpu, bits)
	local result = a + b
	writeRM(cpu, mod, rm, result, bits)
	setFlagsAdd(cpu, a, b, result, bits)
end

local function addRRM(cpu, bits)
	local _mod, reg, _rm, a, b = fetchRRM(cpu, bits)
	local result = a + b
	writeR(cpu, reg, result, bits)
	setFlagsAdd(cpu, a, b, result, bits)
end

local function addAccImm(cpu, bits)
	local a, b = fetchAccImm(cpu, bits)
	local result = a + b
	writeR(cpu, 0, result, bits)
	setFlagsAdd(cpu, a, b, result, bits)
end

OPCODES[0x00] = function(cpu) addRMR(cpu, 8)          end -- ADD r/m8, r8
OPCODES[0x01] = function(cpu) addRMR(cpu, OS(cpu))    end -- ADD r/m16/32, r16/32
OPCODES[0x02] = function(cpu) addRRM(cpu, 8)          end -- ADD r8, r/m8
OPCODES[0x03] = function(cpu) addRRM(cpu, OS(cpu))    end -- ADD r16/32, r/m16/32
OPCODES[0x04] = function(cpu) addAccImm(cpu, 8)       end -- ADD AL, imm8
OPCODES[0x05] = function(cpu) addAccImm(cpu, OS(cpu)) end -- ADD AX/EAX, imm16/32

OPCODES[0x06] = function(cpu)                             -- PUSH ES
	cpu.ESP -= 2
	buffer.writeu16(cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), cpu.ES)
end

OPCODES[0x07] = function(cpu)                             -- POP ES
	local val = buffer.readu16(cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP))
	cpu.ESP += 2
	cpu.ES = val
	cpu.ESBase = val * 16
end


local function setFlagsLogic(cpu, result, bits)
	local r  = bit32.band(result, bit32.lshift(1, bits) - 1)
	local zf = r == 0 and 1 or 0
	local sf = bit32.extract(r, bits - 1, 1)
	local p  = PARITY_LUT[bit32.band(r, 0xFF)]
	cpu.EFLAGS = bit32.bor(
		bit32.band(cpu.EFLAGS, 0xFFFFF72E),
		bit32.lshift(p, 2),
		bit32.lshift(zf, 6), bit32.lshift(sf, 7))
end

local function orRMR(cpu, bits)
	local mod, _reg, rm, a, b = fetchRMR(cpu, bits)
	local result = bit32.bor(a, b)
	writeRM(cpu, mod, rm, result, bits)
	setFlagsLogic(cpu, result, bits)
end

local function orRRM(cpu, bits)
	local _mod, reg, _rm, a, b = fetchRRM(cpu, bits)
	local result = bit32.bor(a, b)
	writeR(cpu, reg, result, bits)
	setFlagsLogic(cpu, result, bits)
end

local function orAccImm(cpu, bits)
	local a, b = fetchAccImm(cpu, bits)
	local result = bit32.bor(a, b)
	writeR(cpu, 0, result, bits)
	setFlagsLogic(cpu, result, bits)
end

OPCODES[0x08] = function(cpu) orRMR(cpu, 8)          end -- OR r/m8, r8
OPCODES[0x09] = function(cpu) orRMR(cpu, OS(cpu))    end -- OR r/m16/32, r16/32
OPCODES[0x0A] = function(cpu) orRRM(cpu, 8)          end -- OR r8, r/m8
OPCODES[0x0B] = function(cpu) orRRM(cpu, OS(cpu))    end -- OR r16/32, r/m16/32
OPCODES[0x0C] = function(cpu) orAccImm(cpu, 8)       end -- OR AL, imm8
OPCODES[0x0D] = function(cpu) orAccImm(cpu, OS(cpu)) end -- OR AX/EAX, imm16/32

OPCODES[0x0E] = function(cpu)                             -- PUSH CS
	cpu.ESP -= 2
	buffer.writeu16(cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), cpu.CS)
end

OPCODES[0x0F] = function(cpu)                             -- 2-byte escape
	local byte = buffer.readu8(cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += 1
	OPCODES_0F[byte](cpu)
end


local function adcRMR(cpu, bits)
	local mod, _reg, rm, a, b = fetchRMR(cpu, bits)
	local cf = bit32.extract(cpu.EFLAGS, 0, 1)
	local result = a + b + cf
	writeRM(cpu, mod, rm, result, bits)
	setFlagsAdd(cpu, a, b + cf, result, bits)
end

local function adcRRM(cpu, bits)
	local _mod, reg, _rm, a, b = fetchRRM(cpu, bits)
	local cf = bit32.extract(cpu.EFLAGS, 0, 1)
	local result = a + b + cf
	writeR(cpu, reg, result, bits)
	setFlagsAdd(cpu, a, b + cf, result, bits)
end

local function adcAccImm(cpu, bits)
	local a, b = fetchAccImm(cpu, bits)
	local cf = bit32.extract(cpu.EFLAGS, 0, 1)
	local result = a + b + cf
	writeR(cpu, 0, result, bits)
	setFlagsAdd(cpu, a, b + cf, result, bits)
end

OPCODES[0x10] = function(cpu) adcRMR(cpu, 8)          end -- ADC r/m8, r8
OPCODES[0x11] = function(cpu) adcRMR(cpu, OS(cpu))    end -- ADC r/m16/32, r16/32
OPCODES[0x12] = function(cpu) adcRRM(cpu, 8)          end -- ADC r8, r/m8
OPCODES[0x13] = function(cpu) adcRRM(cpu, OS(cpu))    end -- ADC r16/32, r/m16/32
OPCODES[0x14] = function(cpu) adcAccImm(cpu, 8)       end -- ADC AL, imm8
OPCODES[0x15] = function(cpu) adcAccImm(cpu, OS(cpu)) end -- ADC AX/EAX, imm16/32

OPCODES[0x16] = function(cpu)                             -- PUSH SS
	cpu.ESP -= 2
	buffer.writeu16(cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), cpu.SS)
end

OPCODES[0x17] = function(cpu)                             -- POP SS
	local val = buffer.readu16(cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP))
	cpu.ESP += 2
	cpu.SS = val
	cpu.SSBase = val * 16
end


local function setFlagsSub(cpu, a, b, result, bits)
	local mask = bit32.lshift(1, bits) - 1
	local r  = bit32.band(result, mask)
	local cf = a < b and 1 or 0
	local zf = r == 0 and 1 or 0
	local sf = bit32.extract(r, bits - 1, 1)
	local af = bit32.extract(bit32.bxor(a, b, r), 4, 1)
	local of = bit32.extract(bit32.band(bit32.bxor(a, b), bit32.bxor(a, r)), bits - 1, 1)
	local p  = PARITY_LUT[bit32.band(r, 0xFF)]
	cpu.EFLAGS = bit32.bor(
		bit32.band(cpu.EFLAGS, 0xFFFFF72E),
		cf, bit32.lshift(p, 2), bit32.lshift(af, 4),
		bit32.lshift(zf, 6), bit32.lshift(sf, 7), bit32.lshift(of, 11))
end

local function sbbRMR(cpu, bits)
	local mod, _reg, rm, a, b = fetchRMR(cpu, bits)
	local cf = bit32.extract(cpu.EFLAGS, 0, 1)
	local result = a - b - cf
	writeRM(cpu, mod, rm, result, bits)
	setFlagsSub(cpu, a, b + cf, result, bits)
end

local function sbbRRM(cpu, bits)
	local _mod, reg, _rm, a, b = fetchRRM(cpu, bits)
	local cf = bit32.extract(cpu.EFLAGS, 0, 1)
	local result = a - b - cf
	writeR(cpu, reg, result, bits)
	setFlagsSub(cpu, a, b + cf, result, bits)
end

local function sbbAccImm(cpu, bits)
	local a, b = fetchAccImm(cpu, bits)
	local cf = bit32.extract(cpu.EFLAGS, 0, 1)
	local result = a - b - cf
	writeR(cpu, 0, result, bits)
	setFlagsSub(cpu, a, b + cf, result, bits)
end

OPCODES[0x18] = function(cpu) sbbRMR(cpu, 8)          end -- SBB r/m8, r8
OPCODES[0x19] = function(cpu) sbbRMR(cpu, OS(cpu))    end -- SBB r/m16/32, r16/32
OPCODES[0x1A] = function(cpu) sbbRRM(cpu, 8)          end -- SBB r8, r/m8
OPCODES[0x1B] = function(cpu) sbbRRM(cpu, OS(cpu))    end -- SBB r16/32, r/m16/32
OPCODES[0x1C] = function(cpu) sbbAccImm(cpu, 8)       end -- SBB AL, imm8
OPCODES[0x1D] = function(cpu) sbbAccImm(cpu, OS(cpu)) end -- SBB AX/EAX, imm16/32

OPCODES[0x1E] = function(cpu)                             -- PUSH DS
	cpu.ESP -= 2
	buffer.writeu16(cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), cpu.DS)
end

OPCODES[0x1F] = function(cpu)                             -- POP DS
	local val = buffer.readu16(cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP))
	cpu.ESP += 2
	cpu.DS = val
	cpu.DSBase = val * 16
end


local function andRMR(cpu, bits)
	local mod, _reg, rm, a, b = fetchRMR(cpu, bits)
	local result = bit32.band(a, b)
	writeRM(cpu, mod, rm, result, bits)
	setFlagsLogic(cpu, result, bits)
end

local function andRRM(cpu, bits)
	local _mod, reg, _rm, a, b = fetchRRM(cpu, bits)
	local result = bit32.band(a, b)
	writeR(cpu, reg, result, bits)
	setFlagsLogic(cpu, result, bits)
end

local function andAccImm(cpu, bits)
	local a, b = fetchAccImm(cpu, bits)
	local result = bit32.band(a, b)
	writeR(cpu, 0, result, bits)
	setFlagsLogic(cpu, result, bits)
end

OPCODES[0x20] = function(cpu) andRMR(cpu, 8)          end -- AND r/m8, r8
OPCODES[0x21] = function(cpu) andRMR(cpu, OS(cpu))    end -- AND r/m16/32, r16/32
OPCODES[0x22] = function(cpu) andRRM(cpu, 8)          end -- AND r8, r/m8
OPCODES[0x23] = function(cpu) andRRM(cpu, OS(cpu))    end -- AND r16/32, r/m16/32
OPCODES[0x24] = function(cpu) andAccImm(cpu, 8)       end -- AND AL, imm8
OPCODES[0x25] = function(cpu) andAccImm(cpu, OS(cpu)) end -- AND AX/EAX, imm16/32

-- 0x26 = ES: prefix, handled in CPU:Step() prefix loop

OPCODES[0x27] = function(cpu)                             -- DAA
	local al = bit32.extract(cpu.EAX, 0, 8)
	local orig_al = al
	local af = bit32.extract(cpu.EFLAGS, 4, 1)
	local cf = bit32.extract(cpu.EFLAGS, 0, 1)
	local newcf = 0; local newaf = 0
	if af == 1 or bit32.band(al, 0xF) > 9 then
		al = al + 6
		newcf = (al > 0xFF) and 1 or cf
		newaf = 1
	end
	if cf == 1 or orig_al > 0x9F then
		al = al + 0x60
		newcf = 1
	end
	al = bit32.band(al, 0xFF)
	cpu.EAX = bit32.replace(cpu.EAX, al, 0, 8)
	setFlagsLogic(cpu, al, 8)
	local flags = cpu.EFLAGS
	flags = bit32.replace(flags, newcf, 0, 1)
	flags = bit32.replace(flags, newaf, 4, 1)
	cpu.EFLAGS = flags
end

local function subRMR(cpu, bits)
	local mod, _reg, rm, a, b = fetchRMR(cpu, bits)
	local result = a - b
	writeRM(cpu, mod, rm, result, bits)
	setFlagsSub(cpu, a, b, result, bits)
end

local function subRRM(cpu, bits)
	local _mod, reg, _rm, a, b = fetchRRM(cpu, bits)
	local result = a - b
	writeR(cpu, reg, result, bits)
	setFlagsSub(cpu, a, b, result, bits)
end

local function subAccImm(cpu, bits)
	local a, b = fetchAccImm(cpu, bits)
	local result = a - b
	writeR(cpu, 0, result, bits)
	setFlagsSub(cpu, a, b, result, bits)
end

OPCODES[0x28] = function(cpu) subRMR(cpu, 8)          end -- SUB r/m8, r8
OPCODES[0x29] = function(cpu) subRMR(cpu, OS(cpu))    end -- SUB r/m16/32, r16/32
OPCODES[0x2A] = function(cpu) subRRM(cpu, 8)          end -- SUB r8, r/m8
OPCODES[0x2B] = function(cpu) subRRM(cpu, OS(cpu))    end -- SUB r16/32, r/m16/32
OPCODES[0x2C] = function(cpu) subAccImm(cpu, 8)       end -- SUB AL, imm8
OPCODES[0x2D] = function(cpu) subAccImm(cpu, OS(cpu)) end -- SUB AX/EAX, imm16/32

-- 0x2E = CS: prefix, handled in CPU:Step() prefix loop

OPCODES[0x2F] = function(cpu)                             -- DAS
	local al = bit32.extract(cpu.EAX, 0, 8)
	local orig_al = al
	local af = bit32.extract(cpu.EFLAGS, 4, 1)
	local cf = bit32.extract(cpu.EFLAGS, 0, 1)
	local newcf = 0; local newaf = 0
	if af == 1 or bit32.band(al, 0xF) > 9 then
		al = al - 6
		newcf = (al < 0 or cf == 1) and 1 or 0
		newaf = 1
	end
	if cf == 1 or orig_al > 0x9F then
		al = al - 0x60
		newcf = 1
	end
	al = bit32.band(al, 0xFF)
	cpu.EAX = bit32.replace(cpu.EAX, al, 0, 8)
	setFlagsLogic(cpu, al, 8)
	local flags = cpu.EFLAGS
	flags = bit32.replace(flags, newcf, 0, 1)
	flags = bit32.replace(flags, newaf, 4, 1)
	cpu.EFLAGS = flags
end

local function xorRMR(cpu, bits)
	local mod, _reg, rm, a, b = fetchRMR(cpu, bits)
	local result = bit32.bxor(a, b)
	writeRM(cpu, mod, rm, result, bits)
	setFlagsLogic(cpu, result, bits)
end

local function xorRRM(cpu, bits)
	local _mod, reg, _rm, a, b = fetchRRM(cpu, bits)
	local result = bit32.bxor(a, b)
	writeR(cpu, reg, result, bits)
	setFlagsLogic(cpu, result, bits)
end

local function xorAccImm(cpu, bits)
	local a, b = fetchAccImm(cpu, bits)
	local result = bit32.bxor(a, b)
	writeR(cpu, 0, result, bits)
	setFlagsLogic(cpu, result, bits)
end

OPCODES[0x30] = function(cpu) xorRMR(cpu, 8)          end -- XOR r/m8, r8
OPCODES[0x31] = function(cpu) xorRMR(cpu, OS(cpu))    end -- XOR r/m16/32, r16/32
OPCODES[0x32] = function(cpu) xorRRM(cpu, 8)          end -- XOR r8, r/m8
OPCODES[0x33] = function(cpu) xorRRM(cpu, OS(cpu))    end -- XOR r16/32, r/m16/32
OPCODES[0x34] = function(cpu) xorAccImm(cpu, 8)       end -- XOR AL, imm8
OPCODES[0x35] = function(cpu) xorAccImm(cpu, OS(cpu)) end -- XOR AX/EAX, imm16/32

-- 0x36 = SS: prefix, handled in CPU:Step() prefix loop

OPCODES[0x37] = function(cpu)                             -- AAA
	local al = bit32.extract(cpu.EAX, 0, 8)
	local af = bit32.extract(cpu.EFLAGS, 4, 1)
	local newcf, newaf
	if af == 1 or bit32.band(al, 0xF) > 9 then
		al = bit32.band(al + 6, 0xFF)
		cpu.EAX = bit32.replace(cpu.EAX, bit32.band(bit32.extract(cpu.EAX, 8, 8) + 1, 0xFF), 8, 8)
		newcf = 1; newaf = 1
	else
		newcf = 0; newaf = 0
	end
	al = bit32.band(al, 0x0F)
	cpu.EAX = bit32.replace(cpu.EAX, al, 0, 8)
	local flags = cpu.EFLAGS
	flags = bit32.replace(flags, newcf, 0, 1)
	flags = bit32.replace(flags, newaf, 4, 1)
	cpu.EFLAGS = flags
end

local function cmpRMR(cpu, bits)
	local _mod, _reg, _rm, a, b = fetchRMR(cpu, bits)
	setFlagsSub(cpu, a, b, a - b, bits)
end

local function cmpRRM(cpu, bits)
	local _mod, _reg, _rm, a, b = fetchRRM(cpu, bits)
	setFlagsSub(cpu, a, b, a - b, bits)
end

local function cmpAccImm(cpu, bits)
	local a, b = fetchAccImm(cpu, bits)
	setFlagsSub(cpu, a, b, a - b, bits)
end

OPCODES[0x38] = function(cpu) cmpRMR(cpu, 8)          end -- CMP r/m8, r8
OPCODES[0x39] = function(cpu) cmpRMR(cpu, OS(cpu))    end -- CMP r/m16/32, r16/32
OPCODES[0x3A] = function(cpu) cmpRRM(cpu, 8)          end -- CMP r8, r/m8
OPCODES[0x3B] = function(cpu) cmpRRM(cpu, OS(cpu))    end -- CMP r16/32, r/m16/32
OPCODES[0x3C] = function(cpu) cmpAccImm(cpu, 8)       end -- CMP AL, imm8
OPCODES[0x3D] = function(cpu) cmpAccImm(cpu, OS(cpu)) end -- CMP AX/EAX, imm16/32

-- 0x3E = DS: prefix, handled in CPU:Step() prefix loop

OPCODES[0x3F] = function(cpu)                             -- AAS
	local al = bit32.extract(cpu.EAX, 0, 8)
	local af = bit32.extract(cpu.EFLAGS, 4, 1)
	local newcf, newaf
	if af == 1 or bit32.band(al, 0xF) > 9 then
		al = bit32.band(al - 6, 0xFF)
		cpu.EAX = bit32.replace(cpu.EAX, bit32.band(bit32.extract(cpu.EAX, 8, 8) - 1, 0xFF), 8, 8)
		newcf = 1; newaf = 1
	else
		newcf = 0; newaf = 0
	end
	al = bit32.band(al, 0x0F)
	cpu.EAX = bit32.replace(cpu.EAX, al, 0, 8)
	local flags = cpu.EFLAGS
	flags = bit32.replace(flags, newcf, 0, 1)
	flags = bit32.replace(flags, newaf, 4, 1)
	cpu.EFLAGS = flags
end

local function setFlagsIncDec(cpu, a, result, bits, of)
	local mask = bit32.lshift(1, bits) - 1
	local r  = bit32.band(result, mask)
	local zf = r == 0 and 1 or 0
	local sf = bit32.extract(r, bits - 1, 1)
	local af = bit32.extract(bit32.bxor(a, 1, r), 4, 1)
	local p  = PARITY_LUT[bit32.band(r, 0xFF)]
	cpu.EFLAGS = bit32.bor(
		bit32.band(cpu.EFLAGS, 0xFFFFF72B),
		bit32.lshift(p, 2), bit32.lshift(af, 4),
		bit32.lshift(zf, 6), bit32.lshift(sf, 7), bit32.lshift(of, 11))
end

local function incR(cpu, reg)
	local bits = OS(cpu)
	local mask = bit32.lshift(1, bits) - 1
	local a = readR(cpu, reg, bits)
	local result = a + 1
	writeR(cpu, reg, result, bits)
	setFlagsIncDec(cpu, a, result, bits, (a == bit32.rshift(mask, 1)) and 1 or 0)
end

local function decR(cpu, reg)
	local bits = OS(cpu)
	local a = readR(cpu, reg, bits)
	local result = a - 1
	writeR(cpu, reg, result, bits)
	setFlagsIncDec(cpu, a, result, bits, (a == bit32.lshift(1, bits - 1)) and 1 or 0)
end

OPCODES[0x40] = function(cpu) incR(cpu, 0) end -- INC EAX
OPCODES[0x41] = function(cpu) incR(cpu, 1) end -- INC ECX
OPCODES[0x42] = function(cpu) incR(cpu, 2) end -- INC EDX
OPCODES[0x43] = function(cpu) incR(cpu, 3) end -- INC EBX
OPCODES[0x44] = function(cpu) incR(cpu, 4) end -- INC ESP
OPCODES[0x45] = function(cpu) incR(cpu, 5) end -- INC EBP
OPCODES[0x46] = function(cpu) incR(cpu, 6) end -- INC ESI
OPCODES[0x47] = function(cpu) incR(cpu, 7) end -- INC EDI
OPCODES[0x48] = function(cpu) decR(cpu, 0) end -- DEC EAX
OPCODES[0x49] = function(cpu) decR(cpu, 1) end -- DEC ECX
OPCODES[0x4A] = function(cpu) decR(cpu, 2) end -- DEC EDX
OPCODES[0x4B] = function(cpu) decR(cpu, 3) end -- DEC EBX
OPCODES[0x4C] = function(cpu) decR(cpu, 4) end -- DEC ESP
OPCODES[0x4D] = function(cpu) decR(cpu, 5) end -- DEC EBP
OPCODES[0x4E] = function(cpu) decR(cpu, 6) end -- DEC ESI
OPCODES[0x4F] = function(cpu) decR(cpu, 7) end -- DEC EDI

local function pushR(cpu, reg)
	local bits = OS(cpu)
	local val = readR(cpu, reg, bits)
	cpu.ESP -= bits // 8
	BUF_WRITE[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), val)
end

local function popR(cpu, reg)
	local bits = OS(cpu)
	local val = BUF_READ[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP))
	cpu.ESP += bits // 8
	writeR(cpu, reg, val, bits)
end

OPCODES[0x50] = function(cpu) pushR(cpu, 0) end -- PUSH EAX
OPCODES[0x51] = function(cpu) pushR(cpu, 1) end -- PUSH ECX
OPCODES[0x52] = function(cpu) pushR(cpu, 2) end -- PUSH EDX
OPCODES[0x53] = function(cpu) pushR(cpu, 3) end -- PUSH EBX
OPCODES[0x54] = function(cpu) pushR(cpu, 4) end -- PUSH ESP
OPCODES[0x55] = function(cpu) pushR(cpu, 5) end -- PUSH EBP
OPCODES[0x56] = function(cpu) pushR(cpu, 6) end -- PUSH ESI
OPCODES[0x57] = function(cpu) pushR(cpu, 7) end -- PUSH EDI
OPCODES[0x58] = function(cpu) popR(cpu, 0)  end -- POP EAX
OPCODES[0x59] = function(cpu) popR(cpu, 1)  end -- POP ECX
OPCODES[0x5A] = function(cpu) popR(cpu, 2)  end -- POP EDX
OPCODES[0x5B] = function(cpu) popR(cpu, 3)  end -- POP EBX
OPCODES[0x5C] = function(cpu) popR(cpu, 4)  end -- POP ESP
OPCODES[0x5D] = function(cpu) popR(cpu, 5)  end -- POP EBP
OPCODES[0x5E] = function(cpu) popR(cpu, 6)  end -- POP ESI
OPCODES[0x5F] = function(cpu) popR(cpu, 7)  end -- POP EDI

OPCODES[0x60] = function(cpu)                             -- PUSHA
	local bits = OS(cpu)
	local step = bits // 8
	local esp = readR(cpu, 4, bits)
	cpu.ESP -= step; BUF_WRITE[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), readR(cpu, 0, bits))
	cpu.ESP -= step; BUF_WRITE[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), readR(cpu, 1, bits))
	cpu.ESP -= step; BUF_WRITE[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), readR(cpu, 2, bits))
	cpu.ESP -= step; BUF_WRITE[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), readR(cpu, 3, bits))
	cpu.ESP -= step; BUF_WRITE[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), esp)
	cpu.ESP -= step; BUF_WRITE[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), readR(cpu, 5, bits))
	cpu.ESP -= step; BUF_WRITE[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), readR(cpu, 6, bits))
	cpu.ESP -= step; BUF_WRITE[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), readR(cpu, 7, bits))
end

OPCODES[0x61] = function(cpu)                             -- POPA
	local bits = OS(cpu)
	local step = bits // 8
	writeR(cpu, 7, BUF_READ[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP)), bits); cpu.ESP += step
	writeR(cpu, 6, BUF_READ[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP)), bits); cpu.ESP += step
	writeR(cpu, 5, BUF_READ[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP)), bits); cpu.ESP += step
	cpu.ESP += step
	writeR(cpu, 3, BUF_READ[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP)), bits); cpu.ESP += step
	writeR(cpu, 2, BUF_READ[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP)), bits); cpu.ESP += step
	writeR(cpu, 1, BUF_READ[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP)), bits); cpu.ESP += step
	writeR(cpu, 0, BUF_READ[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP)), bits); cpu.ESP += step
end

local BUF_READI = { [16] = buffer.readi16, [32] = buffer.readi32 }

local function signExtend(val, bits)
	local sign = bit32.extract(val, bits - 1, 1)
	return sign == 1 and (val - bit32.lshift(1, bits)) or val
end

OPCODES[0x62] = function(cpu)                             -- BOUND r16/32, m16/32
	local bits = OS(cpu)
	local mod, reg, rm = ModRM(cpu)
	if mod == 3 then cpu:INT(6); return end
	local idx = signExtend(readR(cpu, reg, bits), bits)
	local addr = LA16(cpu, mod, rm)
	local lo = BUF_READI[bits](cpu.RAM, addr)
	local hi = BUF_READI[bits](cpu.RAM, phys(cpu, addr + bits // 8))
	if idx < lo or idx > hi then cpu:INT(5) end
end

-- 0x63 = ARPL, protected mode only, #UD in real mode
-- 0x64 = FS: prefix, handled in CPU:Step() prefix loop
-- 0x65 = GS: prefix, handled in CPU:Step() prefix loop
-- 0x66 = operand-size prefix, handled in CPU:Step() prefix loop
-- 0x67 = address-size prefix, handled in CPU:Step() prefix loop

OPCODES[0x68] = function(cpu)                             -- PUSH imm16/32
	local bits = OS(cpu)
	local val = BUF_READ[bits](cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += bits // 8
	cpu.ESP -= bits // 8
	BUF_WRITE[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), val)
end

local function setFlagsIMUL(cpu, result, bits)
	local mask = bit32.lshift(1, bits) - 1
	local truncated = bit32.band(result, mask)
	local signBit = bit32.extract(truncated, bits - 1, 1)
	local signExtended = signBit == 1 and (truncated - bit32.lshift(1, bits)) or truncated
	local cf = (signExtended ~= result) and 1 or 0
	cpu.EFLAGS = bit32.replace(cpu.EFLAGS, cf, 0,  1)
	cpu.EFLAGS = bit32.replace(cpu.EFLAGS, cf, 11, 1)
end

OPCODES[0x69] = function(cpu)                             -- IMUL r16/32, r/m16/32, imm16/32
	local bits = OS(cpu)
	local mod, reg, rm = ModRM(cpu)
	local a = signExtend(readRM(cpu, mod, rm, bits), bits)
	local b = signExtend(BUF_READ[bits](cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP)), bits)
	cpu.EIP += bits // 8
	local result = a * b
	writeR(cpu, reg, result, bits)
	setFlagsIMUL(cpu, result, bits)
end

OPCODES[0x6A] = function(cpu)                             -- PUSH imm8
	local bits = OS(cpu)
	local val = buffer.readi8(cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += 1
	cpu.ESP -= bits // 8
	BUF_WRITE[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), bit32.band(val, bit32.lshift(1, bits) - 1))
end

OPCODES[0x6B] = function(cpu)                             -- IMUL r16/32, r/m16/32, imm8
	local bits = OS(cpu)
	local mod, reg, rm = ModRM(cpu)
	local a = signExtend(readRM(cpu, mod, rm, bits), bits)
	local b = buffer.readi8(cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += 1
	local result = a * b
	writeR(cpu, reg, result, bits)
	setFlagsIMUL(cpu, result, bits)
end

local function strStep(cpu, bits)
	return bit32.extract(cpu.EFLAGS, 10, 1) == 0 and bits // 8 or -(bits // 8)
end

local function repNext(cpu)
	if cpu.REP then
		cpu.ECX = bit32.replace(cpu.ECX, bit32.band(cpu.ECX - 1, 0xFFFF), 0, 16)
		if bit32.band(cpu.ECX, 0xFFFF) ~= 0 then cpu.EIP -= 1 end
	end
end

local function repCheck(cpu)
	return cpu.REP and bit32.band(cpu.ECX, 0xFFFF) == 0
end

OPCODES[0x6C] = function(cpu)                             -- INSB
	if repCheck(cpu) then return end
	local port = bit32.extract(cpu.EDX, 0, 16)
	local di   = bit32.extract(cpu.EDI, 0, 16)
	buffer.writeu8(cpu.RAM, phys(cpu, cpu.ESBase + di), cpu.PortsIn[port]())
	cpu.EDI = bit32.replace(cpu.EDI, bit32.band(di + strStep(cpu, 8), 0xFFFF), 0, 16)
	repNext(cpu)
end

OPCODES[0x6D] = function(cpu)                             -- INSW
	if repCheck(cpu) then return end
	local bits = OS(cpu)
	local port = bit32.extract(cpu.EDX, 0, 16)
	local di   = bit32.extract(cpu.EDI, 0, 16)
	BUF_WRITE[bits](cpu.RAM, phys(cpu, cpu.ESBase + di), cpu.PortsIn[port]())
	cpu.EDI = bit32.replace(cpu.EDI, bit32.band(di + strStep(cpu, bits), 0xFFFF), 0, 16)
	repNext(cpu)
end

OPCODES[0x6E] = function(cpu)                             -- OUTSB
	if repCheck(cpu) then return end
	local port = bit32.extract(cpu.EDX, 0, 16)
	local si   = bit32.extract(cpu.ESI, 0, 16)
	local seg  = cpu.SEG_OVERRIDE and cpu[SEG_BASE[cpu.SEG_OVERRIDE]] or cpu.DSBase
	cpu.PortsOut[port](buffer.readu8(cpu.RAM, phys(cpu, seg + si)))
	cpu.ESI = bit32.replace(cpu.ESI, bit32.band(si + strStep(cpu, 8), 0xFFFF), 0, 16)
	repNext(cpu)
end

OPCODES[0x6F] = function(cpu)                             -- OUTSW
	if repCheck(cpu) then return end
	local bits = OS(cpu)
	local port = bit32.extract(cpu.EDX, 0, 16)
	local si   = bit32.extract(cpu.ESI, 0, 16)
	local seg  = cpu.SEG_OVERRIDE and cpu[SEG_BASE[cpu.SEG_OVERRIDE]] or cpu.DSBase
	cpu.PortsOut[port](BUF_READ[bits](cpu.RAM, phys(cpu, seg + si)))
	cpu.ESI = bit32.replace(cpu.ESI, bit32.band(si + strStep(cpu, bits), 0xFFFF), 0, 16)
	repNext(cpu)
end

local function jcc(cpu, cond)
	local disp = buffer.readi8(cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += 1
	if cond then
		cpu.EIP = bit32.band(cpu.EIP + disp, bit32.lshift(1, OS(cpu)) - 1)
	end
end

local function fl(cpu, bit) return bit32.extract(cpu.EFLAGS, bit, 1) == 1 end

OPCODES[0x70] = function(cpu) jcc(cpu, fl(cpu, 11)) end                                  -- JO
OPCODES[0x71] = function(cpu) jcc(cpu, not fl(cpu, 11)) end                              -- JNO
OPCODES[0x72] = function(cpu) jcc(cpu, fl(cpu, 0)) end                                   -- JB
OPCODES[0x73] = function(cpu) jcc(cpu, not fl(cpu, 0)) end                               -- JNB
OPCODES[0x74] = function(cpu) jcc(cpu, fl(cpu, 6)) end                                   -- JZ
OPCODES[0x75] = function(cpu) jcc(cpu, not fl(cpu, 6)) end                               -- JNZ
OPCODES[0x76] = function(cpu) jcc(cpu, fl(cpu, 0) or fl(cpu, 6)) end                    -- JBE
OPCODES[0x77] = function(cpu) jcc(cpu, not fl(cpu, 0) and not fl(cpu, 6)) end            -- JA
OPCODES[0x78] = function(cpu) jcc(cpu, fl(cpu, 7)) end                                   -- JS
OPCODES[0x79] = function(cpu) jcc(cpu, not fl(cpu, 7)) end                               -- JNS
OPCODES[0x7A] = function(cpu) jcc(cpu, fl(cpu, 2)) end                                   -- JP
OPCODES[0x7B] = function(cpu) jcc(cpu, not fl(cpu, 2)) end                               -- JNP
OPCODES[0x7C] = function(cpu) jcc(cpu, fl(cpu, 7) ~= fl(cpu, 11)) end                   -- JL
OPCODES[0x7D] = function(cpu) jcc(cpu, fl(cpu, 7) == fl(cpu, 11)) end                   -- JGE
OPCODES[0x7E] = function(cpu) jcc(cpu, fl(cpu, 6) or fl(cpu, 7) ~= fl(cpu, 11)) end     -- JLE
OPCODES[0x7F] = function(cpu) jcc(cpu, not fl(cpu, 6) and fl(cpu, 7) == fl(cpu, 11)) end -- JG

local IMM_ALU = {
	[0] = function(cpu, mod, rm, a, b, bits)
		local result = a + b
		writeRM(cpu, mod, rm, result, bits)
		setFlagsAdd(cpu, a, b, result, bits)
	end,
	[1] = function(cpu, mod, rm, a, b, bits)
		local result = bit32.bor(a, b)
		writeRM(cpu, mod, rm, result, bits)
		setFlagsLogic(cpu, result, bits)
	end,
	[2] = function(cpu, mod, rm, a, b, bits)
		local cf = bit32.extract(cpu.EFLAGS, 0, 1)
		local result = a + b + cf
		writeRM(cpu, mod, rm, result, bits)
		setFlagsAdd(cpu, a, b + cf, result, bits)
	end,
	[3] = function(cpu, mod, rm, a, b, bits)
		local cf = bit32.extract(cpu.EFLAGS, 0, 1)
		local result = a - b - cf
		writeRM(cpu, mod, rm, result, bits)
		setFlagsSub(cpu, a, b + cf, result, bits)
	end,
	[4] = function(cpu, mod, rm, a, b, bits)
		local result = bit32.band(a, b)
		writeRM(cpu, mod, rm, result, bits)
		setFlagsLogic(cpu, result, bits)
	end,
	[5] = function(cpu, mod, rm, a, b, bits)
		local result = a - b
		writeRM(cpu, mod, rm, result, bits)
		setFlagsSub(cpu, a, b, result, bits)
	end,
	[6] = function(cpu, mod, rm, a, b, bits)
		local result = bit32.bxor(a, b)
		writeRM(cpu, mod, rm, result, bits)
		setFlagsLogic(cpu, result, bits)
	end,
	[7] = function(cpu, mod, rm, a, b, bits)
		setFlagsSub(cpu, a, b, a - b, bits)
	end,
}

OPCODES[0x80] = function(cpu)                             -- ALU r/m8, imm8
	local mod, reg, rm = ModRM(cpu)
	local a = readRM(cpu, mod, rm, 8)
	local b = buffer.readu8(cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += 1
	IMM_ALU[reg](cpu, mod, rm, a, b, 8)
end

OPCODES[0x81] = function(cpu)                             -- ALU r/m16/32, imm16/32
	local bits = OS(cpu)
	local mod, reg, rm = ModRM(cpu)
	local a = readRM(cpu, mod, rm, bits)
	local b = BUF_READ[bits](cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += bits // 8
	IMM_ALU[reg](cpu, mod, rm, a, b, bits)
end

OPCODES[0x82] = OPCODES[0x80]                             -- ALU r/m8, imm8 (redundant)

OPCODES[0x83] = function(cpu)                             -- ALU r/m16/32, imm8 sign-extended
	local bits = OS(cpu)
	local mod, reg, rm = ModRM(cpu)
	local a = readRM(cpu, mod, rm, bits)
	local b = buffer.readi8(cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += 1
	IMM_ALU[reg](cpu, mod, rm, a, b, bits)
end

OPCODES[0x84] = function(cpu)                             -- TEST r/m8, r8
	local mod, reg, rm = ModRM(cpu)
	local a = readRM(cpu, mod, rm, 8)
	local b = readR(cpu, reg, 8)
	setFlagsLogic(cpu, bit32.band(a, b), 8)
end

OPCODES[0x85] = function(cpu)                             -- TEST r/m16/32, r16/32
	local bits = OS(cpu)
	local mod, reg, rm = ModRM(cpu)
	local a = readRM(cpu, mod, rm, bits)
	local b = readR(cpu, reg, bits)
	setFlagsLogic(cpu, bit32.band(a, b), bits)
end

OPCODES[0x86] = function(cpu)                             -- XCHG r/m8, r8
	local mod, reg, rm = ModRM(cpu)
	local a = readRM(cpu, mod, rm, 8)
	local b = readR(cpu, reg, 8)
	writeRM(cpu, mod, rm, b, 8)
	writeR(cpu, reg, a, 8)
end

OPCODES[0x87] = function(cpu)                             -- XCHG r/m16/32, r16/32
	local bits = OS(cpu)
	local mod, reg, rm = ModRM(cpu)
	local a = readRM(cpu, mod, rm, bits)
	local b = readR(cpu, reg, bits)
	writeRM(cpu, mod, rm, b, bits)
	writeR(cpu, reg, a, bits)
end

OPCODES[0x88] = function(cpu)                             -- MOV r/m8, r8
	local mod, reg, rm = ModRM(cpu)
	writeRM(cpu, mod, rm, readR(cpu, reg, 8), 8)
end

OPCODES[0x89] = function(cpu)                             -- MOV r/m16/32, r16/32
	local bits = OS(cpu)
	local mod, reg, rm = ModRM(cpu)
	writeRM(cpu, mod, rm, readR(cpu, reg, bits), bits)
end

OPCODES[0x8A] = function(cpu)                             -- MOV r8, r/m8
	local mod, reg, rm = ModRM(cpu)
	writeR(cpu, reg, readRM(cpu, mod, rm, 8), 8)
end

OPCODES[0x8B] = function(cpu)                             -- MOV r16/32, r/m16/32
	local bits = OS(cpu)
	local mod, reg, rm = ModRM(cpu)
	writeR(cpu, reg, readRM(cpu, mod, rm, bits), bits)
end

local SEG_MAP = { [0] = "ES", [1] = "CS", [2] = "SS", [3] = "DS", [4] = "FS", [5] = "GS" }

OPCODES[0x8C] = function(cpu)                             -- MOV r/m16, Sreg
	local mod, reg, rm = ModRM(cpu)
	writeRM(cpu, mod, rm, cpu[SEG_MAP[reg]], 16)
end

OPCODES[0x8D] = function(cpu)                             -- LEA r16/32, m
	local bits = OS(cpu)
	local mod, reg, rm = ModRM(cpu)
	writeR(cpu, reg, EA16(cpu, mod, rm), bits)
end

OPCODES[0x8E] = function(cpu)                             -- MOV Sreg, r/m16
	local mod, reg, rm = ModRM(cpu)
	local val = readRM(cpu, mod, rm, 16)
	local seg = SEG_MAP[reg]
	cpu[seg] = val
	cpu[SEG_BASE[seg]] = val * 16
end

OPCODES[0x8F] = function(cpu)                             -- POP r/m16/32
	local bits = OS(cpu)
	local mod, reg, rm = ModRM(cpu)
	if reg ~= 0 then cpu:INT(6); return end
	local val = BUF_READ[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP))
	cpu.ESP += bits // 8
	writeRM(cpu, mod, rm, val, bits)
end

local function xchgAccR(cpu, reg)
	local bits = OS(cpu)
	local a = readR(cpu, 0, bits)
	local b = readR(cpu, reg, bits)
	writeR(cpu, 0, b, bits)
	writeR(cpu, reg, a, bits)
end

OPCODES[0x90] = function(cpu) end                          -- NOP
OPCODES[0x91] = function(cpu) xchgAccR(cpu, 1) end        -- XCHG EAX, ECX
OPCODES[0x92] = function(cpu) xchgAccR(cpu, 2) end        -- XCHG EAX, EDX
OPCODES[0x93] = function(cpu) xchgAccR(cpu, 3) end        -- XCHG EAX, EBX
OPCODES[0x94] = function(cpu) xchgAccR(cpu, 4) end        -- XCHG EAX, ESP
OPCODES[0x95] = function(cpu) xchgAccR(cpu, 5) end        -- XCHG EAX, EBP
OPCODES[0x96] = function(cpu) xchgAccR(cpu, 6) end        -- XCHG EAX, ESI
OPCODES[0x97] = function(cpu) xchgAccR(cpu, 7) end        -- XCHG EAX, EDI

OPCODES[0x98] = function(cpu)                             -- CBW / CWDE
	local bits = OS(cpu)
	if bits == 16 then
		local al = bit32.extract(cpu.EAX, 0, 8)
		local sign = bit32.extract(al, 7, 1)
		cpu.EAX = bit32.replace(cpu.EAX, sign == 1 and 0xFF or 0x00, 8, 8)
	else
		local ax = bit32.extract(cpu.EAX, 0, 16)
		local sign = bit32.extract(ax, 15, 1)
		cpu.EAX = sign == 1 and (ax - 0x10000) + 0x100000000 or ax
		cpu.EAX = bit32.band(cpu.EAX, 0xFFFFFFFF)
	end
end

OPCODES[0x99] = function(cpu)                             -- CWD / CDQ
	local bits = OS(cpu)
	if bits == 16 then
		local sign = bit32.extract(cpu.EAX, 15, 1)
		cpu.EDX = bit32.replace(cpu.EDX, sign == 1 and 0xFFFF or 0x0000, 0, 16)
	else
		local sign = bit32.extract(cpu.EAX, 31, 1)
		cpu.EDX = sign == 1 and 0xFFFFFFFF or 0
	end
end

OPCODES[0x9A] = function(cpu)                             -- CALL FAR imm16:16/32
	local bits = OS(cpu)
	local ip = BUF_READ[bits](cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += bits // 8
	local cs = buffer.readu16(cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += 2
	cpu.ESP -= bits // 8
	BUF_WRITE[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), cpu.CS)
	cpu.ESP -= bits // 8
	BUF_WRITE[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), cpu.EIP)
	cpu.CS = cs
	cpu.CSBase = cs * 16
	cpu.EIP = ip
end

OPCODES[0x9B] = function(cpu) end                         -- FWAIT

OPCODES[0x9C] = function(cpu)                             -- PUSHF
	local bits = OS(cpu)
	cpu.ESP -= bits // 8
	BUF_WRITE[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), bit32.band(cpu.EFLAGS, bit32.lshift(1, bits) - 1))
end

OPCODES[0x9D] = function(cpu)                             -- POPF
	local bits = OS(cpu)
	local val = BUF_READ[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP))
	cpu.ESP += bits // 8
	val = bit32.replace(val, 1, 1, 1)
	cpu.EFLAGS = bit32.replace(cpu.EFLAGS, val, 0, bits)
end

OPCODES[0x9E] = function(cpu)                             -- SAHF
	local flags = cpu.EFLAGS
	flags = bit32.replace(flags, bit32.band(bit32.extract(cpu.EAX, 8, 8), 0xD5), 0, 8)
	flags = bit32.replace(flags, 1, 1, 1)
	cpu.EFLAGS = flags
end

OPCODES[0x9F] = function(cpu)                             -- LAHF
	cpu.EAX = bit32.replace(cpu.EAX, bit32.bor(bit32.band(cpu.EFLAGS, 0xD5), 0x02), 8, 8)
end

local function moffs(cpu)
	local addr = buffer.readu16(cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += 2
	return phys(cpu, (cpu.SEG_OVERRIDE and cpu[SEG_BASE[cpu.SEG_OVERRIDE]] or cpu.DSBase) + addr)
end

OPCODES[0xA0] = function(cpu) writeR(cpu, 0, buffer.readu8(cpu.RAM, moffs(cpu)), 8)                       end -- MOV AL, moffs8
OPCODES[0xA1] = function(cpu) local b = OS(cpu); writeR(cpu, 0, BUF_READ[b](cpu.RAM, moffs(cpu)), b)       end -- MOV AX/EAX, moffs16/32
OPCODES[0xA2] = function(cpu) buffer.writeu8(cpu.RAM, moffs(cpu), readR(cpu, 0, 8))                       end -- MOV moffs8, AL
OPCODES[0xA3] = function(cpu) local b = OS(cpu); BUF_WRITE[b](cpu.RAM, moffs(cpu), readR(cpu, 0, b))       end -- MOV moffs16/32, AX/EAX

local function movs(cpu, bits)
	if repCheck(cpu) then return end
	local seg = cpu.SEG_OVERRIDE and cpu[SEG_BASE[cpu.SEG_OVERRIDE]] or cpu.DSBase
	local si = bit32.extract(cpu.ESI, 0, 16)
	local di = bit32.extract(cpu.EDI, 0, 16)
	BUF_WRITE[bits](cpu.RAM, phys(cpu, cpu.ESBase + di), BUF_READ[bits](cpu.RAM, phys(cpu, seg + si)))
	local step = strStep(cpu, bits)
	cpu.ESI = bit32.replace(cpu.ESI, bit32.band(si + step, 0xFFFF), 0, 16)
	cpu.EDI = bit32.replace(cpu.EDI, bit32.band(di + step, 0xFFFF), 0, 16)
	repNext(cpu)
end

local function cmps(cpu, bits)
	if repCheck(cpu) then return end
	local seg = cpu.SEG_OVERRIDE and cpu[SEG_BASE[cpu.SEG_OVERRIDE]] or cpu.DSBase
	local si = bit32.extract(cpu.ESI, 0, 16)
	local di = bit32.extract(cpu.EDI, 0, 16)
	local a = BUF_READ[bits](cpu.RAM, phys(cpu, seg + si))
	local b = BUF_READ[bits](cpu.RAM, phys(cpu, cpu.ESBase + di))
	setFlagsSub(cpu, a, b, a - b, bits)
	local step = strStep(cpu, bits)
	cpu.ESI = bit32.replace(cpu.ESI, bit32.band(si + step, 0xFFFF), 0, 16)
	cpu.EDI = bit32.replace(cpu.EDI, bit32.band(di + step, 0xFFFF), 0, 16)
	repNext(cpu)
end

OPCODES[0xA4] = function(cpu) movs(cpu, 8)        end -- MOVSB
OPCODES[0xA5] = function(cpu) movs(cpu, OS(cpu))  end -- MOVSW / MOVSD
OPCODES[0xA6] = function(cpu) cmps(cpu, 8)        end -- CMPSB
OPCODES[0xA7] = function(cpu) cmps(cpu, OS(cpu))  end -- CMPSW / CMPSD

OPCODES[0xA8] = function(cpu) local a, b = fetchAccImm(cpu, 8); setFlagsLogic(cpu, bit32.band(a, b), 8)      end -- TEST AL, imm8
OPCODES[0xA9] = function(cpu) local b = OS(cpu); local a, i = fetchAccImm(cpu, b); setFlagsLogic(cpu, bit32.band(a, i), b) end -- TEST AX/EAX, imm16/32

local function stos(cpu, bits)
	if repCheck(cpu) then return end
	local di = bit32.extract(cpu.EDI, 0, 16)
	BUF_WRITE[bits](cpu.RAM, phys(cpu, cpu.ESBase + di), readR(cpu, 0, bits))
	cpu.EDI = bit32.replace(cpu.EDI, bit32.band(di + strStep(cpu, bits), 0xFFFF), 0, 16)
	repNext(cpu)
end

local function lods(cpu, bits)
	if repCheck(cpu) then return end
	local seg = cpu.SEG_OVERRIDE and cpu[SEG_BASE[cpu.SEG_OVERRIDE]] or cpu.DSBase
	local si = bit32.extract(cpu.ESI, 0, 16)
	writeR(cpu, 0, BUF_READ[bits](cpu.RAM, phys(cpu, seg + si)), bits)
	cpu.ESI = bit32.replace(cpu.ESI, bit32.band(si + strStep(cpu, bits), 0xFFFF), 0, 16)
	repNext(cpu)
end

local function scas(cpu, bits)
	if repCheck(cpu) then return end
	local di = bit32.extract(cpu.EDI, 0, 16)
	local a = readR(cpu, 0, bits)
	local b = BUF_READ[bits](cpu.RAM, phys(cpu, cpu.ESBase + di))
	setFlagsSub(cpu, a, b, a - b, bits)
	cpu.EDI = bit32.replace(cpu.EDI, bit32.band(di + strStep(cpu, bits), 0xFFFF), 0, 16)
	repNext(cpu)
end

OPCODES[0xAA] = function(cpu) stos(cpu, 8)       end -- STOSB
OPCODES[0xAB] = function(cpu) stos(cpu, OS(cpu)) end -- STOSW / STOSD
OPCODES[0xAC] = function(cpu) lods(cpu, 8)       end -- LODSB
OPCODES[0xAD] = function(cpu) lods(cpu, OS(cpu)) end -- LODSW / LODSD
OPCODES[0xAE] = function(cpu) scas(cpu, 8)       end -- SCASB
OPCODES[0xAF] = function(cpu) scas(cpu, OS(cpu)) end -- SCASW / SCASD

local function movRI(cpu, reg, bits)
	local val = BUF_READ[bits](cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += bits // 8
	writeR(cpu, reg, val, bits)
end

OPCODES[0xB0] = function(cpu) movRI(cpu, 0, 8)        end -- MOV AL, imm8
OPCODES[0xB1] = function(cpu) movRI(cpu, 1, 8)        end -- MOV CL, imm8
OPCODES[0xB2] = function(cpu) movRI(cpu, 2, 8)        end -- MOV DL, imm8
OPCODES[0xB3] = function(cpu) movRI(cpu, 3, 8)        end -- MOV BL, imm8
OPCODES[0xB4] = function(cpu) movRI(cpu, 4, 8)        end -- MOV AH, imm8
OPCODES[0xB5] = function(cpu) movRI(cpu, 5, 8)        end -- MOV CH, imm8
OPCODES[0xB6] = function(cpu) movRI(cpu, 6, 8)        end -- MOV DH, imm8
OPCODES[0xB7] = function(cpu) movRI(cpu, 7, 8)        end -- MOV BH, imm8
OPCODES[0xB8] = function(cpu) movRI(cpu, 0, OS(cpu))  end -- MOV AX/EAX, imm16/32
OPCODES[0xB9] = function(cpu) movRI(cpu, 1, OS(cpu))  end -- MOV CX/ECX, imm16/32
OPCODES[0xBA] = function(cpu) movRI(cpu, 2, OS(cpu))  end -- MOV DX/EDX, imm16/32
OPCODES[0xBB] = function(cpu) movRI(cpu, 3, OS(cpu))  end -- MOV BX/EBX, imm16/32
OPCODES[0xBC] = function(cpu) movRI(cpu, 4, OS(cpu))  end -- MOV SP/ESP, imm16/32
OPCODES[0xBD] = function(cpu) movRI(cpu, 5, OS(cpu))  end -- MOV BP/EBP, imm16/32
OPCODES[0xBE] = function(cpu) movRI(cpu, 6, OS(cpu))  end -- MOV SI/ESI, imm16/32
OPCODES[0xBF] = function(cpu) movRI(cpu, 7, OS(cpu))  end -- MOV DI/EDI, imm16/32

local SHIFT_RM = {
	[0] = function(cpu, mod, rm, a, bits, cnt)             -- ROL
		local c = cnt % bits
		local result = bit32.bor(bit32.lshift(a, c), bit32.rshift(a, bits - c))
		writeRM(cpu, mod, rm, result, bits)
		local cf = bit32.extract(result, 0, 1)
		local of = bit32.bxor(cf, bit32.extract(result, bits - 1, 1))
		cpu.EFLAGS = bit32.replace(bit32.replace(cpu.EFLAGS, cf, 0, 1), of, 11, 1)
	end,
	[1] = function(cpu, mod, rm, a, bits, cnt)             -- ROR
		local c = cnt % bits
		local result = bit32.bor(bit32.rshift(a, c), bit32.lshift(a, bits - c))
		writeRM(cpu, mod, rm, result, bits)
		local cf = bit32.extract(result, bits - 1, 1)
		local of = bit32.bxor(cf, bit32.extract(result, bits - 2, 1))
		cpu.EFLAGS = bit32.replace(bit32.replace(cpu.EFLAGS, cf, 0, 1), of, 11, 1)
	end,
	[2] = function(cpu, mod, rm, a, bits, cnt)             -- RCL
		local cf = bit32.extract(cpu.EFLAGS, 0, 1)
		local c = cnt % (bits + 1)
		if c == 0 then return end
		local mask = bit32.lshift(1, bits) - 1
		local result = bit32.band(bit32.bor(bit32.lshift(a, c), bit32.bor(bit32.lshift(cf, c - 1), bit32.rshift(a, bits + 1 - c))), mask)
		local newcf = bit32.extract(a, bits - c, 1)
		writeRM(cpu, mod, rm, result, bits)
		local of = bit32.bxor(newcf, bit32.extract(result, bits - 1, 1))
		cpu.EFLAGS = bit32.replace(bit32.replace(cpu.EFLAGS, newcf, 0, 1), of, 11, 1)
	end,
	[3] = function(cpu, mod, rm, a, bits, cnt)             -- RCR
		local cf = bit32.extract(cpu.EFLAGS, 0, 1)
		local c = cnt % (bits + 1)
		if c == 0 then return end
		local mask = bit32.lshift(1, bits) - 1
		local extended = bit32.bor(bit32.lshift(cf, bits), a)
		local result = bit32.band(bit32.bor(bit32.rshift(extended, c), bit32.lshift(extended, bits + 1 - c)), mask)
		local newcf = bit32.extract(extended, c - 1, 1)
		writeRM(cpu, mod, rm, result, bits)
		local of = bit32.bxor(bit32.extract(a, bits - 1, 1), cf)
		cpu.EFLAGS = bit32.replace(bit32.replace(cpu.EFLAGS, newcf, 0, 1), of, 11, 1)
	end,
	[4] = function(cpu, mod, rm, a, bits, cnt)             -- SHL
		local result = bit32.lshift(a, cnt)
		writeRM(cpu, mod, rm, result, bits)
		local cf = cnt <= bits and bit32.extract(a, bits - cnt, 1) or 0
		local of = bit32.bxor(cf, bit32.extract(result, bits - 1, 1))
		setFlagsLogic(cpu, result, bits)
		cpu.EFLAGS = bit32.replace(bit32.replace(cpu.EFLAGS, cf, 0, 1), of, 11, 1)
	end,
	[5] = function(cpu, mod, rm, a, bits, cnt)             -- SHR
		local result = bit32.rshift(a, cnt)
		writeRM(cpu, mod, rm, result, bits)
		local cf = cnt <= bits and bit32.extract(a, cnt - 1, 1) or 0
		local of = bit32.extract(a, bits - 1, 1)
		setFlagsLogic(cpu, result, bits)
		cpu.EFLAGS = bit32.replace(bit32.replace(cpu.EFLAGS, cf, 0, 1), of, 11, 1)
	end,
	[7] = function(cpu, mod, rm, a, bits, cnt)             -- SAR
		local signed = signExtend(a, bits)
		local result = bit32.band(signed >= 0 and bit32.rshift(signed, cnt) or math.floor(signed / bit32.lshift(1, cnt)), bit32.lshift(1, bits) - 1)
		writeRM(cpu, mod, rm, result, bits)
		local cf = cnt <= bits and bit32.extract(a, cnt - 1, 1) or bit32.extract(a, bits - 1, 1)
		setFlagsLogic(cpu, result, bits)
		cpu.EFLAGS = bit32.replace(cpu.EFLAGS, cf, 0, 1)
	end,
}
SHIFT_RM[6] = SHIFT_RM[4]                                 -- SHL alias

local function shiftRM(cpu, bits)
	local mod, reg, rm = ModRM(cpu)
	local a = readRM(cpu, mod, rm, bits)
	local cnt = bit32.band(buffer.readu8(cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP)), 31)
	cpu.EIP += 1
	if cnt ~= 0 then SHIFT_RM[reg](cpu, mod, rm, a, bits, cnt) end
end

OPCODES[0xC0] = function(cpu) shiftRM(cpu, 8)       end -- SHIFT r/m8, imm8
OPCODES[0xC1] = function(cpu) shiftRM(cpu, OS(cpu)) end -- SHIFT r/m16/32, imm8

OPCODES[0xC2] = function(cpu)                             -- RET imm16
	local bits = OS(cpu)
	local n = buffer.readu16(cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += 2
	cpu.EIP = BUF_READ[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP))
	cpu.ESP += bits // 8 + n
end

OPCODES[0xC3] = function(cpu)                             -- RET
	local bits = OS(cpu)
	cpu.EIP = BUF_READ[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP))
	cpu.ESP += bits // 8
end

local function loadFarPtr(cpu, seg)
	local bits = OS(cpu)
	local mod, reg, rm = ModRM(cpu)
	if mod == 3 then cpu:INT(6); return end
	local addr = LA16(cpu, mod, rm)
	local off = BUF_READ[bits](cpu.RAM, addr)
	local sel = buffer.readu16(cpu.RAM, phys(cpu, addr + bits // 8))
	writeR(cpu, reg, off, bits)
	cpu[seg] = sel
	cpu[SEG_BASE[seg]] = sel * 16
end

OPCODES[0xC4] = function(cpu) loadFarPtr(cpu, "ES") end -- LES r16/32, m16:16/32
OPCODES[0xC5] = function(cpu) loadFarPtr(cpu, "DS") end -- LDS r16/32, m16:16/32

OPCODES[0xC6] = function(cpu)                             -- MOV r/m8, imm8
	local mod, _reg, rm = ModRM(cpu)
	local val = buffer.readu8(cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += 1
	writeRM(cpu, mod, rm, val, 8)
end

OPCODES[0xC7] = function(cpu)                             -- MOV r/m16/32, imm16/32
	local bits = OS(cpu)
	local mod, _reg, rm = ModRM(cpu)
	local val = BUF_READ[bits](cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += bits // 8
	writeRM(cpu, mod, rm, val, bits)
end

OPCODES[0xC8] = function(cpu)                             -- ENTER imm16, imm8
	local bits = OS(cpu)
	local frameSize = buffer.readu16(cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += 2
	local level = bit32.band(buffer.readu8(cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP)), 31)
	cpu.EIP += 1
	cpu.ESP -= bits // 8
	BUF_WRITE[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), readR(cpu, 5, bits))
	local framePtr = bit32.extract(cpu.ESP, 0, 16)
	if level > 0 then
		for _ = 1, level - 1 do
			cpu.EBP = bit32.replace(cpu.EBP, bit32.band(bit32.extract(cpu.EBP, 0, 16) - bits // 8, 0xFFFF), 0, 16)
			local val = BUF_READ[bits](cpu.RAM, phys(cpu, cpu.SSBase + bit32.extract(cpu.EBP, 0, 16)))
			cpu.ESP -= bits // 8
			BUF_WRITE[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), val)
		end
		cpu.ESP -= bits // 8
		BUF_WRITE[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), framePtr)
	end
	writeR(cpu, 5, framePtr, bits)
	cpu.ESP = bit32.replace(cpu.ESP, bit32.band(bit32.extract(cpu.ESP, 0, 16) - frameSize, 0xFFFF), 0, 16)
end

OPCODES[0xC9] = function(cpu)                             -- LEAVE
	local bits = OS(cpu)
	local val = BUF_READ[bits](cpu.RAM, phys(cpu, cpu.SSBase + bit32.extract(cpu.EBP, 0, 16)))
	cpu.ESP = bit32.replace(cpu.ESP, bit32.band(bit32.extract(cpu.EBP, 0, 16) + bits // 8, 0xFFFF), 0, 16)
	writeR(cpu, 5, val, bits)
end

local function retFar(cpu, n)
	local bits = OS(cpu)
	local ip = BUF_READ[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP))
	cpu.ESP += bits // 8
	local cs = BUF_READ[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP))
	cpu.ESP += bits // 8 + n
	cpu.CS = bit32.extract(cs, 0, 16)
	cpu.CSBase = cpu.CS * 16
	cpu.EIP = ip
end

OPCODES[0xCA] = function(cpu)                             -- RETF imm16
	local n = buffer.readu16(cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += 2
	retFar(cpu, n)
end

OPCODES[0xCB] = function(cpu) retFar(cpu, 0) end          -- RETF

OPCODES[0xCC] = function(cpu) cpu:INT(3) end              -- INT3

OPCODES[0xCD] = function(cpu)                             -- INT imm8
	local n = buffer.readu8(cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += 1
	cpu:INT(n)
end

OPCODES[0xCE] = function(cpu)                             -- INTO
	if bit32.extract(cpu.EFLAGS, 11, 1) == 1 then cpu:INT(4) end
end

OPCODES[0xCF] = function(cpu)                             -- IRET
	local bits = OS(cpu)
	local ip    = BUF_READ[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP))
	cpu.ESP += bits // 8
	local cs    = BUF_READ[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP))
	cpu.ESP += bits // 8
	local flags = BUF_READ[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP))
	cpu.ESP += bits // 8
	cpu.EIP = ip
	cpu.CS = bit32.extract(cs, 0, 16)
	cpu.CSBase = cpu.CS * 16
	flags = bit32.replace(flags, 1, 1, 1)
	cpu.EFLAGS = bit32.replace(cpu.EFLAGS, flags, 0, bits)
end

local function shiftRM1(cpu, bits)
	local mod, reg, rm = ModRM(cpu)
	local a = readRM(cpu, mod, rm, bits)
	SHIFT_RM[reg](cpu, mod, rm, a, bits, 1)
end

local function shiftRMCL(cpu, bits)
	local mod, reg, rm = ModRM(cpu)
	local a = readRM(cpu, mod, rm, bits)
	local cnt = bit32.band(bit32.extract(cpu.ECX, 0, 8), 31)
	if cnt ~= 0 then SHIFT_RM[reg](cpu, mod, rm, a, bits, cnt) end
end

OPCODES[0xD0] = function(cpu) shiftRM1(cpu, 8)        end -- SHIFT r/m8, 1
OPCODES[0xD1] = function(cpu) shiftRM1(cpu, OS(cpu))  end -- SHIFT r/m16/32, 1
OPCODES[0xD2] = function(cpu) shiftRMCL(cpu, 8)       end -- SHIFT r/m8, CL
OPCODES[0xD3] = function(cpu) shiftRMCL(cpu, OS(cpu)) end -- SHIFT r/m16/32, CL

OPCODES[0xD4] = function(cpu)                             -- AAM
	local imm = buffer.readu8(cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += 1
	if imm == 0 then cpu:INT(0); return end
	local al = bit32.extract(cpu.EAX, 0, 8)
	local ah = al // imm
	al = al % imm
	cpu.EAX = bit32.replace(bit32.replace(cpu.EAX, ah, 8, 8), al, 0, 8)
	setFlagsLogic(cpu, al, 8)
end

OPCODES[0xD5] = function(cpu)                             -- AAD
	local imm = buffer.readu8(cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += 1
	local al = bit32.extract(cpu.EAX, 0, 8)
	local ah = bit32.extract(cpu.EAX, 8, 8)
	local result = bit32.band(al + ah * imm, 0xFF)
	cpu.EAX = bit32.replace(cpu.EAX, 0, 8, 8)
	cpu.EAX = bit32.replace(cpu.EAX, result, 0, 8)
	setFlagsLogic(cpu, result, 8)
end

OPCODES[0xD6] = function(cpu)                             -- SALC
	cpu.EAX = bit32.replace(cpu.EAX, bit32.extract(cpu.EFLAGS, 0, 1) == 1 and 0xFF or 0x00, 0, 8)
end

OPCODES[0xD7] = function(cpu)                             -- XLAT
	local seg = cpu.SEG_OVERRIDE and cpu[SEG_BASE[cpu.SEG_OVERRIDE]] or cpu.DSBase
	local addr = bit32.band(bit32.extract(cpu.EBX, 0, 16) + bit32.extract(cpu.EAX, 0, 8), 0xFFFF)
	cpu.EAX = bit32.replace(cpu.EAX, buffer.readu8(cpu.RAM, phys(cpu, seg + addr)), 0, 8)
end

-- x87 FPU (CPU.new must initialise: FPU_ST={[0]=0,0,0,0,0,0,0,0}, FPU_TOP=0, FPU_SW=0, FPU_CW=0x037F, FPU_TW=0xFFFF)

local LOG2E = 1 / math.log(2)

local function stGet(cpu, i) return cpu.FPU_ST[(cpu.FPU_TOP + i) % 8] end
local function stSet(cpu, i, v) cpu.FPU_ST[(cpu.FPU_TOP + i) % 8] = v end

local function stPush(cpu, val)
	cpu.FPU_TOP = (cpu.FPU_TOP - 1) % 8
	local tag = (val ~= val or val == math.huge or val == -math.huge) and 2 or (val == 0 and 1 or 0)
	cpu.FPU_ST[cpu.FPU_TOP] = val
	cpu.FPU_TW = bit32.replace(cpu.FPU_TW, tag, cpu.FPU_TOP * 2, 2)
	cpu.FPU_SW = bit32.replace(cpu.FPU_SW, cpu.FPU_TOP, 11, 3)
end

local function stPop(cpu)
	local val = cpu.FPU_ST[cpu.FPU_TOP]
	cpu.FPU_TW = bit32.replace(cpu.FPU_TW, 3, cpu.FPU_TOP * 2, 2)
	cpu.FPU_TOP = (cpu.FPU_TOP + 1) % 8
	cpu.FPU_SW = bit32.replace(cpu.FPU_SW, cpu.FPU_TOP, 11, 3)
	return val
end

local function fpuSetCC(cpu, c0, c1, c2, c3)
	local sw = cpu.FPU_SW
	sw = bit32.replace(sw, c0, 8,  1)
	sw = bit32.replace(sw, c1, 9,  1)
	sw = bit32.replace(sw, c2, 10, 1)
	sw = bit32.replace(sw, c3, 14, 1)
	cpu.FPU_SW = sw
end

local function fpuCompare(cpu, a, b)
	if a ~= a or b ~= b then fpuSetCC(cpu, 1, 0, 1, 1)
	elseif a > b         then fpuSetCC(cpu, 0, 0, 0, 0)
	elseif a < b         then fpuSetCC(cpu, 1, 0, 0, 0)
	else                      fpuSetCC(cpu, 0, 0, 0, 1)
	end
end

local function fpuRound(cpu, x)
	local rc = bit32.extract(cpu.FPU_CW, 10, 2)
	if rc == 0 then
		local t, f = math.modf(x)
		if f >= 0.5 then return t + 1 elseif f <= -0.5 then return t - 1 else return t end
	elseif rc == 1 then return math.floor(x)
	elseif rc == 2 then return math.ceil(x)
	else local t = math.modf(x); return t end
end

local function readF80(ram, addr)
	local mLo = buffer.readu32(ram, addr)
	local mHi = buffer.readu32(ram, addr + 4)
	local se  = buffer.readu16(ram, addr + 8)
	local sign = bit32.rshift(se, 15)
	local exp  = bit32.band(se, 0x7FFF)
	if exp == 0x7FFF then
		return (mHi == 0x80000000 and mLo == 0) and (sign == 1 and -math.huge or math.huge) or (0/0)
	end
	if exp == 0 then return sign == 1 and -0.0 or 0.0 end
	local frac  = bit32.band(mHi, 0x7FFFFFFF) * (2^21) + bit32.rshift(mLo, 11)
	local value = (2^52 + frac) * 2^(exp - 16383 - 52)
	return sign == 1 and -value or value
end

local function writeF80(ram, addr, val)
	if val ~= val then
		buffer.writeu32(ram, addr, 0); buffer.writeu32(ram, addr + 4, 0xC0000000)
		buffer.writeu16(ram, addr + 8, 0x7FFF); return
	end
	local sign = 0
	if val < 0 then sign = 1; val = -val end
	if val == math.huge then
		buffer.writeu32(ram, addr, 0); buffer.writeu32(ram, addr + 4, 0x80000000)
		buffer.writeu16(ram, addr + 8, bit32.bor(bit32.lshift(sign, 15), 0x7FFF)); return
	end
	if val == 0 then
		buffer.writeu32(ram, addr, 0); buffer.writeu32(ram, addr + 4, 0)
		buffer.writeu16(ram, addr + 8, bit32.lshift(sign, 15)); return
	end
	local exp  = math.floor(math.log(val) * LOG2E)
	local mant = val * 2^(-exp)
	if mant < 1  then exp -= 1; mant = val * 2^(-exp) end
	if mant >= 2 then exp += 1; mant = val * 2^(-exp) end
	local mHf = mant * (2^31)
	local mHi = math.floor(mHf)
	local mLo = math.floor((mHf - mHi) * (2^32))
	buffer.writeu32(ram, addr,     bit32.band(mLo, 0xFFFFFFFF))
	buffer.writeu32(ram, addr + 4, bit32.band(mHi, 0xFFFFFFFF))
	buffer.writeu16(ram, addr + 8, bit32.bor(bit32.lshift(sign, 15), bit32.band(exp + 16383, 0x7FFF)))
end

local function fpuGetSW(cpu)
	return bit32.replace(cpu.FPU_SW, cpu.FPU_TOP, 11, 3)
end

local function fpuInit(cpu)
	cpu.FPU_CW = 0x037F; cpu.FPU_SW = 0; cpu.FPU_TW = 0xFFFF; cpu.FPU_TOP = 0
end

local function fpuLoadEnv(cpu, addr)
	cpu.FPU_CW = buffer.readu16(cpu.RAM, addr)
	local sw = buffer.readu16(cpu.RAM, phys(cpu, addr + 2))
	cpu.FPU_SW = sw; cpu.FPU_TOP = bit32.extract(sw, 11, 3)
	cpu.FPU_TW = buffer.readu16(cpu.RAM, phys(cpu, addr + 4))
end

local function fpuSaveEnv(cpu, addr)
	buffer.writeu16(cpu.RAM, addr,                 cpu.FPU_CW)
	buffer.writeu16(cpu.RAM, phys(cpu, addr + 2),  fpuGetSW(cpu))
	buffer.writeu16(cpu.RAM, phys(cpu, addr + 4),  cpu.FPU_TW)
	buffer.writeu32(cpu.RAM, phys(cpu, addr + 6),  0)
	buffer.writeu32(cpu.RAM, phys(cpu, addr + 10), 0)
end

local FPU_ARITH = {
	[0] = function(a, b) return a + b end,
	[1] = function(a, b) return a * b end,
	[4] = function(a, b) return a - b end,
	[5] = function(a, b) return b - a end,
	[6] = function(a, b) return a / b end,
	[7] = function(a, b) return b / a end,
}

local FPU_ARITH_STI = {
	[0] = function(a, b) return a + b end,
	[1] = function(a, b) return a * b end,
	[4] = function(a, b) return b - a end,
	[5] = function(a, b) return a - b end,
	[6] = function(a, b) return b / a end,
	[7] = function(a, b) return a / b end,
}

OPCODES[0xD8] = function(cpu)                             -- ESC D8
	local mod, reg, rm = ModRM(cpu)
	local st0 = stGet(cpu, 0)
	if mod == 3 then
		local sti = stGet(cpu, rm)
		if reg == 2 then fpuCompare(cpu, st0, sti); return end
		if reg == 3 then fpuCompare(cpu, st0, sti); stPop(cpu); return end
		local f = FPU_ARITH[reg]; if f then stSet(cpu, 0, f(st0, sti)) end
	else
		local m = buffer.readf32(cpu.RAM, LA16(cpu, mod, rm))
		if reg == 2 then fpuCompare(cpu, st0, m); return end
		if reg == 3 then fpuCompare(cpu, st0, m); stPop(cpu); return end
		local f = FPU_ARITH[reg]; if f then stSet(cpu, 0, f(st0, m)) end
	end
end

local D9_REG = {}

local function fxchST(cpu, rm)
	local t = stGet(cpu, 0); local s = stGet(cpu, rm)
	stSet(cpu, 0, s); stSet(cpu, rm, t)
	local p0 = cpu.FPU_TOP; local pi = (cpu.FPU_TOP + rm) % 8
	local t0 = bit32.extract(cpu.FPU_TW, p0 * 2, 2)
	local ti = bit32.extract(cpu.FPU_TW, pi * 2, 2)
	cpu.FPU_TW = bit32.replace(bit32.replace(cpu.FPU_TW, ti, p0 * 2, 2), t0, pi * 2, 2)
end
for i = 0, 7 do D9_REG[0xC0 + i] = fxchST end               -- FXCH ST(i)

D9_REG[0xD0] = function(cpu, rm) end                          -- FNOP
D9_REG[0xE0] = function(cpu, rm) stSet(cpu, 0, -stGet(cpu, 0)) end                     -- FCHS
D9_REG[0xE1] = function(cpu, rm) stSet(cpu, 0, math.abs(stGet(cpu, 0))) end            -- FABS
D9_REG[0xE4] = function(cpu, rm) fpuCompare(cpu, stGet(cpu, 0), 0) end                 -- FTST
D9_REG[0xE5] = function(cpu, rm)                              -- FXAM
	local v  = stGet(cpu, 0)
	local tw = bit32.extract(cpu.FPU_TW, cpu.FPU_TOP * 2, 2)
	local sign = v < 0 and 1 or 0
	local c0, c2, c3
	if   tw == 3                             then c0=1; c2=0; c3=1
	elseif v ~= v                            then c0=1; c2=0; c3=0
	elseif v == math.huge or v == -math.huge then c0=1; c2=1; c3=0
	elseif v == 0                            then c0=0; c2=0; c3=1
	else                                          c0=0; c2=1; c3=0 end
	fpuSetCC(cpu, c0, sign, c2, c3)
end
D9_REG[0xE8] = function(cpu, rm) stPush(cpu, 1) end                                    -- FLD1
D9_REG[0xE9] = function(cpu, rm) stPush(cpu, math.log(10) * LOG2E) end                 -- FLDL2T
D9_REG[0xEA] = function(cpu, rm) stPush(cpu, LOG2E) end                                -- FLDL2E
D9_REG[0xEB] = function(cpu, rm) stPush(cpu, math.pi) end                              -- FLDPI
D9_REG[0xEC] = function(cpu, rm) stPush(cpu, math.log(2) / math.log(10)) end          -- FLDLG2
D9_REG[0xED] = function(cpu, rm) stPush(cpu, math.log(2)) end                         -- FLDLN2
D9_REG[0xEE] = function(cpu, rm) stPush(cpu, 0) end                                    -- FLDZ
D9_REG[0xF0] = function(cpu, rm) stSet(cpu, 0, 2^stGet(cpu, 0) - 1) end               -- F2XM1
D9_REG[0xF1] = function(cpu, rm)                              -- FYL2X
	local x = stPop(cpu); stSet(cpu, 0, stGet(cpu, 0) * math.log(x) * LOG2E)
end
D9_REG[0xF2] = function(cpu, rm)                              -- FPTAN
	stSet(cpu, 0, math.tan(stGet(cpu, 0))); stPush(cpu, 1)
	cpu.FPU_SW = bit32.replace(cpu.FPU_SW, 0, 10, 1)
end
D9_REG[0xF3] = function(cpu, rm)                              -- FPATAN
	local x = stPop(cpu); stSet(cpu, 0, math.atan2(stGet(cpu, 0), x))
end
D9_REG[0xF4] = function(cpu, rm)                              -- FXTRACT
	local v   = stGet(cpu, 0)
	local exp = v ~= 0 and math.floor(math.log(math.abs(v)) * LOG2E) or -math.huge
	stSet(cpu, 0, exp); stPush(cpu, v ~= 0 and v * 2^(-exp) or v)
end
D9_REG[0xF5] = function(cpu, rm)                              -- FPREM1
	local d  = stGet(cpu, 1)
	local qi = math.floor(stGet(cpu, 0) / d + 0.5)
	stSet(cpu, 0, stGet(cpu, 0) - qi * d)
	cpu.FPU_SW = bit32.replace(cpu.FPU_SW, 0, 10, 1)
end
D9_REG[0xF6] = function(cpu, rm)                              -- FDECSTP
	cpu.FPU_TOP = (cpu.FPU_TOP - 1) % 8
	cpu.FPU_SW  = bit32.replace(cpu.FPU_SW, cpu.FPU_TOP, 11, 3)
end
D9_REG[0xF7] = function(cpu, rm)                              -- FINCSTP
	cpu.FPU_TOP = (cpu.FPU_TOP + 1) % 8
	cpu.FPU_SW  = bit32.replace(cpu.FPU_SW, cpu.FPU_TOP, 11, 3)
end
D9_REG[0xF8] = function(cpu, rm)                              -- FPREM
	local d = stGet(cpu, 1)
	local q = math.modf(stGet(cpu, 0) / d)
	stSet(cpu, 0, stGet(cpu, 0) - q * d)
	cpu.FPU_SW = bit32.replace(cpu.FPU_SW, 0, 10, 1)
end
D9_REG[0xF9] = function(cpu, rm)                              -- FYL2XP1
	local x = stPop(cpu); stSet(cpu, 0, stGet(cpu, 0) * math.log(x + 1) * LOG2E)
end
D9_REG[0xFA] = function(cpu, rm) stSet(cpu, 0, math.sqrt(stGet(cpu, 0))) end          -- FSQRT
D9_REG[0xFB] = function(cpu, rm)                              -- FSINCOS
	local v = stGet(cpu, 0)
	stSet(cpu, 0, math.sin(v)); stPush(cpu, math.cos(v))
	cpu.FPU_SW = bit32.replace(cpu.FPU_SW, 0, 10, 1)
end
D9_REG[0xFC] = function(cpu, rm) stSet(cpu, 0, fpuRound(cpu, stGet(cpu, 0))) end      -- FRNDINT
D9_REG[0xFD] = function(cpu, rm)                              -- FSCALE
	local q = math.modf(stGet(cpu, 1)); stSet(cpu, 0, stGet(cpu, 0) * 2^q)
end
D9_REG[0xFE] = function(cpu, rm)                              -- FSIN
	stSet(cpu, 0, math.sin(stGet(cpu, 0)))
	cpu.FPU_SW = bit32.replace(cpu.FPU_SW, 0, 10, 1)
end
D9_REG[0xFF] = function(cpu, rm)                              -- FCOS
	stSet(cpu, 0, math.cos(stGet(cpu, 0)))
	cpu.FPU_SW = bit32.replace(cpu.FPU_SW, 0, 10, 1)
end

OPCODES[0xD9] = function(cpu)                             -- ESC D9
	local mod, reg, rm = ModRM(cpu)
	if mod ~= 3 then
		local addr = LA16(cpu, mod, rm)
		if     reg == 0 then stPush(cpu, buffer.readf32(cpu.RAM, addr))
		elseif reg == 2 then buffer.writef32(cpu.RAM, addr, stGet(cpu, 0))
		elseif reg == 3 then buffer.writef32(cpu.RAM, addr, stPop(cpu))
		elseif reg == 4 then fpuLoadEnv(cpu, addr)
		elseif reg == 5 then cpu.FPU_CW = buffer.readu16(cpu.RAM, addr)
		elseif reg == 6 then fpuSaveEnv(cpu, addr)
		elseif reg == 7 then buffer.writeu16(cpu.RAM, addr, cpu.FPU_CW)
		end
		return
	end
	local b = bit32.bor(0xC0, bit32.lshift(reg, 3), rm)
	local f = D9_REG[b]; if f then f(cpu, rm) end
end

OPCODES[0xDA] = function(cpu)                             -- ESC DA
	local mod, reg, rm = ModRM(cpu)
	if mod == 3 then
		if reg == 5 and rm == 1 then                                           -- FUCOMPP
			fpuCompare(cpu, stGet(cpu, 0), stGet(cpu, 1)); stPop(cpu); stPop(cpu)
		end
	else
		local m   = signExtend(buffer.readu32(cpu.RAM, LA16(cpu, mod, rm)), 32)
		local st0 = stGet(cpu, 0)
		if reg == 2 then fpuCompare(cpu, st0, m); return end
		if reg == 3 then fpuCompare(cpu, st0, m); stPop(cpu); return end
		local f = FPU_ARITH[reg]; if f then stSet(cpu, 0, f(st0, m)) end
	end
end

local DB_MEM = {
	[0] = function(cpu, addr) stPush(cpu, signExtend(buffer.readu32(cpu.RAM, addr), 32)) end, -- FILD m32
	[2] = function(cpu, addr) buffer.writeu32(cpu.RAM, addr, bit32.band(fpuRound(cpu, stGet(cpu, 0)), 0xFFFFFFFF)) end, -- FIST m32
	[3] = function(cpu, addr) buffer.writeu32(cpu.RAM, addr, bit32.band(fpuRound(cpu, stPop(cpu)), 0xFFFFFFFF)) end,    -- FISTP m32
	[5] = function(cpu, addr) stPush(cpu, readF80(cpu.RAM, addr)) end,         -- FLD m80
	[7] = function(cpu, addr) writeF80(cpu.RAM, addr, stPop(cpu)) end,         -- FSTP m80
}

OPCODES[0xDB] = function(cpu)                             -- ESC DB
	local mod, reg, rm = ModRM(cpu)
	if mod == 3 then
		if     reg == 4 and rm == 2 then cpu.FPU_SW = bit32.band(cpu.FPU_SW, 0x7F00) -- FNCLEX
		elseif reg == 4 and rm == 3 then fpuInit(cpu)                                 -- FNINIT
		end
	else
		local f = DB_MEM[reg]; if f then f(cpu, LA16(cpu, mod, rm)) end
	end
end

OPCODES[0xDC] = function(cpu)                             -- ESC DC
	local mod, reg, rm = ModRM(cpu)
	if mod == 3 then
		local st0 = stGet(cpu, 0); local sti = stGet(cpu, rm)
		if reg == 2 then fpuCompare(cpu, sti, st0); return end
		if reg == 3 then fpuCompare(cpu, sti, st0); stPop(cpu); return end
		local f = FPU_ARITH_STI[reg]; if f then stSet(cpu, rm, f(sti, st0)) end
	else
		local m   = buffer.readf64(cpu.RAM, LA16(cpu, mod, rm))
		local st0 = stGet(cpu, 0)
		if reg == 2 then fpuCompare(cpu, st0, m); return end
		if reg == 3 then fpuCompare(cpu, st0, m); stPop(cpu); return end
		local f = FPU_ARITH[reg]; if f then stSet(cpu, 0, f(st0, m)) end
	end
end

local DD_REG = {
	[0] = function(cpu, rm) cpu.FPU_TW = bit32.replace(cpu.FPU_TW, 3, ((cpu.FPU_TOP + rm) % 8) * 2, 2) end, -- FFREE ST(i)
	[2] = function(cpu, rm) stSet(cpu, rm, stGet(cpu, 0)) end,                 -- FST ST(i)
	[3] = function(cpu, rm) stSet(cpu, rm, stGet(cpu, 0)); stPop(cpu) end,     -- FSTP ST(i)
	[4] = function(cpu, rm) fpuCompare(cpu, stGet(cpu, 0), stGet(cpu, rm)) end, -- FUCOM ST(i)
	[5] = function(cpu, rm) fpuCompare(cpu, stGet(cpu, 0), stGet(cpu, rm)); stPop(cpu) end, -- FUCOMP ST(i)
}

local DD_MEM = {
	[0] = function(cpu, addr) stPush(cpu, buffer.readf64(cpu.RAM, addr)) end,  -- FLD m64
	[2] = function(cpu, addr) buffer.writef64(cpu.RAM, addr, stGet(cpu, 0)) end, -- FST m64
	[3] = function(cpu, addr) buffer.writef64(cpu.RAM, addr, stPop(cpu)) end,  -- FSTP m64
	[4] = function(cpu, addr)                                                  -- FRSTOR
		fpuLoadEnv(cpu, addr)
		for i = 0, 7 do cpu.FPU_ST[i] = readF80(cpu.RAM, phys(cpu, addr + 14 + i * 10)) end
	end,
	[6] = function(cpu, addr)                                                  -- FNSAVE
		fpuSaveEnv(cpu, addr)
		for i = 0, 7 do writeF80(cpu.RAM, phys(cpu, addr + 14 + i * 10), cpu.FPU_ST[i]) end
		fpuInit(cpu)
	end,
	[7] = function(cpu, addr) buffer.writeu16(cpu.RAM, addr, fpuGetSW(cpu)) end, -- FNSTSW m16
}

OPCODES[0xDD] = function(cpu)                             -- ESC DD
	local mod, reg, rm = ModRM(cpu)
	if mod == 3 then
		local f = DD_REG[reg]; if f then f(cpu, rm) end
	else
		local f = DD_MEM[reg]; if f then f(cpu, LA16(cpu, mod, rm)) end
	end
end

OPCODES[0xDE] = function(cpu)                             -- ESC DE
	local mod, reg, rm = ModRM(cpu)
	if mod == 3 then
		if reg == 3 and rm == 1 then                                           -- FCOMPP
			fpuCompare(cpu, stGet(cpu, 0), stGet(cpu, 1)); stPop(cpu); stPop(cpu); return
		end
		local st0 = stGet(cpu, 0); local sti = stGet(cpu, rm)
		local f = FPU_ARITH_STI[reg]
		if f then stSet(cpu, rm, f(sti, st0)); stPop(cpu) end
	else
		local m   = signExtend(buffer.readu16(cpu.RAM, LA16(cpu, mod, rm)), 16)
		local st0 = stGet(cpu, 0)
		if reg == 2 then fpuCompare(cpu, st0, m); return end
		if reg == 3 then fpuCompare(cpu, st0, m); stPop(cpu); return end
		local f = FPU_ARITH[reg]; if f then stSet(cpu, 0, f(st0, m)) end
	end
end

local DF_MEM = {
	[0] = function(cpu, addr) stPush(cpu, signExtend(buffer.readu16(cpu.RAM, addr), 16)) end, -- FILD m16
	[2] = function(cpu, addr) buffer.writeu16(cpu.RAM, addr, bit32.band(fpuRound(cpu, stGet(cpu, 0)), 0xFFFF)) end, -- FIST m16
	[3] = function(cpu, addr) buffer.writeu16(cpu.RAM, addr, bit32.band(fpuRound(cpu, stPop(cpu)), 0xFFFF)) end,    -- FISTP m16
	[4] = function(cpu, addr)                                                  -- FBLD m80 (BCD)
		local val = 0
		for i = 8, 0, -1 do
			local byte = buffer.readu8(cpu.RAM, phys(cpu, addr + i))
			val = val * 100 + bit32.rshift(byte, 4) * 10 + bit32.band(byte, 0xF)
		end
		local sign = bit32.rshift(buffer.readu8(cpu.RAM, phys(cpu, addr + 9)), 7)
		stPush(cpu, sign == 1 and -val or val)
	end,
	[5] = function(cpu, addr)                                                  -- FILD m64
		local lo  = buffer.readu32(cpu.RAM, addr)
		local hi  = buffer.readu32(cpu.RAM, phys(cpu, addr + 4))
		local neg = hi >= 0x80000000
		if neg then
			lo = bit32.band(bit32.bnot(lo) + 1, 0xFFFFFFFF)
			hi = bit32.band(bit32.bnot(hi) + (lo == 0 and 1 or 0), 0xFFFFFFFF)
		end
		stPush(cpu, neg and -(hi * (2^32) + lo) or (hi * (2^32) + lo))
	end,
	[6] = function(cpu, addr)                                                  -- FBSTP m80 (BCD)
		local v   = fpuRound(cpu, stPop(cpu))
		local neg = v < 0; v = math.abs(v)
		for i = 0, 8 do
			local d = v % 100; v = math.floor(v / 100)
			buffer.writeu8(cpu.RAM, phys(cpu, addr + i), bit32.bor(bit32.lshift(math.floor(d / 10), 4), d % 10))
		end
		buffer.writeu8(cpu.RAM, phys(cpu, addr + 9), neg and 0x80 or 0)
	end,
	[7] = function(cpu, addr)                                                  -- FISTP m64
		local v   = fpuRound(cpu, stPop(cpu))
		local neg = v < 0; v = math.abs(v)
		local lo = v % (2^32); local hi = math.floor(v / (2^32))
		if neg then
			lo = bit32.band(bit32.bnot(math.floor(lo)) + 1, 0xFFFFFFFF)
			hi = bit32.band(bit32.bnot(hi) + (lo == 0 and 1 or 0), 0xFFFFFFFF)
		end
		buffer.writeu32(cpu.RAM, addr,                bit32.band(math.floor(lo), 0xFFFFFFFF))
		buffer.writeu32(cpu.RAM, phys(cpu, addr + 4), bit32.band(hi, 0xFFFFFFFF))
	end,
}

OPCODES[0xDF] = function(cpu)                             -- ESC DF
	local mod, reg, rm = ModRM(cpu)
	if mod == 3 then
		if reg == 4 and rm == 0 then                                           -- FNSTSW AX
			cpu.EAX = bit32.replace(cpu.EAX, fpuGetSW(cpu), 0, 16)
		end
	else
		local f = DF_MEM[reg]; if f then f(cpu, LA16(cpu, mod, rm)) end
	end
end

local function loopDecCX(cpu)
	local disp = buffer.readi8(cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += 1
	local cx = bit32.band(bit32.extract(cpu.ECX, 0, 16) - 1, 0xFFFF)
	cpu.ECX = bit32.replace(cpu.ECX, cx, 0, 16)
	return disp, cx
end

OPCODES[0xE0] = function(cpu)                             -- LOOPNZ
	local disp, cx = loopDecCX(cpu)
	if cx ~= 0 and bit32.extract(cpu.EFLAGS, 6, 1) == 0 then
		cpu.EIP = bit32.band(cpu.EIP + disp, bit32.lshift(1, OS(cpu)) - 1)
	end
end

OPCODES[0xE1] = function(cpu)                             -- LOOPZ
	local disp, cx = loopDecCX(cpu)
	if cx ~= 0 and bit32.extract(cpu.EFLAGS, 6, 1) == 1 then
		cpu.EIP = bit32.band(cpu.EIP + disp, bit32.lshift(1, OS(cpu)) - 1)
	end
end

OPCODES[0xE2] = function(cpu)                             -- LOOP
	local disp, cx = loopDecCX(cpu)
	if cx ~= 0 then cpu.EIP = bit32.band(cpu.EIP + disp, bit32.lshift(1, OS(cpu)) - 1) end
end

OPCODES[0xE3] = function(cpu)                             -- JCXZ / JECXZ
	local disp = buffer.readi8(cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += 1
	local sz = cpu.ADDRSIZE_OVERRIDE and 32 or 16
	if bit32.extract(cpu.ECX, 0, sz) == 0 then
		cpu.EIP = bit32.band(cpu.EIP + disp, bit32.lshift(1, OS(cpu)) - 1)
	end
end

local function inPortImm(cpu, bits)
	local port = buffer.readu8(cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += 1
	writeR(cpu, 0, cpu.PortsIn[bit32.band(port, 0x3FF)](), bits)
end

local function outPortImm(cpu, bits)
	local port = buffer.readu8(cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += 1
	cpu.PortsOut[bit32.band(port, 0x3FF)](readR(cpu, 0, bits))
end

local function inPortDX(cpu, bits)
	writeR(cpu, 0, cpu.PortsIn[bit32.band(bit32.extract(cpu.EDX, 0, 16), 0x3FF)](), bits)
end

local function outPortDX(cpu, bits)
	cpu.PortsOut[bit32.band(bit32.extract(cpu.EDX, 0, 16), 0x3FF)](readR(cpu, 0, bits))
end

OPCODES[0xE4] = function(cpu) inPortImm(cpu, 8)        end -- IN AL, imm8
OPCODES[0xE5] = function(cpu) inPortImm(cpu, OS(cpu))  end -- IN AX/EAX, imm8
OPCODES[0xE6] = function(cpu) outPortImm(cpu, 8)       end -- OUT imm8, AL
OPCODES[0xE7] = function(cpu) outPortImm(cpu, OS(cpu)) end -- OUT imm8, AX/EAX

OPCODES[0xE8] = function(cpu)                             -- CALL rel16/32
	local bits = OS(cpu)
	local disp = BUF_READI[bits](cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += bits // 8
	cpu.ESP -= bits // 8
	BUF_WRITE[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), cpu.EIP)
	cpu.EIP = bit32.band(cpu.EIP + disp, bit32.lshift(1, bits) - 1)
end

OPCODES[0xE9] = function(cpu)                             -- JMP rel16/32
	local bits = OS(cpu)
	local disp = BUF_READI[bits](cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += bits // 8
	cpu.EIP = bit32.band(cpu.EIP + disp, bit32.lshift(1, bits) - 1)
end

OPCODES[0xEA] = function(cpu)                             -- JMP FAR imm16:16/32
	local bits = OS(cpu)
	local ip = BUF_READ[bits](cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += bits // 8
	local cs = buffer.readu16(cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += 2
	cpu.CS = cs
	cpu.CSBase = cs * 16
	cpu.EIP = ip
end

OPCODES[0xEB] = function(cpu)                             -- JMP rel8
	local disp = buffer.readi8(cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += 1
	cpu.EIP += disp
end

OPCODES[0xEC] = function(cpu) inPortDX(cpu, 8)        end -- IN AL, DX
OPCODES[0xED] = function(cpu) inPortDX(cpu, OS(cpu))  end -- IN AX/EAX, DX
OPCODES[0xEE] = function(cpu) outPortDX(cpu, 8)       end -- OUT DX, AL
OPCODES[0xEF] = function(cpu) outPortDX(cpu, OS(cpu)) end -- OUT DX, AX/EAX

-- 0xF0 = LOCK prefix, handled in CPU:Step() prefix loop
OPCODES[0xF1] = function(cpu) cpu:INT(1) end              -- ICEBP
-- 0xF2 = REPNE prefix, handled in CPU:Step() prefix loop
-- 0xF3 = REP prefix, handled in CPU:Step() prefix loop

OPCODES[0xF4] = function(cpu)                             -- HLT
	cpu.EIP -= 1
end

OPCODES[0xF5] = function(cpu)                             -- CMC
	cpu.EFLAGS = bit32.bxor(cpu.EFLAGS, 1)
end

local function mul32to64(a, b)
	local aLo = bit32.band(a, 0xFFFF)
	local aHi = bit32.rshift(a, 16)
	local bLo = bit32.band(b, 0xFFFF)
	local bHi = bit32.rshift(b, 16)
	local p0 = aLo * bLo
	local p1 = aLo * bHi
	local p2 = aHi * bLo
	local p3 = aHi * bHi
	local mid = p1 + p2
	local midLo = bit32.band(mid, 0xFFFF)
	local midHi = math.floor(mid / 0x10000)
	local lo = p0 + midLo * 0x10000
	local rLo = bit32.band(lo, 0xFFFFFFFF)
	local rHi = bit32.band(p3 + midHi + math.floor(lo / 0x100000000), 0xFFFFFFFF)
	return rHi, rLo
end

local function imul32to64(a, b)
	local sa = a >= 0x80000000 and (a - 0x100000000) or a
	local sb = b >= 0x80000000 and (b - 0x100000000) or b
	local neg = (sa < 0) ~= (sb < 0)
	local hi, lo = mul32to64(math.abs(sa), math.abs(sb))
	if neg and (hi ~= 0 or lo ~= 0) then
		lo = bit32.band(bit32.bnot(lo) + 1, 0xFFFFFFFF)
		hi = bit32.band(bit32.bnot(hi) + (lo == 0 and 1 or 0), 0xFFFFFFFF)
	end
	return hi, lo
end

local function udiv64(hiNum, loNum, d)
	local q = 0
	local rem = hiNum
	for i = 31, 0, -1 do
		rem = rem * 2 + bit32.extract(loNum, i, 1)
		if rem >= d then
			rem = rem - d
			q = bit32.replace(q, 1, i, 1)
		end
	end
	return q, rem
end

local GRP3 = {
	[0] = function(cpu, mod, rm, a, bits)                     -- TEST
		local b = BUF_READ[bits](cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
		cpu.EIP += bits // 8
		setFlagsLogic(cpu, bit32.band(a, b), bits)
	end,
	[2] = function(cpu, mod, rm, a, bits)                     -- NOT
		writeRM(cpu, mod, rm, bit32.bnot(a), bits)
	end,
	[3] = function(cpu, mod, rm, a, bits)                     -- NEG
		local result = 0 - a
		writeRM(cpu, mod, rm, result, bits)
		setFlagsSub(cpu, 0, a, result, bits)
	end,
	[4] = function(cpu, mod, rm, a, bits)                     -- MUL
		if bits == 8 then
			local result = readR(cpu, 0, 8) * a
			writeR(cpu, 0, result, 16)
			local cf = (bit32.extract(bit32.band(result, 0xFFFF), 8, 8) ~= 0) and 1 or 0
			cpu.EFLAGS = bit32.replace(bit32.replace(cpu.EFLAGS, cf, 0, 1), cf, 11, 1)
		elseif bits == 16 then
			local result = readR(cpu, 0, 16) * a
			local lo = bit32.band(result, 0xFFFF)
			local hi = bit32.band(math.floor(result / 0x10000), 0xFFFF)
			writeR(cpu, 0, lo, 16); writeR(cpu, 2, hi, 16)
			local cf = (hi ~= 0) and 1 or 0
			cpu.EFLAGS = bit32.replace(bit32.replace(cpu.EFLAGS, cf, 0, 1), cf, 11, 1)
		else
			local hi, lo = mul32to64(readR(cpu, 0, 32), a)
			writeR(cpu, 0, lo, 32); writeR(cpu, 2, hi, 32)
			local cf = (hi ~= 0) and 1 or 0
			cpu.EFLAGS = bit32.replace(bit32.replace(cpu.EFLAGS, cf, 0, 1), cf, 11, 1)
		end
	end,
	[5] = function(cpu, mod, rm, a, bits)                     -- IMUL
		if bits == 8 then
			local result = signExtend(readR(cpu, 0, 8), 8) * signExtend(a, 8)
			local ax = bit32.band(result, 0xFFFF)
			writeR(cpu, 0, ax, 16)
			local cf = (signExtend(bit32.band(ax, 0xFF), 8) ~= result) and 1 or 0
			cpu.EFLAGS = bit32.replace(bit32.replace(cpu.EFLAGS, cf, 0, 1), cf, 11, 1)
		elseif bits == 16 then
			local result = signExtend(readR(cpu, 0, 16), 16) * signExtend(a, 16)
			local lo = bit32.band(result, 0xFFFF)
			local hi = bit32.band(math.floor(result / 0x10000), 0xFFFF)
			writeR(cpu, 0, lo, 16); writeR(cpu, 2, hi, 16)
			local cf = (signExtend(lo, 16) ~= result) and 1 or 0
			cpu.EFLAGS = bit32.replace(bit32.replace(cpu.EFLAGS, cf, 0, 1), cf, 11, 1)
		else
			local hi, lo = imul32to64(readR(cpu, 0, 32), a)
			writeR(cpu, 0, lo, 32); writeR(cpu, 2, hi, 32)
			local signLo = bit32.extract(lo, 31, 1)
			local cf = (hi ~= (signLo == 1 and 0xFFFFFFFF or 0)) and 1 or 0
			cpu.EFLAGS = bit32.replace(bit32.replace(cpu.EFLAGS, cf, 0, 1), cf, 11, 1)
		end
	end,
	[6] = function(cpu, mod, rm, a, bits)                     -- DIV
		if a == 0 then cpu:INT(0); return end
		if bits == 8 then
			local num = readR(cpu, 0, 16)
			local quot = math.floor(num / a)
			local rem = num % a
			if quot > 0xFF then cpu:INT(0); return end
			cpu.EAX = bit32.replace(bit32.replace(cpu.EAX, quot, 0, 8), rem, 8, 8)
		elseif bits == 16 then
			local lo = readR(cpu, 0, 16); local hi = readR(cpu, 2, 16)
			local num = hi * 0x10000 + lo
			local quot = math.floor(num / a); local rem = num % a
			if quot > 0xFFFF then cpu:INT(0); return end
			writeR(cpu, 0, quot, 16); writeR(cpu, 2, rem, 16)
		else
			local lo = readR(cpu, 0, 32); local hi = readR(cpu, 2, 32)
			if hi >= a then cpu:INT(0); return end
			local quot, rem = udiv64(hi, lo, a)
			writeR(cpu, 0, quot, 32); writeR(cpu, 2, rem, 32)
		end
	end,
	[7] = function(cpu, mod, rm, a, bits)                     -- IDIV
		if a == 0 then cpu:INT(0); return end
		local sa = signExtend(a, bits)
		if bits == 8 then
			local num = signExtend(readR(cpu, 0, 16), 16)
			local quot, _ = math.modf(num / sa)
			local rem = num - quot * sa
			if quot < -128 or quot > 127 then cpu:INT(0); return end
			cpu.EAX = bit32.replace(bit32.replace(cpu.EAX, bit32.band(quot, 0xFF), 0, 8), bit32.band(rem, 0xFF), 8, 8)
		elseif bits == 16 then
			local lo = readR(cpu, 0, 16); local hi = readR(cpu, 2, 16)
			local snum = (hi >= 0x8000 and (hi - 0x10000) or hi) * 0x10000 + lo
			local quot, _ = math.modf(snum / sa)
			local rem = snum - quot * sa
			if quot < -32768 or quot > 32767 then cpu:INT(0); return end
			writeR(cpu, 0, bit32.band(quot, 0xFFFF), 16)
			writeR(cpu, 2, bit32.band(rem, 0xFFFF), 16)
		else
			local lo = readR(cpu, 0, 32); local hi = readR(cpu, 2, 32)
			local negNum = hi >= 0x80000000
			local negDiv = sa < 0
			local absA = negDiv and -sa or sa
			local absHi, absLo
			if negNum then
				absLo = bit32.band(bit32.bnot(lo) + 1, 0xFFFFFFFF)
				absHi = bit32.band(bit32.bnot(hi) + (absLo == 0 and 1 or 0), 0xFFFFFFFF)
			else
				absHi, absLo = hi, lo
			end
			if absHi >= absA then cpu:INT(0); return end
			local q, r = udiv64(absHi, absLo, absA)
			local negQ = negNum ~= negDiv
			if negQ then
				if q > 0x80000000 then cpu:INT(0); return end
				q = bit32.band(-q, 0xFFFFFFFF)
			else
				if q > 0x7FFFFFFF then cpu:INT(0); return end
			end
			if negNum and r ~= 0 then r = bit32.band(-r, 0xFFFFFFFF) end
			writeR(cpu, 0, q, 32); writeR(cpu, 2, r, 32)
		end
	end,
}
GRP3[1] = GRP3[0]                                             -- TEST (reg=1 alias)

local function grp3(cpu, bits)
	local mod, reg, rm = ModRM(cpu)
	local a = readRM(cpu, mod, rm, bits)
	GRP3[reg](cpu, mod, rm, a, bits)
end

OPCODES[0xF6] = function(cpu) grp3(cpu, 8)       end -- GRP3 r/m8
OPCODES[0xF7] = function(cpu) grp3(cpu, OS(cpu)) end -- GRP3 r/m16/32

OPCODES[0xF8] = function(cpu) cpu.EFLAGS = bit32.replace(cpu.EFLAGS, 0, 0,  1) end -- CLC
OPCODES[0xF9] = function(cpu) cpu.EFLAGS = bit32.replace(cpu.EFLAGS, 1, 0,  1) end -- STC
OPCODES[0xFA] = function(cpu) cpu.EFLAGS = bit32.replace(cpu.EFLAGS, 0, 9,  1) end -- CLI
OPCODES[0xFB] = function(cpu) cpu.EFLAGS = bit32.replace(cpu.EFLAGS, 1, 9,  1) end -- STI
OPCODES[0xFC] = function(cpu) cpu.EFLAGS = bit32.replace(cpu.EFLAGS, 0, 10, 1) end -- CLD
OPCODES[0xFD] = function(cpu) cpu.EFLAGS = bit32.replace(cpu.EFLAGS, 1, 10, 1) end -- STD

OPCODES[0xFE] = function(cpu)                             -- GRP4 r/m8
	local mod, reg, rm = ModRM(cpu)
	if reg > 1 then cpu:INT(6); return end
	local addr = mod ~= 3 and LA16(cpu, mod, rm) or nil
	local a = mod == 3 and readR(cpu, rm, 8) or buffer.readu8(cpu.RAM, addr)
	local result = reg == 0 and a + 1 or a - 1
	local of = reg == 0 and ((a == 0x7F) and 1 or 0) or ((a == 0x80) and 1 or 0)
	if mod == 3 then writeR(cpu, rm, result, 8)
	else buffer.writeu8(cpu.RAM, addr, bit32.band(result, 0xFF)) end
	setFlagsIncDec(cpu, a, result, 8, of)
end

local GRP5 = {
	[0] = function(cpu, mod, rm, addr, bits, a)               -- INC
		local mask = bit32.lshift(1, bits) - 1
		local result = a + 1
		local of = (a == bit32.rshift(mask, 1)) and 1 or 0
		writeRM(cpu, mod, rm, result, bits)
		setFlagsIncDec(cpu, a, result, bits, of)
	end,
	[1] = function(cpu, mod, rm, addr, bits, a)               -- DEC
		local result = a - 1
		local of = (a == bit32.lshift(1, bits - 1)) and 1 or 0
		writeRM(cpu, mod, rm, result, bits)
		setFlagsIncDec(cpu, a, result, bits, of)
	end,
	[2] = function(cpu, mod, rm, addr, bits, a)               -- CALL near indirect
		cpu.ESP -= bits // 8
		BUF_WRITE[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), cpu.EIP)
		cpu.EIP = bit32.band(a, bit32.lshift(1, bits) - 1)
	end,
	[3] = function(cpu, mod, rm, addr, bits, a)               -- CALL FAR indirect
		if mod == 3 then cpu:INT(6); return end
		local ip = BUF_READ[bits](cpu.RAM, addr)
		local cs = buffer.readu16(cpu.RAM, phys(cpu, (addr) + bits // 8))
		cpu.ESP -= bits // 8
		BUF_WRITE[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), cpu.CS)
		cpu.ESP -= bits // 8
		BUF_WRITE[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), cpu.EIP)
		cpu.CS = cs; cpu.CSBase = cs * 16; cpu.EIP = ip
	end,
	[4] = function(cpu, mod, rm, addr, bits, a)               -- JMP near indirect
		cpu.EIP = bit32.band(a, bit32.lshift(1, bits) - 1)
	end,
	[5] = function(cpu, mod, rm, addr, bits, a)               -- JMP FAR indirect
		if mod == 3 then cpu:INT(6); return end
		local ip = BUF_READ[bits](cpu.RAM, addr)
		local cs = buffer.readu16(cpu.RAM, phys(cpu, (addr) + bits // 8))
		cpu.CS = cs; cpu.CSBase = cs * 16; cpu.EIP = ip
	end,
	[6] = function(cpu, mod, rm, addr, bits, a)               -- PUSH
		cpu.ESP -= bits // 8
		BUF_WRITE[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), a)
	end,
}

OPCODES[0xFF] = function(cpu)                             -- GRP5 r/m16/32
	local bits = OS(cpu)
	local mod, reg, rm = ModRM(cpu)
	local addr = mod ~= 3 and LA16(cpu, mod, rm) or nil
	local a = mod == 3 and readR(cpu, rm, bits) or BUF_READ[bits](cpu.RAM, addr)
	local f = GRP5[reg]; if f then f(cpu, mod, rm, addr, bits, a) end
end

-- TODO: 0F 00 GRP6 (SLDT/STR/LLDT/LTR/VERR/VERW) — protected mode only
-- TODO: 0F 02 LAR — protected mode only
-- TODO: 0F 03 LSL — protected mode only
-- TODO: 0F 24 MOV r32, TRn — test registers, 486 only
-- TODO: 0F 26 MOV TRn, r32 — test registers, 486 only

OPCODES_0F[0x01] = function(cpu)                           -- GRP7
	local mod, reg, rm = ModRM(cpu)
	if mod == 3 then return end
	local addr = LA16(cpu, mod, rm)
	if     reg == 0 then                                   -- SGDT
		buffer.writeu16(cpu.RAM, addr,                cpu.GDTRLimit or 0)
		buffer.writeu32(cpu.RAM, phys(cpu, addr + 2), cpu.GDTRBase  or 0)
	elseif reg == 1 then                                   -- SIDT
		buffer.writeu16(cpu.RAM, addr,                cpu.IDTRLimit or 0x3FF)
		buffer.writeu32(cpu.RAM, phys(cpu, addr + 2), cpu.IDTRBase  or 0)
	elseif reg == 2 then                                   -- LGDT
		cpu.GDTRLimit = buffer.readu16(cpu.RAM, addr)
		cpu.GDTRBase  = buffer.readu32(cpu.RAM, phys(cpu, addr + 2))
	elseif reg == 3 then                                   -- LIDT
		cpu.IDTRLimit = buffer.readu16(cpu.RAM, addr)
		cpu.IDTRBase  = buffer.readu32(cpu.RAM, phys(cpu, addr + 2))
	elseif reg == 4 then                                   -- SMSW
		writeRM(cpu, mod, rm, bit32.band(cpu.CR0 or 0, 0xFFFF), 16)
	elseif reg == 6 then                                   -- LMSW
		local val = readRM(cpu, mod, rm, 16)
		cpu.CR0 = bit32.bor(bit32.band(cpu.CR0 or 0, 0xFFFF0000), bit32.band(val, 0xFFFF))
	end
	-- reg 7 = INVLPG, NOP in real mode
end

OPCODES_0F[0x06] = function(cpu)                           -- CLTS
	cpu.CR0 = bit32.band(cpu.CR0 or 0, bit32.bnot(8))
end

OPCODES_0F[0x0B] = function(cpu) cpu:INT(6) end            -- UD2

OPCODES_0F[0x20] = function(cpu)                           -- MOV r32, CRn
	local _mod, reg, rm = ModRM(cpu)
	local val = reg == 0 and (cpu.CR0 or 0) or (reg == 2 and (cpu.CR2 or 0) or (reg == 3 and (cpu.CR3 or 0) or 0))
	writeR(cpu, rm, val, 32)
end

OPCODES_0F[0x21] = function(cpu)                           -- MOV r32, DRn
	local _mod, reg, rm = ModRM(cpu)
	local val = reg == 6 and (cpu.DR6 or 0) or (reg == 7 and (cpu.DR7 or 0) or 0)
	writeR(cpu, rm, val, 32)
end

OPCODES_0F[0x22] = function(cpu)                           -- MOV CRn, r32
	local _mod, reg, rm = ModRM(cpu)
	local val = readR(cpu, rm, 32)
	if     reg == 0 then cpu.CR0 = val
	elseif reg == 2 then cpu.CR2 = val
	elseif reg == 3 then cpu.CR3 = val
	end
end

OPCODES_0F[0x23] = function(cpu)                           -- MOV DRn, r32
	local _mod, reg, rm = ModRM(cpu)
	local val = readR(cpu, rm, 32)
	if     reg == 6 then cpu.DR6 = val
	elseif reg == 7 then cpu.DR7 = val
	end
end

OPCODES_0F[0x31] = function(cpu)                           -- RDTSC
	local t = math.floor(os.clock() * 1e6)
	cpu.EAX = bit32.band(t, 0xFFFFFFFF)
	cpu.EDX = bit32.band(math.floor(t / 0x100000000), 0xFFFFFFFF)
end

local function jcc2(cpu, cond)                            -- Jcc rel16/32
	local bits = OS(cpu)
	local disp = BUF_READI[bits](cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP))
	cpu.EIP += bits // 8
	if cond then cpu.EIP = bit32.band(cpu.EIP + disp, bit32.lshift(1, bits) - 1) end
end

OPCODES_0F[0x80] = function(cpu) jcc2(cpu, fl(cpu, 11)) end                                  -- JO
OPCODES_0F[0x81] = function(cpu) jcc2(cpu, not fl(cpu, 11)) end                              -- JNO
OPCODES_0F[0x82] = function(cpu) jcc2(cpu, fl(cpu, 0)) end                                   -- JB
OPCODES_0F[0x83] = function(cpu) jcc2(cpu, not fl(cpu, 0)) end                               -- JNB
OPCODES_0F[0x84] = function(cpu) jcc2(cpu, fl(cpu, 6)) end                                   -- JZ
OPCODES_0F[0x85] = function(cpu) jcc2(cpu, not fl(cpu, 6)) end                               -- JNZ
OPCODES_0F[0x86] = function(cpu) jcc2(cpu, fl(cpu, 0) or fl(cpu, 6)) end                    -- JBE
OPCODES_0F[0x87] = function(cpu) jcc2(cpu, not fl(cpu, 0) and not fl(cpu, 6)) end            -- JA
OPCODES_0F[0x88] = function(cpu) jcc2(cpu, fl(cpu, 7)) end                                   -- JS
OPCODES_0F[0x89] = function(cpu) jcc2(cpu, not fl(cpu, 7)) end                               -- JNS
OPCODES_0F[0x8A] = function(cpu) jcc2(cpu, fl(cpu, 2)) end                                   -- JP
OPCODES_0F[0x8B] = function(cpu) jcc2(cpu, not fl(cpu, 2)) end                               -- JNP
OPCODES_0F[0x8C] = function(cpu) jcc2(cpu, fl(cpu, 7) ~= fl(cpu, 11)) end                   -- JL
OPCODES_0F[0x8D] = function(cpu) jcc2(cpu, fl(cpu, 7) == fl(cpu, 11)) end                   -- JGE
OPCODES_0F[0x8E] = function(cpu) jcc2(cpu, fl(cpu, 6) or fl(cpu, 7) ~= fl(cpu, 11)) end     -- JLE
OPCODES_0F[0x8F] = function(cpu) jcc2(cpu, not fl(cpu, 6) and fl(cpu, 7) == fl(cpu, 11)) end -- JG

local function setCC(cpu, cond)                           -- SETcc r/m8
	local mod, _reg, rm = ModRM(cpu)
	writeRM(cpu, mod, rm, cond and 1 or 0, 8)
end

OPCODES_0F[0x90] = function(cpu) setCC(cpu, fl(cpu, 11)) end                                  -- SETO
OPCODES_0F[0x91] = function(cpu) setCC(cpu, not fl(cpu, 11)) end                              -- SETNO
OPCODES_0F[0x92] = function(cpu) setCC(cpu, fl(cpu, 0)) end                                   -- SETB
OPCODES_0F[0x93] = function(cpu) setCC(cpu, not fl(cpu, 0)) end                               -- SETNB
OPCODES_0F[0x94] = function(cpu) setCC(cpu, fl(cpu, 6)) end                                   -- SETZ
OPCODES_0F[0x95] = function(cpu) setCC(cpu, not fl(cpu, 6)) end                               -- SETNZ
OPCODES_0F[0x96] = function(cpu) setCC(cpu, fl(cpu, 0) or fl(cpu, 6)) end                    -- SETBE
OPCODES_0F[0x97] = function(cpu) setCC(cpu, not fl(cpu, 0) and not fl(cpu, 6)) end            -- SETA
OPCODES_0F[0x98] = function(cpu) setCC(cpu, fl(cpu, 7)) end                                   -- SETS
OPCODES_0F[0x99] = function(cpu) setCC(cpu, not fl(cpu, 7)) end                               -- SETNS
OPCODES_0F[0x9A] = function(cpu) setCC(cpu, fl(cpu, 2)) end                                   -- SETP
OPCODES_0F[0x9B] = function(cpu) setCC(cpu, not fl(cpu, 2)) end                               -- SETNP
OPCODES_0F[0x9C] = function(cpu) setCC(cpu, fl(cpu, 7) ~= fl(cpu, 11)) end                   -- SETL
OPCODES_0F[0x9D] = function(cpu) setCC(cpu, fl(cpu, 7) == fl(cpu, 11)) end                   -- SETGE
OPCODES_0F[0x9E] = function(cpu) setCC(cpu, fl(cpu, 6) or fl(cpu, 7) ~= fl(cpu, 11)) end     -- SETLE
OPCODES_0F[0x9F] = function(cpu) setCC(cpu, not fl(cpu, 6) and fl(cpu, 7) == fl(cpu, 11)) end -- SETG

OPCODES_0F[0xA0] = function(cpu)                           -- PUSH FS
	cpu.ESP -= 2
	buffer.writeu16(cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), cpu.FS)
end

OPCODES_0F[0xA1] = function(cpu)                           -- POP FS
	local val = buffer.readu16(cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP))
	cpu.ESP += 2
	cpu.FS = val; cpu.FSBase = val * 16
end

OPCODES_0F[0xA2] = function(cpu)                           -- CPUID
	local eax = cpu.EAX
	if eax == 0 then
		cpu.EAX = 1
		cpu.EBX = 0x756E6547; cpu.EDX = 0x49656E69; cpu.ECX = 0x6C65746E
	elseif eax == 1 then
		cpu.EAX = 0x00000300
		cpu.EBX = 0; cpu.ECX = 0; cpu.EDX = 1
	else
		cpu.EAX = 0; cpu.EBX = 0; cpu.ECX = 0; cpu.EDX = 0
	end
end

local function btApply(cpu, mod, rm, addr, bits, idx, op)
	if mod == 3 then
		local val = readR(cpu, rm, bits)
		local b = bit32.extract(val, idx, 1)
		cpu.EFLAGS = bit32.replace(cpu.EFLAGS, b, 0, 1)
		if     op == 1 then writeR(cpu, rm, bit32.replace(val, 1,     idx, 1), bits)
		elseif op == 2 then writeR(cpu, rm, bit32.replace(val, 0,     idx, 1), bits)
		elseif op == 3 then writeR(cpu, rm, bit32.replace(val, 1 - b, idx, 1), bits)
		end
	else
		local val = BUF_READ[bits](cpu.RAM, addr)
		local b = bit32.extract(val, idx, 1)
		cpu.EFLAGS = bit32.replace(cpu.EFLAGS, b, 0, 1)
		if     op == 1 then BUF_WRITE[bits](cpu.RAM, addr, bit32.replace(val, 1,     idx, 1))
		elseif op == 2 then BUF_WRITE[bits](cpu.RAM, addr, bit32.replace(val, 0,     idx, 1))
		elseif op == 3 then BUF_WRITE[bits](cpu.RAM, addr, bit32.replace(val, 1 - b, idx, 1))
		end
	end
end

local function btReg(cpu, op)                             -- BT/BTS/BTR/BTC r/m, r
	local bits = OS(cpu)
	local mod, reg, rm = ModRM(cpu)
	local bitVal = signExtend(readR(cpu, reg, bits), bits)
	if mod == 3 then
		btApply(cpu, mod, rm, nil, bits, bitVal % bits, op)
	else
		local byteOff = math.floor(bitVal / bits) * (bits // 8)
		local bitOff  = bitVal % bits
		btApply(cpu, mod, rm, LA16(cpu, mod, rm) + byteOff, bits, bitOff, op)
	end
end

OPCODES_0F[0xA3] = function(cpu) btReg(cpu, 0) end         -- BT r/m, r
OPCODES_0F[0xAB] = function(cpu) btReg(cpu, 1) end         -- BTS r/m, r
OPCODES_0F[0xB3] = function(cpu) btReg(cpu, 2) end         -- BTR r/m, r
OPCODES_0F[0xBB] = function(cpu) btReg(cpu, 3) end         -- BTC r/m, r

local function shld(cpu, mod, reg, rm, bits, cnt)         -- SHLD
	cnt = bit32.band(cnt, 31)
	if cnt == 0 then return end
	local dst = readRM(cpu, mod, rm, bits)
	local src = readR(cpu, reg, bits)
	local mask = bit32.lshift(1, bits) - 1
	local cf = bit32.extract(dst, bits - cnt, 1)
	local result = bit32.band(bit32.bor(bit32.lshift(dst, cnt), bit32.rshift(src, bits - cnt)), mask)
	writeRM(cpu, mod, rm, result, bits)
	setFlagsLogic(cpu, result, bits)
	cpu.EFLAGS = bit32.replace(cpu.EFLAGS, cf, 0, 1)
	if cnt == 1 then cpu.EFLAGS = bit32.replace(cpu.EFLAGS, bit32.bxor(cf, bit32.extract(result, bits - 1, 1)), 11, 1) end
end

local function shrd(cpu, mod, reg, rm, bits, cnt)         -- SHRD
	cnt = bit32.band(cnt, 31)
	if cnt == 0 then return end
	local dst = readRM(cpu, mod, rm, bits)
	local src = readR(cpu, reg, bits)
	local mask = bit32.lshift(1, bits) - 1
	local cf = bit32.extract(dst, cnt - 1, 1)
	local result = bit32.band(bit32.bor(bit32.rshift(dst, cnt), bit32.lshift(src, bits - cnt)), mask)
	writeRM(cpu, mod, rm, result, bits)
	setFlagsLogic(cpu, result, bits)
	cpu.EFLAGS = bit32.replace(cpu.EFLAGS, cf, 0, 1)
	if cnt == 1 then cpu.EFLAGS = bit32.replace(cpu.EFLAGS, bit32.bxor(bit32.extract(dst, bits - 1, 1), bit32.extract(result, bits - 1, 1)), 11, 1) end
end

OPCODES_0F[0xA4] = function(cpu)                           -- SHLD r/m, r, imm8
	local bits = OS(cpu); local mod, reg, rm = ModRM(cpu)
	local cnt = buffer.readu8(cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP)); cpu.EIP += 1
	shld(cpu, mod, reg, rm, bits, cnt)
end

OPCODES_0F[0xA5] = function(cpu)                           -- SHLD r/m, r, CL
	local bits = OS(cpu); local mod, reg, rm = ModRM(cpu)
	shld(cpu, mod, reg, rm, bits, bit32.extract(cpu.ECX, 0, 8))
end

OPCODES_0F[0xA8] = function(cpu)                           -- PUSH GS
	cpu.ESP -= 2
	buffer.writeu16(cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), cpu.GS)
end

OPCODES_0F[0xA9] = function(cpu)                           -- POP GS
	local val = buffer.readu16(cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP))
	cpu.ESP += 2
	cpu.GS = val; cpu.GSBase = val * 16
end

OPCODES_0F[0xAC] = function(cpu)                           -- SHRD r/m, r, imm8
	local bits = OS(cpu); local mod, reg, rm = ModRM(cpu)
	local cnt = buffer.readu8(cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP)); cpu.EIP += 1
	shrd(cpu, mod, reg, rm, bits, cnt)
end

OPCODES_0F[0xAD] = function(cpu)                           -- SHRD r/m, r, CL
	local bits = OS(cpu); local mod, reg, rm = ModRM(cpu)
	shrd(cpu, mod, reg, rm, bits, bit32.extract(cpu.ECX, 0, 8))
end

OPCODES_0F[0xAF] = function(cpu)                           -- IMUL r, r/m
	local bits = OS(cpu)
	local mod, reg, rm = ModRM(cpu)
	local a = signExtend(readR(cpu, reg, bits), bits)
	local b = signExtend(readRM(cpu, mod, rm, bits), bits)
	local result = a * b
	writeR(cpu, reg, result, bits)
	setFlagsIMUL(cpu, result, bits)
end

local function cmpxchg(cpu, bits)                        -- CMPXCHG
	local mod, reg, rm = ModRM(cpu)
	local dst = readRM(cpu, mod, rm, bits)
	local acc = readR(cpu, 0, bits)
	setFlagsSub(cpu, acc, dst, acc - dst, bits)
	if dst == acc then
		writeRM(cpu, mod, rm, readR(cpu, reg, bits), bits)
	else
		writeR(cpu, 0, dst, bits)
	end
end

OPCODES_0F[0xB0] = function(cpu) cmpxchg(cpu, 8)       end -- CMPXCHG r/m8, r8
OPCODES_0F[0xB1] = function(cpu) cmpxchg(cpu, OS(cpu)) end -- CMPXCHG r/m, r

OPCODES_0F[0xB2] = function(cpu) loadFarPtr(cpu, "SS") end  -- LSS r, m
OPCODES_0F[0xB4] = function(cpu) loadFarPtr(cpu, "FS") end  -- LFS r, m
OPCODES_0F[0xB5] = function(cpu) loadFarPtr(cpu, "GS") end  -- LGS r, m

OPCODES_0F[0xB6] = function(cpu)                           -- MOVZX r, r/m8
	local bits = OS(cpu)
	local mod, reg, rm = ModRM(cpu)
	writeR(cpu, reg, readRM(cpu, mod, rm, 8), bits)
end

OPCODES_0F[0xB7] = function(cpu)                           -- MOVZX r, r/m16
	local mod, reg, rm = ModRM(cpu)
	writeR(cpu, reg, readRM(cpu, mod, rm, 16), 32)
end

local GRP8 = { [4]=0, [5]=1, [6]=2, [7]=3 }

OPCODES_0F[0xBA] = function(cpu)                           -- GRP8 r/m, imm8
	local bits = OS(cpu)
	local mod, reg, rm = ModRM(cpu)
	local idx = buffer.readu8(cpu.RAM, phys(cpu, cpu.CSBase + cpu.EIP)) % bits
	cpu.EIP += 1
	local op = GRP8[reg]
	if op then btApply(cpu, mod, rm, mod ~= 3 and LA16(cpu, mod, rm) or nil, bits, idx, op) end
end

OPCODES_0F[0xBC] = function(cpu)                           -- BSF r, r/m
	local bits = OS(cpu)
	local mod, reg, rm = ModRM(cpu)
	local val = readRM(cpu, mod, rm, bits)
	if val == 0 then cpu.EFLAGS = bit32.replace(cpu.EFLAGS, 1, 6, 1); return end
	cpu.EFLAGS = bit32.replace(cpu.EFLAGS, 0, 6, 1)
	local i = 0; while bit32.extract(val, i, 1) == 0 do i += 1 end
	writeR(cpu, reg, i, bits)
end

OPCODES_0F[0xBD] = function(cpu)                           -- BSR r, r/m
	local bits = OS(cpu)
	local mod, reg, rm = ModRM(cpu)
	local val = readRM(cpu, mod, rm, bits)
	if val == 0 then cpu.EFLAGS = bit32.replace(cpu.EFLAGS, 1, 6, 1); return end
	cpu.EFLAGS = bit32.replace(cpu.EFLAGS, 0, 6, 1)
	local i = bits - 1; while bit32.extract(val, i, 1) == 0 do i -= 1 end
	writeR(cpu, reg, i, bits)
end

OPCODES_0F[0xBE] = function(cpu)                           -- MOVSX r, r/m8
	local bits = OS(cpu)
	local mod, reg, rm = ModRM(cpu)
	writeR(cpu, reg, bit32.band(signExtend(readRM(cpu, mod, rm, 8), 8), bit32.lshift(1, bits) - 1), bits)
end

OPCODES_0F[0xBF] = function(cpu)                           -- MOVSX r, r/m16
	local mod, reg, rm = ModRM(cpu)
	writeR(cpu, reg, bit32.band(signExtend(readRM(cpu, mod, rm, 16), 16), 0xFFFFFFFF), 32)
end

local function xadd(cpu, bits)                           -- XADD
	local mod, reg, rm = ModRM(cpu)
	local dst = readRM(cpu, mod, rm, bits)
	local src = readR(cpu, reg, bits)
	local result = dst + src
	writeRM(cpu, mod, rm, result, bits)
	writeR(cpu, reg, dst, bits)
	setFlagsAdd(cpu, dst, src, result, bits)
end

OPCODES_0F[0xC0] = function(cpu) xadd(cpu, 8)       end    -- XADD r/m8, r8
OPCODES_0F[0xC1] = function(cpu) xadd(cpu, OS(cpu)) end    -- XADD r/m, r

local function bswap(x)
	return bit32.bor(
		bit32.lshift(bit32.band(x, 0xFF), 24),
		bit32.lshift(bit32.band(x, 0xFF00), 8),
		bit32.rshift(bit32.band(x, 0xFF0000), 8),
		bit32.rshift(x, 24)
	)
end

local function bswapR(cpu, r) REG_BSWAP[r](cpu, bswap(REG_READ32[r](cpu))) end

OPCODES_0F[0xC8] = function(cpu) bswapR(cpu, 0) end        -- BSWAP EAX
OPCODES_0F[0xC9] = function(cpu) bswapR(cpu, 1) end        -- BSWAP ECX
OPCODES_0F[0xCA] = function(cpu) bswapR(cpu, 2) end        -- BSWAP EDX
OPCODES_0F[0xCB] = function(cpu) bswapR(cpu, 3) end        -- BSWAP EBX
OPCODES_0F[0xCC] = function(cpu) bswapR(cpu, 4) end        -- BSWAP ESP
OPCODES_0F[0xCD] = function(cpu) bswapR(cpu, 5) end        -- BSWAP EBP
OPCODES_0F[0xCE] = function(cpu) bswapR(cpu, 6) end        -- BSWAP ESI
OPCODES_0F[0xCF] = function(cpu) bswapR(cpu, 7) end        -- BSWAP EDI

-- INT: interrupt/exception dispatch (real mode + protected mode)
-- Must be defined here to close over loadSeg, BUF_WRITE, phys, buffer
local function INT(cpu, n)
	if cpu._exception_depth >= 2 then return end
	cpu._exception_depth += 1
	if bit32.band(cpu.CR0, 1) == 0 then
		-- Real mode: read IVT vector at n*4, push FLAGS/CS/IP (16-bit), clear TF+IF
		local newIP = buffer.readu16(cpu.RAM, phys(cpu, n * 4))
		local newCS = buffer.readu16(cpu.RAM, phys(cpu, n * 4 + 2))
		cpu.ESP -= 2; buffer.writeu16(cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), bit32.band(cpu.EFLAGS, 0xFFFF))
		cpu.ESP -= 2; buffer.writeu16(cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), cpu.CS)
		cpu.ESP -= 2; buffer.writeu16(cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), bit32.band(cpu.EIP, 0xFFFF))
		cpu.EFLAGS = bit32.band(cpu.EFLAGS, 0xFFFFFCFF)   -- clear TF (bit8) and IF (bit9)
		cpu.CS     = newCS
		cpu.CSBase = newCS * 16
		cpu.EIP    = newIP
	else
		-- Protected mode: read IDT gate descriptor at IDTRBase + n*8
		local gateAddr  = phys(cpu, cpu.IDTRBase + n * 8)
		local lo        = buffer.readu32(cpu.RAM, gateAddr)
		local hi        = buffer.readu32(cpu.RAM, phys(cpu, gateAddr + 4))
		if bit32.extract(hi, 15, 1) == 0 then cpu._exception_depth -= 1; return end  -- not present
		local gateType  = bit32.extract(hi, 8, 4)          -- type field bits [11:8]
		local is32      = bit32.extract(gateType, 3, 1)    -- D bit: 1=32-bit gate, 0=16-bit
		local bits      = is32 == 1 and 32 or 16
		local offset    = bit32.bor(bit32.band(lo, 0xFFFF), bit32.lshift(bit32.rshift(hi, 16), 16))
		local selector  = bit32.extract(lo, 16, 16)
		-- Push EFLAGS, CS (always 16-bit), EIP/IP
		cpu.ESP -= bits; BUF_WRITE[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), bit32.band(cpu.EFLAGS, bit32.lshift(1, bits) - 1))
		cpu.ESP -= bits; BUF_WRITE[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), bit32.band(cpu.CS,     bit32.lshift(1, bits) - 1))
		cpu.ESP -= bits; BUF_WRITE[bits](cpu.RAM, phys(cpu, cpu.SSBase + cpu.ESP), bit32.band(cpu.EIP,    bit32.lshift(1, bits) - 1))
		cpu.EFLAGS = bit32.band(cpu.EFLAGS, 0xFFFFFEFF)   -- clear TF (bit8)
		if gateType == 0xE or gateType == 0x6 then          -- interrupt gate or trap-16: also clear IF
			cpu.EFLAGS = bit32.band(cpu.EFLAGS, 0xFFFFFDFF)
		end
		cpu.CS     = selector
		cpu.CSBase = selector * 16
		cpu.EIP    = offset
	end
	cpu._exception_depth -= 1
end


OPCODES._INT = INT
return OPCODES