--!strict

local Types = require("./Types")
type CPU = Types.CPU

local REG8_OFFSET = {[0]=0, 2, 4, 6, 1, 3, 5, 7}
local REG16_OFFSET = {[0]=0, 2, 4, 6, 8, 10, 12, 14}
local SREG = {"ES", "CS", "SS", "DS"}

local function RR(cpu: CPU, reg, w): number
    if w == 0 then
        return buffer.readu8(cpu.Registers, REG8_OFFSET[reg])
    else
        return buffer.readu16(cpu.Registers, REG16_OFFSET[reg])
    end
end

local function WR(cpu: CPU, reg, w, v)
    if w == 0 then
        buffer.writeu8(cpu.Registers, REG8_OFFSET[reg], v)
    else
        buffer.writeu16(cpu.Registers, REG16_OFFSET[reg], v)
    end
end

local function RM(cpu: CPU, addr, w)
    if w == 0 then
        return buffer.readu8(cpu.RAM, addr)
    else 
        return buffer.readu16(cpu.RAM, addr)
    end
end

local function WM(cpu: CPU, addr, w, v)
    if w == 0 then
        return buffer.writeu8(cpu.RAM, addr, v)
    else 
        return buffer.writeu16(cpu.RAM, addr, v)
    end
end

local function physAddr(seg: number, addr: number)
    return bit32.band(seg * 16 + addr, 0xFFFFF)
end

local function imm(cpu: CPU, w)
    local imm = RM(cpu, physAddr(cpu.CS, cpu.IP), w)
    cpu.IP = bit32.band(cpu.IP + (w == 0 and 1 or 2), 0xFFFF)
    return imm
end

local function ModRM(cpu: CPU)
    local modrm = imm(cpu, 0)
    local mod = bit32.extract(modrm, 6, 2)
    local reg = bit32.extract(modrm, 3, 3)
    local rm = bit32.extract(modrm, 0, 3)
    return mod, reg, rm
end

local RM_EA = {
    [0] = function(cpu) return RR(cpu, 3, 1) + RR(cpu, 6, 1) end, -- BX + SI
    [1] = function(cpu) return RR(cpu, 3, 1) + RR(cpu, 7, 1) end, -- BX + DI
    [2] = function(cpu) return RR(cpu, 5, 1) + RR(cpu, 6, 1) end, -- BP + SI
    [3] = function(cpu) return RR(cpu, 5, 1) + RR(cpu, 7, 1) end, -- BP + DI
    [4] = function(cpu) return RR(cpu, 6, 1) end,                 -- SI
    [5] = function(cpu) return RR(cpu, 7, 1) end,                 -- DI
    [6] = function(cpu) return RR(cpu, 5, 1) end,                 -- BP
    [7] = function(cpu) return RR(cpu, 3, 1) end                  -- BX
}

local RM_SS = { [2]=true, [3]=true, [6]=true }

local function M(cpu: CPU, mod, rm)
    local base
    local seg
    if mod == 0 and rm == 6 then
        base = imm(cpu, 1)
        seg = cpu.DS
    else
        base = RM_EA[rm](cpu)
        if mod == 1 then
            base += buffer.readi8(cpu.RAM, physAddr(cpu.CS, cpu.IP))
            cpu.IP = bit32.band(cpu.IP + 1, 0xFFFF)
        elseif mod == 2 then
            base += buffer.readi16(cpu.RAM, physAddr(cpu.CS, cpu.IP))
            cpu.IP = bit32.band(cpu.IP + 2, 0xFFFF)
        end
        seg = RM_SS[rm] and cpu.SS or cpu.DS
    end

    seg = cpu.SegmentOverride or seg

    return physAddr(seg, bit32.band(base, 0xFFFF))
end

local FLAGS = {
    CF = 0, 
    PF = 2,
    AF = 4,
    ZF = 6,
    SF = 7,
    TF = 8,
    IF = 9,
    DF = 10,
    OF = 11,
}

local function readFlag(cpu: CPU, flag)
    return bit32.extract(cpu.FLAGS, flag) == 1
end

local function setFlag(cpu: CPU, flag, v)
    cpu.FLAGS = bit32.replace(cpu.FLAGS, v and 1 or 0, flag)
end

local function popcount(n)
	local count = 0

	while n > 0 do
		n = bit32.band(n, n - 1)
		count += 1
	end

	return count
end

local PARITY = table.create(256, false)
for i = 0, 255 do
    PARITY[i] = bit32.band(popcount(i), 1) == 0
end

local function mov(cpu: CPU, d, w)
    local mod, reg, rm = ModRM(cpu)
    if mod == 3 then
        WR(cpu, d == 1 and reg or rm, w, RR(cpu, d == 1 and rm or reg, w))
    else
        local addr = M(cpu, mod, rm)
        if d == 1 then
            WR(cpu, reg, w, RM(cpu, addr, w))
        else
            WM(cpu, addr, w, RR(cpu, reg, w))
        end
    end
end

local function flagsAdd(cpu: CPU, a: number, b: number, w: number, carry: number?): number
    local c = carry or 0
    local raw = a + b + c
    local mask = w == 0 and 0xFF or 0xFFFF
    local result = bit32.band(raw, mask)

    setFlag(cpu, FLAGS.CF, raw > mask)
    setFlag(cpu, FLAGS.ZF, result == 0)
    setFlag(cpu, FLAGS.SF, bit32.extract(result, w == 0 and 7 or 15) == 1)
    setFlag(cpu, FLAGS.PF, PARITY[bit32.band(result, 0xFF)])
    setFlag(cpu, FLAGS.AF, bit32.band(bit32.bxor(a, b, result), 0x10) ~= 0)

    local signBit = w == 0 and 0b10000000 or 0b1000000000000000
    local overflow = bit32.band(bit32.bnot(bit32.bxor(a, b)), bit32.bxor(a, result))
    setFlag(cpu, FLAGS.OF, bit32.band(overflow, signBit) ~= 0)

    return result
end

local function add(cpu: CPU, d, w, carry: boolean?)
    local cv: number = carry and (readFlag(cpu, FLAGS.CF) and 1 or 0) or 0
    local mod, reg, rm = ModRM(cpu)
    local regVal = RR(cpu, reg, w)
    if mod == 3 then
        local rmVal = RR(cpu, rm, w)
        WR(cpu, d == 1 and reg or rm, w, flagsAdd(cpu, rmVal, regVal, w, cv))
    else
        local addr = M(cpu, mod, rm)
        local rmVal = RM(cpu, addr, w)
        local result = flagsAdd(cpu, rmVal, regVal, w, cv)
        if d == 1 then
            WR(cpu, reg, w, result)
        else
            WM(cpu, addr, w, result)
        end
    end
end

local function flagsSub(cpu: CPU, a: number, b: number, w: number, borrow: number?): number
    local bor = borrow or 0
    local raw = a - b - bor
    local mask = w == 0 and 0xFF or 0xFFFF
    local result = bit32.band(raw, mask)

    setFlag(cpu, FLAGS.CF, raw < 0)
    setFlag(cpu, FLAGS.ZF, result == 0)
    setFlag(cpu, FLAGS.SF, bit32.extract(result, w == 0 and 7 or 15) == 1)
    setFlag(cpu, FLAGS.PF, PARITY[bit32.band(result, 0xFF)])
    setFlag(cpu, FLAGS.AF, bit32.band(bit32.bxor(a, b, result), 0x10) ~= 0)

    local signBit = w == 0 and 0x80 or 0x8000
    local overflow = bit32.band(bit32.bxor(a, b), bit32.bxor(a, result))
    setFlag(cpu, FLAGS.OF, bit32.band(overflow, signBit) ~= 0)

    return result
end

local function sub(cpu: CPU, d, w, borrow: boolean?)
    local bv: number = borrow and (readFlag(cpu, FLAGS.CF) and 1 or 0) or 0
    local mod, reg, rm = ModRM(cpu)
    local regVal = RR(cpu, reg, w)
    if mod == 3 then
        local rmVal = RR(cpu, rm, w)
        local result = if d == 0
            then flagsSub(cpu, rmVal, regVal, w, bv)
            else flagsSub(cpu, regVal, rmVal, w, bv)
        WR(cpu, d == 1 and reg or rm, w, result)
    else
        local addr = M(cpu, mod, rm)
        local rmVal = RM(cpu, addr, w)
        local result = if d == 0
            then flagsSub(cpu, rmVal, regVal, w, bv)
            else flagsSub(cpu, regVal, rmVal, w, bv)
        if d == 1 then
            WR(cpu, reg, w, result)
        else
            WM(cpu, addr, w, result)
        end
    end
end

local function cmp(cpu: CPU, d, w)
    local mod, reg, rm = ModRM(cpu)
    local regVal = RR(cpu, reg, w)
    local rmVal = if mod == 3
        then RR(cpu, rm, w)
        else RM(cpu, M(cpu, mod, rm), w)
    if d == 0 then
        flagsSub(cpu, rmVal, regVal, w)
    else
        flagsSub(cpu, regVal, rmVal, w)
    end
end

local function flagsIncDec(cpu: CPU, result, w)
    local mask = w == 0 and 0xFF or 0xFFFF
    result = bit32.band(result, mask)

    setFlag(cpu, FLAGS.ZF, result == 0)
    setFlag(cpu, FLAGS.SF, bit32.extract(result, w == 0 and 7 or 15) == 1)
    setFlag(cpu, FLAGS.PF, PARITY[bit32.band(result, 0xFF)])
    setFlag(cpu, FLAGS.AF, bit32.band(result, 0x0F) == 0)

    return result
end

local function incDec(cpu: CPU, reg, sign: number)
    local v = RR(cpu, reg, 1)
    setFlag(cpu, FLAGS.OF, sign == 1 and v == 0x7FFF or v == 0x8000)
    local result = flagsIncDec(cpu, v + sign, 1)
    setFlag(cpu, FLAGS.AF, if sign == 1
        then bit32.band(v, 0x0F) == 0x0F
        else bit32.band(v, 0x0F) == 0x00)
    WR(cpu, reg, 1, result)
end

local function push(cpu: CPU, v)
    WR(cpu, 8, 1, bit32.band(RR(cpu, 8, 1) - 2, 0xFFFF))
    WM(cpu, physAddr(cpu.SS, RR(cpu, 8, 1)), 1, v)
end

local function pop(cpu: CPU)
    local v = RM(cpu, physAddr(cpu.SS, RR(cpu, 8, 1)), 1)
    WR(cpu, 8, 1, bit32.band(RR(cpu, 8, 1) + 2, 0xFFFF))
    return v
end

local function flagsLogic(cpu: CPU, result: number, w: number): number
    local mask = w == 0 and 0xFF or 0xFFFF
    result = bit32.band(result, mask)

    setFlag(cpu, FLAGS.CF, false)
    setFlag(cpu, FLAGS.OF, false)
    setFlag(cpu, FLAGS.AF, false)
    setFlag(cpu, FLAGS.ZF, result == 0)

    setFlag(cpu, FLAGS.SF, bit32.extract(result, w == 0 and 7 or 15) == 1)
    setFlag(cpu, FLAGS.PF, PARITY[bit32.band(result, 0xFF)])

    return result
end

local function logic(cpu: CPU, d, w, op)
    local mod, reg, rm = ModRM(cpu)
    local regVal = RR(cpu, reg, w)
    if mod == 3 then
        local rmVal = RR(cpu, rm, w)
        WR(cpu, d == 1 and reg or rm, w, flagsLogic(cpu, op(regVal, rmVal), w))
    else
        local addr = M(cpu, mod, rm)
        local rmVal = RM(cpu, addr, w)
        local result = flagsLogic(cpu, op(regVal, rmVal), w)
        if d == 1 then
            WR(cpu, reg, w, result)
        else
            WM(cpu, addr, w, result)
        end
    end
end

local function test(cpu: CPU, w)
    local mod, reg, rm = ModRM(cpu)
    local regVal = RR(cpu, reg, w)
    local rmVal = if mod == 3
        then RR(cpu, rm, w)
        else RM(cpu, M(cpu, mod, rm), w)
    flagsLogic(cpu, bit32.band(regVal, rmVal), w)
end

local function xchg(cpu: CPU, w)
    local mod, reg, rm = ModRM(cpu)
    local regVal = RR(cpu, reg, w)
    if mod == 3 then
        local rmVal = RR(cpu, rm, w)
        WR(cpu, reg, w, rmVal)
        WR(cpu, rm, w, regVal)
    else
        local addr = M(cpu, mod, rm)
        local rmVal = RM(cpu, addr, w)
        WM(cpu, addr, w, regVal)
        WR(cpu, reg, w, rmVal)
    end
end

local function xchgAX(cpu: CPU, reg)
    local ax = RR(cpu, 0, 1)
    WR(cpu, 0, 1, RR(cpu, reg, 1))
    WR(cpu, reg, 1, ax)
end

local function jcc(cpu: CPU, cond)
    local offset = buffer.readi8(cpu.RAM, physAddr(cpu.CS, cpu.IP))
    cpu.IP = bit32.band(cpu.IP + 1, 0xFFFF)
    if cond then
        cpu.IP = bit32.band(cpu.IP + offset, 0xFFFF)
    end
end

local function SFNeOF(cpu: CPU)
    return readFlag(cpu, FLAGS.SF) ~= readFlag(cpu, FLAGS.OF)
end

local function DA(cpu: CPU, sign: number)
    local al = RR(cpu, 0, 0)
    local oldAL = al
    local oldCF = readFlag(cpu, FLAGS.CF)

    if bit32.band(al, 0x0F) > 9 or readFlag(cpu, FLAGS.AF) then
        al = bit32.band(al + sign * 6, 0xFF)
        setFlag(cpu, FLAGS.AF, true)
    else
        setFlag(cpu, FLAGS.AF, false)
    end

    if oldAL > 0x99 or oldCF then
        al = bit32.band(al + sign * 0x60, 0xFF)
        setFlag(cpu, FLAGS.CF, true)
    else
        setFlag(cpu, FLAGS.CF, false)
    end

    setFlag(cpu, FLAGS.SF, bit32.extract(al, 7) == 1)
    setFlag(cpu, FLAGS.ZF, al == 0)
    setFlag(cpu, FLAGS.PF, PARITY[al])
    WR(cpu, 0, 0, al)
end

local function AA(cpu: CPU, sign: number)
    local al = RR(cpu, 0, 0)
    local ah = RR(cpu, 4, 0)

    if bit32.band(al, 0x0F) > 9 or readFlag(cpu, FLAGS.AF) then
        al = bit32.band(al + sign * 6, 0xFF)
        ah = bit32.band(ah + sign, 0xFF)
        setFlag(cpu, FLAGS.AF, true)
        setFlag(cpu, FLAGS.CF, true)
    else
        setFlag(cpu, FLAGS.AF, false)
        setFlag(cpu, FLAGS.CF, false)
    end

    WR(cpu, 0, 0, bit32.band(al, 0x0F))
    WR(cpu, 4, 0, ah)
end

local function strStep(cpu: CPU, w)
    local step = (w == 0 and 1 or 2) * (readFlag(cpu, FLAGS.DF) and -1 or 1)
    cpu.SI = bit32.band(cpu.SI + step, 0xFFFF)
    cpu.DI = bit32.band(cpu.DI + step, 0xFFFF)
end

local function repLoop(cpu: CPU, body, checkZF)
    local rep, repne = cpu.REP, cpu.REPNE
    local cx = (rep or repne) and buffer.readu16(cpu.Registers, 2) or 1
    while cx > 0 do
        body(cpu)
        cx = bit32.band(cx - 1, 0xFFFF)
        if checkZF then
            local zf = bit32.extract(cpu.FLAGS, 6) == 1
            if cpu.REPNE and zf then break end
            if cpu.REP and not zf then break end
        end
    end
    if rep or repne then buffer.writeu16(cpu.Registers, 2, cx) end
    return cx
end

local GROUP1 = {
    [0] = function(cpu, a, b, w) return flagsAdd(cpu, a, b, w) end,
    [1] = function(cpu, a, b, w) return flagsLogic(cpu, bit32.bor(a, b), w) end,
    [2] = function(cpu, a, b, w) return flagsAdd(cpu, a, b, w, readFlag(cpu, FLAGS.CF) and 1 or 0) end,
    [3] = function(cpu, a, b, w) return flagsSub(cpu, a, b, w, readFlag(cpu, FLAGS.CF) and 1 or 0) end,
    [4] = function(cpu, a, b, w) return flagsLogic(cpu, bit32.band(a, b), w) end,
    [5] = function(cpu, a, b, w) return flagsSub(cpu, a, b, w) end,
    [6] = function(cpu, a, b, w) return flagsLogic(cpu, bit32.bxor(a, b), w) end,
    [7] = function(cpu, a, b, w) return flagsSub(cpu, a, b, w) end,
}

local function group1(cpu: CPU, w, immW)
    local mod, reg, rm = ModRM(cpu)
    local b = if immW == 0 and w == 1
        then bit32.band(buffer.readi8(cpu.RAM, physAddr(cpu.CS, cpu.IP)), 0xFFFF)
        else imm(cpu, immW)
    if immW == 0 and w == 1 then
        cpu.IP = bit32.band(cpu.IP + 1, 0xFFFF)
    end
    local op = GROUP1[reg]
    if mod == 3 then
        local a = RR(cpu, rm, w)
        local result = op(cpu, a, b, w)
        if reg ~= 7 then WR(cpu, rm, w, result) end
    else
        local addr = M(cpu, mod, rm)
        local a = RM(cpu, addr, w)
        local result = op(cpu, a, b, w)
        if reg ~= 7 then WM(cpu, addr, w, result) end
    end
end

local GROUP2: {(cpu: CPU, v: number, count: number, bits: number, mask: number) -> number} = {
    [0] = function(cpu, v, count, bits, mask) -- ROL
        count = count % bits
        if count == 0 then return v end
        local result = bit32.band(bit32.bor(bit32.lshift(v, count), bit32.rshift(v, bits - count)), mask)
        setFlag(cpu, FLAGS.CF, bit32.band(result, 1) == 1)
        if count == 1 then
            setFlag(cpu, FLAGS.OF, (bit32.band(result, 1) == 1) ~= (bit32.extract(result, bits - 1) == 1))
        end
        return result
    end,
    [1] = function(cpu, v, count, bits, mask) -- ROR
        count = count % bits
        if count == 0 then return v end
        local result = bit32.band(bit32.bor(bit32.rshift(v, count), bit32.lshift(v, bits - count)), mask)
        local msb = bit32.extract(result, bits - 1) == 1
        setFlag(cpu, FLAGS.CF, msb)
        if count == 1 then
            setFlag(cpu, FLAGS.OF, msb ~= (bit32.extract(result, bits - 2) == 1))
        end
        return result
    end,
    [2] = function(cpu, v, count, bits, mask) -- RCL
        for _ = 1, count do
            local new_cf = bit32.extract(v, bits - 1) == 1
            v = bit32.band(bit32.bor(bit32.lshift(v, 1), readFlag(cpu, FLAGS.CF) and 1 or 0), mask)
            setFlag(cpu, FLAGS.CF, new_cf)
        end
        if count == 1 then
            setFlag(cpu, FLAGS.OF, readFlag(cpu, FLAGS.CF) ~= (bit32.extract(v, bits - 1) == 1))
        end
        return v
    end,
    [3] = function(cpu, v, count, bits, mask) -- RCR
        if count == 1 then
            setFlag(cpu, FLAGS.OF, readFlag(cpu, FLAGS.CF) ~= (bit32.extract(v, bits - 1) == 1))
        end
        for _ = 1, count do
            local new_cf = bit32.band(v, 1) == 1
            v = bit32.band(bit32.bor(bit32.rshift(v, 1), readFlag(cpu, FLAGS.CF) and bit32.lshift(1, bits - 1) or 0), mask)
            setFlag(cpu, FLAGS.CF, new_cf)
        end
        return v
    end,
    [4] = function(cpu, v, count, bits, mask) -- SHL
        if count == 0 then return v end
        local cf = count <= bits and bit32.extract(v, bits - count) == 1 or false
        local result = count < bits and bit32.band(bit32.lshift(v, count), mask) or 0
        setFlag(cpu, FLAGS.CF, cf)
        setFlag(cpu, FLAGS.ZF, result == 0)
        setFlag(cpu, FLAGS.SF, bit32.extract(result, bits - 1) == 1)
        setFlag(cpu, FLAGS.PF, PARITY[bit32.band(result, 0xFF)])
        if count == 1 then
            setFlag(cpu, FLAGS.OF, cf ~= (bit32.extract(result, bits - 1) == 1))
        end
        return result
    end,
    [5] = function(cpu, v, count, bits, mask) -- SHR
        if count == 0 then return v end
        if count == 1 then
            setFlag(cpu, FLAGS.OF, bit32.extract(v, bits - 1) == 1)
        end
        local cf = count <= bits and bit32.extract(v, count - 1) == 1 or false
        local result = count < bits and bit32.rshift(v, count) or 0
        setFlag(cpu, FLAGS.CF, cf)
        setFlag(cpu, FLAGS.ZF, result == 0)
        setFlag(cpu, FLAGS.SF, bit32.extract(result, bits - 1) == 1)
        setFlag(cpu, FLAGS.PF, PARITY[bit32.band(result, 0xFF)])
        return result
    end,
    [7] = function(cpu, v, count, bits, mask) -- SAR
        if count == 0 then return v end
        local msb = bit32.extract(v, bits - 1)
        local cf = count <= bits and bit32.extract(v, count - 1) == 1 or msb == 1
        local shift = 32 - bits
    local result = bit32.band(bit32.arshift(bit32.lshift(v, shift), shift + count), mask)
        setFlag(cpu, FLAGS.CF, cf)
        setFlag(cpu, FLAGS.ZF, result == 0)
        setFlag(cpu, FLAGS.SF, bit32.extract(result, bits - 1) == 1)
        setFlag(cpu, FLAGS.PF, PARITY[bit32.band(result, 0xFF)])
        if count == 1 then setFlag(cpu, FLAGS.OF, false) end
        return result
    end,
}

local function group2(cpu: CPU, w, usesCL)
    local mod, reg, rm = ModRM(cpu)
    local count = usesCL and bit32.band(RR(cpu, 1, 0), 0x1F) or 1
    local bits = w == 0 and 8 or 16
    local mask = w == 0 and 0xFF or 0xFFFF
    local op = GROUP2[reg]
    if mod == 3 then
        WR(cpu, rm, w, op(cpu, RR(cpu, rm, w), count, bits, mask))
    else
        local addr = M(cpu, mod, rm)
        WM(cpu, addr, w, op(cpu, RM(cpu, addr, w), count, bits, mask))
    end
end

local function interrupt(cpu: CPU, n: number)
    push(cpu, cpu.FLAGS)
    push(cpu, cpu.CS)
    push(cpu, cpu.IP)
    setFlag(cpu, FLAGS.IF, false)
    setFlag(cpu, FLAGS.TF, false)
    local vec = physAddr(0, n * 4)
    cpu.IP = RM(cpu, vec, 1)
    cpu.CS = RM(cpu, vec + 2, 1)
end

local OPCODES = {}
setmetatable(OPCODES, {
    __index = function(_, op)
        return function(cpu) end
    end
})

OPCODES[0x00] = function(cpu) add(cpu, 0, 0) end -- ADD r/m8 r8
OPCODES[0x01] = function(cpu) add(cpu, 0, 1) end -- ADD r/m16 r16
OPCODES[0x02] = function(cpu) add(cpu, 1, 0) end -- ADD r8 r/m8
OPCODES[0x03] = function(cpu) add(cpu, 1, 1) end -- ADD r16 r/m16
OPCODES[0x04] = function(cpu) WR(cpu, 0, 0, flagsAdd(cpu, RR(cpu, 0, 0), imm(cpu, 0), 0)) end -- ADD AL imm8
OPCODES[0x05] = function(cpu) WR(cpu, 0, 1, flagsAdd(cpu, RR(cpu, 0, 1), imm(cpu, 1), 1)) end -- ADD AX imm16

OPCODES[0x06] = function(cpu) push(cpu, cpu.ES) end -- PUSH ES
OPCODES[0x07] = function(cpu) cpu.ES = pop(cpu) end -- POP ES
OPCODES[0x08] = function(cpu) logic(cpu, 0, 0, bit32.bor) end -- OR r/m8 r8
OPCODES[0x09] = function(cpu) logic(cpu, 0, 1, bit32.bor) end -- OR r/m16 r16
OPCODES[0x0A] = function(cpu) logic(cpu, 1, 0, bit32.bor) end -- OR r8 r/m8
OPCODES[0x0B] = function(cpu) logic(cpu, 1, 1, bit32.bor) end -- OR r16 r/m16
OPCODES[0x0C] = function(cpu) WR(cpu, 0, 0, flagsLogic(cpu, bit32.bor(RR(cpu, 0, 0), imm(cpu, 0)), 0)) end -- OR AL imm8
OPCODES[0x0D] = function(cpu) WR(cpu, 0, 1, flagsLogic(cpu, bit32.bor(RR(cpu, 0, 1), imm(cpu, 1)), 1)) end -- OR AX imm16

OPCODES[0x0E] = function(cpu) push(cpu, cpu.CS) end -- PUSH CS

local OPCODES_0F = {}

OPCODES[0x0F] = function(cpu) -- Two-byte escape
    local opcode = imm(cpu, 0)
    OPCODES_0F[opcode](cpu)
end

OPCODES[0x10] = function(cpu) add(cpu, 0, 0, true) end -- ADC r/m8 r8
OPCODES[0x11] = function(cpu) add(cpu, 0, 1, true) end -- ADC r/m16 r16
OPCODES[0x12] = function(cpu) add(cpu, 1, 0, true) end -- ADC r8 r/m8
OPCODES[0x13] = function(cpu) add(cpu, 1, 1, true) end -- ADC r16 r/m16
OPCODES[0x14] = function(cpu) WR(cpu, 0, 0, flagsAdd(cpu, RR(cpu, 0, 0), imm(cpu, 0), 0, readFlag(cpu, FLAGS.CF) and 1 or 0)) end -- ADC AL imm8
OPCODES[0x15] = function(cpu) WR(cpu, 0, 1, flagsAdd(cpu, RR(cpu, 0, 1), imm(cpu, 1), 1, readFlag(cpu, FLAGS.CF) and 1 or 0)) end -- ADC AX imm16

OPCODES[0x16] = function(cpu) push(cpu, cpu.SS) end -- PUSH SS
OPCODES[0x17] = function(cpu) cpu.SS = pop(cpu) end -- POP SS

OPCODES[0x18] = function(cpu) sub(cpu, 0, 0, true) end -- SBB r/m8 r8
OPCODES[0x19] = function(cpu) sub(cpu, 0, 1, true) end -- SBB r/m16 r16
OPCODES[0x1A] = function(cpu) sub(cpu, 1, 0, true) end -- SBB r8 r/m8
OPCODES[0x1B] = function(cpu) sub(cpu, 1, 1, true) end -- SBB r16 r/m16
OPCODES[0x1C] = function(cpu) WR(cpu, 0, 0, flagsSub(cpu, RR(cpu, 0, 0), imm(cpu, 0), 0, readFlag(cpu, FLAGS.CF) and 1 or 0)) end -- SBB AL, imm8
OPCODES[0x1D] = function(cpu) WR(cpu, 0, 1, flagsSub(cpu, RR(cpu, 0, 1), imm(cpu, 1), 1, readFlag(cpu, FLAGS.CF) and 1 or 0)) end -- SBB AX, imm16

OPCODES[0x1E] = function(cpu) push(cpu, cpu.DS) end -- PUSH DS
OPCODES[0x1F] = function(cpu) cpu.DS = pop(cpu) end -- POP DS

OPCODES[0x20] = function(cpu) logic(cpu, 0, 0, bit32.band) end -- AND r/m8 r8
OPCODES[0x21] = function(cpu) logic(cpu, 0, 1, bit32.band) end -- AND r/m16 r16
OPCODES[0x22] = function(cpu) logic(cpu, 1, 0, bit32.band) end -- AND r8 r/m8
OPCODES[0x23] = function(cpu) logic(cpu, 1, 1, bit32.band) end -- AND r16 r/m16
OPCODES[0x24] = function(cpu) WR(cpu, 0, 0, flagsLogic(cpu, bit32.band(RR(cpu, 0, 0), imm(cpu, 0)), 0)) end -- AND AL imm8
OPCODES[0x25] = function(cpu) WR(cpu, 0, 1, flagsLogic(cpu, bit32.band(RR(cpu, 0, 1), imm(cpu, 1)), 1)) end -- AND AX imm16

-- 0x26: ES prefix

OPCODES[0x27] = function(cpu) DA(cpu, 1) end -- DAA

OPCODES[0x28] = function(cpu) sub(cpu, 0, 0) end -- SUB r/m8 r8
OPCODES[0x29] = function(cpu) sub(cpu, 0, 1) end -- SUB r/m16 r16
OPCODES[0x2A] = function(cpu) sub(cpu, 1, 0) end -- SUB r8 r/m8
OPCODES[0x2B] = function(cpu) sub(cpu, 1, 1) end -- SUB r16 r/m16
OPCODES[0x2C] = function(cpu) WR(cpu, 0, 0, flagsSub(cpu, RR(cpu, 0, 0), imm(cpu, 0), 0)) end -- SUB AL, imm8
OPCODES[0x2D] = function(cpu) WR(cpu, 0, 1, flagsSub(cpu, RR(cpu, 0, 1), imm(cpu, 1), 1)) end -- SUB AX, imm16

-- 0x2E: CS prefix

OPCODES[0x2F] = function(cpu) DA(cpu, -1) end -- DAS

OPCODES[0x30] = function(cpu) logic(cpu, 0, 0, bit32.bxor) end -- XOR r/m8 r8
OPCODES[0x31] = function(cpu) logic(cpu, 0, 1, bit32.bxor) end -- XOR r/m16 r16
OPCODES[0x32] = function(cpu) logic(cpu, 1, 0, bit32.bxor) end -- XOR r8 r/m8
OPCODES[0x33] = function(cpu) logic(cpu, 1, 1, bit32.bxor) end -- XOR r16 r/m16
OPCODES[0x34] = function(cpu) WR(cpu, 0, 0, flagsLogic(cpu, bit32.bxor(RR(cpu, 0, 0), imm(cpu, 0)), 0)) end -- XOR AL imm8
OPCODES[0x35] = function(cpu) WR(cpu, 0, 1, flagsLogic(cpu, bit32.bxor(RR(cpu, 0, 1), imm(cpu, 1)), 1)) end -- XOR AX imm16

-- 0x36: SS prefx

OPCODES[0x37] = function(cpu) AA(cpu, 1) end -- AAA

OPCODES[0x38] = function(cpu) cmp(cpu, 0, 0) end -- CMP r/m8 r8
OPCODES[0x39] = function(cpu) cmp(cpu, 0, 1) end -- CMP r/m16 r16
OPCODES[0x3A] = function(cpu) cmp(cpu, 1, 0) end -- CMP r8 r/m8
OPCODES[0x3B] = function(cpu) cmp(cpu, 1, 1) end -- CMP r16 r/m16
OPCODES[0x3C] = function(cpu) flagsSub(cpu, RR(cpu, 0, 0), imm(cpu, 0), 0) end -- CMP AL, imm8
OPCODES[0x3D] = function(cpu) flagsSub(cpu, RR(cpu, 0, 1), imm(cpu, 1), 1) end -- CMP AX, imm16

-- 0x3E: DS prefix

OPCODES[0x3F] = function(cpu) AA(cpu, -1) end -- AAS

OPCODES[0x40] = function(cpu) incDec(cpu, 0,  1) end -- INC AX
OPCODES[0x41] = function(cpu) incDec(cpu, 1,  1) end -- INC CX
OPCODES[0x42] = function(cpu) incDec(cpu, 2,  1) end -- INC DX
OPCODES[0x43] = function(cpu) incDec(cpu, 3,  1) end -- INC BX
OPCODES[0x44] = function(cpu) incDec(cpu, 4,  1) end -- INC SP
OPCODES[0x45] = function(cpu) incDec(cpu, 5,  1) end -- INC BP
OPCODES[0x46] = function(cpu) incDec(cpu, 6,  1) end -- INC SI
OPCODES[0x47] = function(cpu) incDec(cpu, 7,  1) end -- INC DI
OPCODES[0x48] = function(cpu) incDec(cpu, 0, -1) end -- DEC AX
OPCODES[0x49] = function(cpu) incDec(cpu, 1, -1) end -- DEC CX
OPCODES[0x4A] = function(cpu) incDec(cpu, 2, -1) end -- DEC DX
OPCODES[0x4B] = function(cpu) incDec(cpu, 3, -1) end -- DEC BX
OPCODES[0x4C] = function(cpu) incDec(cpu, 4, -1) end -- DEC SP
OPCODES[0x4D] = function(cpu) incDec(cpu, 5, -1) end -- DEC BP
OPCODES[0x4E] = function(cpu) incDec(cpu, 6, -1) end -- DEC SI
OPCODES[0x4F] = function(cpu) incDec(cpu, 7, -1) end -- DEC DI

OPCODES[0x50] = function(cpu) push(cpu, RR(cpu, 0, 1)) end -- PUSH AX
OPCODES[0x51] = function(cpu) push(cpu, RR(cpu, 1, 1)) end -- PUSH CX
OPCODES[0x52] = function(cpu) push(cpu, RR(cpu, 2, 1)) end -- PUSH DX
OPCODES[0x53] = function(cpu) push(cpu, RR(cpu, 3, 1)) end -- PUSH BX
OPCODES[0x54] = function(cpu) push(cpu, RR(cpu, 4, 1)) end -- PUSH SP
OPCODES[0x55] = function(cpu) push(cpu, RR(cpu, 5, 1)) end -- PUSH BP
OPCODES[0x56] = function(cpu) push(cpu, RR(cpu, 6, 1)) end -- PUSH SI
OPCODES[0x57] = function(cpu) push(cpu, RR(cpu, 7, 1)) end -- PUSH DI
OPCODES[0x58] = function(cpu) WR(cpu, 0, 1, pop(cpu)) end -- POP AX
OPCODES[0x59] = function(cpu) WR(cpu, 1, 1, pop(cpu)) end -- POP CX
OPCODES[0x5A] = function(cpu) WR(cpu, 2, 1, pop(cpu)) end -- POP DX
OPCODES[0x5B] = function(cpu) WR(cpu, 3, 1, pop(cpu)) end -- POP BX
OPCODES[0x5C] = function(cpu) WR(cpu, 4, 1, pop(cpu)) end -- POP SP
OPCODES[0x5D] = function(cpu) WR(cpu, 5, 1, pop(cpu)) end -- POP BP
OPCODES[0x5E] = function(cpu) WR(cpu, 6, 1, pop(cpu)) end -- POP SI
OPCODES[0x5F] = function(cpu) WR(cpu, 7, 1, pop(cpu)) end -- POP DI

-- 0x60 -> 0x69 undefined in Intel 8086

OPCODES[0x70] = function(cpu) jcc(cpu, readFlag(cpu, FLAGS.OF)) end                                      -- JO
OPCODES[0x71] = function(cpu) jcc(cpu, not readFlag(cpu, FLAGS.OF)) end                                  -- JNO
OPCODES[0x72] = function(cpu) jcc(cpu, readFlag(cpu, FLAGS.CF)) end                                      -- JB
OPCODES[0x73] = function(cpu) jcc(cpu, not readFlag(cpu, FLAGS.CF)) end                                  -- JNB
OPCODES[0x74] = function(cpu) jcc(cpu, readFlag(cpu, FLAGS.ZF)) end                                      -- JZ
OPCODES[0x75] = function(cpu) jcc(cpu, not readFlag(cpu, FLAGS.ZF)) end                                  -- JNZ
OPCODES[0x76] = function(cpu) jcc(cpu, readFlag(cpu, FLAGS.CF) or readFlag(cpu, FLAGS.ZF)) end           -- JBE
OPCODES[0x77] = function(cpu) jcc(cpu, not readFlag(cpu, FLAGS.CF) and not readFlag(cpu, FLAGS.ZF)) end  -- JNBE
OPCODES[0x78] = function(cpu) jcc(cpu, readFlag(cpu, FLAGS.SF)) end                                      -- JS
OPCODES[0x79] = function(cpu) jcc(cpu, not readFlag(cpu, FLAGS.SF)) end                                  -- JNS
OPCODES[0x7A] = function(cpu) jcc(cpu, readFlag(cpu, FLAGS.PF)) end                                      -- JP
OPCODES[0x7B] = function(cpu) jcc(cpu, not readFlag(cpu, FLAGS.PF)) end                                  -- JNP
OPCODES[0x7C] = function(cpu) jcc(cpu, SFNeOF(cpu)) end                                                  -- JL
OPCODES[0x7D] = function(cpu) jcc(cpu, not SFNeOF(cpu)) end                                              -- JNL
OPCODES[0x7E] = function(cpu) jcc(cpu, readFlag(cpu, FLAGS.ZF) or SFNeOF(cpu)) end                       -- JLE
OPCODES[0x7F] = function(cpu) jcc(cpu, not readFlag(cpu, FLAGS.ZF) and not SFNeOF(cpu)) end              -- JNLE

OPCODES[0x80] = function(cpu) group1(cpu, 0, 0) end -- GROUP1 r/m8,  imm8
OPCODES[0x81] = function(cpu) group1(cpu, 1, 1) end -- GROUP1 r/m16, imm16
OPCODES[0x82] = function(cpu) group1(cpu, 0, 0) end -- GROUP1 r/m8,  imm8
OPCODES[0x83] = function(cpu) group1(cpu, 1, 0) end -- GROUP1 r/m16, imm8 sign-extended

OPCODES[0x84] = function(cpu) test(cpu, 0) end -- TEST r/m8, r8
OPCODES[0x85] = function(cpu) test(cpu, 1) end -- TEST r/m16, r16
OPCODES[0x86] = function(cpu) xchg(cpu, 0) end -- XCHG r8, r/m8
OPCODES[0x87] = function(cpu) xchg(cpu, 1) end -- XCHG r16, r/m16

OPCODES[0x88] = function(cpu) mov(cpu, 0, 0) end -- MOV r/m8, r8
OPCODES[0x89] = function(cpu) mov(cpu, 0, 1) end -- MOV r/m16, r16
OPCODES[0x8A] = function(cpu) mov(cpu, 1, 0) end -- MOV r8, r/m8
OPCODES[0x8B] = function(cpu) mov(cpu, 1, 1) end -- MOV r16, r/m16

OPCODES[0x8D] = function(cpu) -- LEA r16, m
    local mod, reg, rm = ModRM(cpu)
    local base
    if mod == 0 and rm == 6 then
        base = imm(cpu, 1)
    else
        base = RM_EA[rm](cpu)
        if mod == 1 then
            base += buffer.readi8(cpu.RAM, physAddr(cpu.CS, cpu.IP))
            cpu.IP = bit32.band(cpu.IP + 1, 0xFFFF)
        elseif mod == 2 then
            base += buffer.readi16(cpu.RAM, physAddr(cpu.CS, cpu.IP))
            cpu.IP = bit32.band(cpu.IP + 2, 0xFFFF)
        end
    end
    WR(cpu, reg, 1, bit32.band(base, 0xFFFF))
end

OPCODES[0x8C] = function(cpu) -- MOV r/m16, sreg
    local mod, reg, rm = ModRM(cpu)
    local v = cpu[SREG[reg + 1]]
    if mod == 3 then
        WR(cpu, rm, 1, v)
    else
        WM(cpu, M(cpu, mod, rm), 1, v)
    end
end

OPCODES[0x8E] = function(cpu) -- MOV sreg, r/m16
    local mod, reg, rm = ModRM(cpu)
    local v = if mod == 3
        then RR(cpu, rm, 1)
        else RM(cpu, M(cpu, mod, rm), 1)
    cpu[SREG[reg + 1]] = v
end

OPCODES[0x8F] = function(cpu) -- POP r/m16
    local mod, _, rm = ModRM(cpu)
    local v = pop(cpu)
    if mod == 3 then
        WR(cpu, rm, 1, v)
    else
        WM(cpu, M(cpu, mod, rm), 1, v)
    end
end

OPCODES[0x90] = function(cpu) end                   -- NOP
OPCODES[0x91] = function(cpu) xchgAX(cpu, 1) end    -- XCHG AX, CX
OPCODES[0x92] = function(cpu) xchgAX(cpu, 2) end    -- XCHG AX, DX
OPCODES[0x93] = function(cpu) xchgAX(cpu, 3) end    -- XCHG AX, BX
OPCODES[0x94] = function(cpu) xchgAX(cpu, 4) end    -- XCHG AX, SP
OPCODES[0x95] = function(cpu) xchgAX(cpu, 5) end    -- XCHG AX, BP
OPCODES[0x96] = function(cpu) xchgAX(cpu, 6) end    -- XCHG AX, SI
OPCODES[0x97] = function(cpu) xchgAX(cpu, 7) end    -- XCHG AX, DI

OPCODES[0x98] = function(cpu) -- CBW
    local al = buffer.readi8(cpu.Registers, REG8_OFFSET[0])
    WR(cpu, 0, 1, bit32.band(al, 0xFFFF))
end

OPCODES[0x99] = function(cpu) -- CWD
    local ax = buffer.readi16(cpu.Registers, REG16_OFFSET[0])
    WR(cpu, 2, 1, ax < 0 and 0xFFFF or 0)
end

OPCODES[0x9A] = function(cpu) -- CALL far
    local ip = imm(cpu, 1)
    local cs = imm(cpu, 1)
    push(cpu, cpu.CS)
    push(cpu, cpu.IP)
    cpu.CS = cs
    cpu.IP = ip
end

OPCODES[0x9B] = function(cpu) end -- WAIT stub

OPCODES[0x9C] = function(cpu) push(cpu, cpu.FLAGS) end -- PUSHF

OPCODES[0x9D] = function(cpu) -- POPF
    cpu.FLAGS = bit32.bor(pop(cpu), 0b10)
end

OPCODES[0x9E] = function(cpu) -- SAHF
    cpu.FLAGS = bit32.bor(bit32.band(cpu.FLAGS, 0xFF00), RR(cpu, 4, 0))
end

OPCODES[0x9F] = function(cpu) -- LAHF
    WR(cpu, 4, 0, bit32.band(cpu.FLAGS, 0xFF))
end

OPCODES[0xA0] = function(cpu) -- MOV AL, imm16
    WR(cpu, 0, 0, RM(cpu, physAddr(cpu.SegmentOverride or cpu.DS, imm(cpu, 1)), 0))
end
OPCODES[0xA1] = function(cpu) -- MOV AX, imm16
    WR(cpu, 0, 1, RM(cpu, physAddr(cpu.SegmentOverride or cpu.DS, imm(cpu, 1)), 1))
end
OPCODES[0xA2] = function(cpu) -- MOV imm16, AL
    WM(cpu, physAddr(cpu.SegmentOverride or cpu.DS, imm(cpu, 1)), 0, RR(cpu, 0, 0))
end
OPCODES[0xA3] = function(cpu) -- MOV imm16, AX
    WM(cpu, physAddr(cpu.SegmentOverride or cpu.DS, imm(cpu, 1)), 1, RR(cpu, 0, 1))
end

OPCODES[0xA4] = function(cpu) -- MOVSB
    repLoop(cpu, function(c)
        WM(c, physAddr(c.ES, c.DI), 0, RM(c, physAddr(c.SegmentOverride or c.DS, c.SI), 0))
        strStep(c, 0)
    end, false)
end

OPCODES[0xA5] = function(cpu) -- MOVSW
    repLoop(cpu, function(c)
        WM(c, physAddr(c.ES, c.DI), 1, RM(c, physAddr(c.SegmentOverride or c.DS, c.SI), 1))
        strStep(c, 1)
    end, false)
end

OPCODES[0xA6] = function(cpu) -- CMPSB
    repLoop(cpu, function(c)
        flagsSub(c, RM(c, physAddr(c.SegmentOverride or c.DS, c.SI), 0), RM(c, physAddr(c.ES, c.DI), 0), 0)
        strStep(c, 0)
    end, true)
end

OPCODES[0xA7] = function(cpu) -- CMPSW
    repLoop(cpu, function(c)
        flagsSub(c, RM(c, physAddr(c.SegmentOverride or c.DS, c.SI), 1), RM(c, physAddr(c.ES, c.DI), 1), 1)
        strStep(c, 1)
    end, true)
end

OPCODES[0xA8] = function(cpu) flagsLogic(cpu, bit32.band(RR(cpu, 0, 0), imm(cpu, 0)), 0) end -- TEST AL, imm8
OPCODES[0xA9] = function(cpu) flagsLogic(cpu, bit32.band(RR(cpu, 0, 1), imm(cpu, 1)), 1) end -- TEST AX, imm16

OPCODES[0xAA] = function(cpu) -- STOSB
    repLoop(cpu, function(c)
        WM(c, physAddr(c.ES, c.DI), 0, RR(c, 0, 0))
        c.DI = bit32.band(c.DI + (readFlag(c, FLAGS.DF) and -1 or 1), 0xFFFF)
    end, false)
end

OPCODES[0xAB] = function(cpu) -- STOSW
    repLoop(cpu, function(c)
        WM(c, physAddr(c.ES, c.DI), 1, RR(c, 0, 1))
        c.DI = bit32.band(c.DI + (readFlag(c, FLAGS.DF) and -2 or 2), 0xFFFF)
    end, false)
end

OPCODES[0xAC] = function(cpu) -- LODSB
    repLoop(cpu, function(c)
        WR(c, 0, 0, RM(c, physAddr(c.SegmentOverride or c.DS, c.SI), 0))
        c.SI = bit32.band(c.SI + (readFlag(c, FLAGS.DF) and -1 or 1), 0xFFFF)
    end, false)
end

OPCODES[0xAD] = function(cpu) -- LODSW
    repLoop(cpu, function(c)
        WR(c, 0, 1, RM(c, physAddr(c.SegmentOverride or c.DS, c.SI), 1))
        c.SI = bit32.band(c.SI + (readFlag(c, FLAGS.DF) and -2 or 2), 0xFFFF)
    end, false)
end

OPCODES[0xAE] = function(cpu) -- SCASB
    repLoop(cpu, function(c)
        flagsSub(c, RR(c, 0, 0), RM(c, physAddr(c.ES, c.DI), 0), 0)
        c.DI = bit32.band(c.DI + (readFlag(c, FLAGS.DF) and -1 or 1), 0xFFFF)
    end, true)
end

OPCODES[0xAF] = function(cpu) -- SCASW
    repLoop(cpu, function(c)
        flagsSub(c, RR(c, 0, 1), RM(c, physAddr(c.ES, c.DI), 1), 1)
        c.DI = bit32.band(c.DI + (readFlag(c, FLAGS.DF) and -2 or 2), 0xFFFF)
    end, true)
end

OPCODES[0xB0] = function(cpu) WR(cpu, 0, 0, imm(cpu, 0)) end -- MOV AL, imm8
OPCODES[0xB1] = function(cpu) WR(cpu, 1, 0, imm(cpu, 0)) end -- MOV CL, imm8
OPCODES[0xB2] = function(cpu) WR(cpu, 2, 0, imm(cpu, 0)) end -- MOV DL, imm8
OPCODES[0xB3] = function(cpu) WR(cpu, 3, 0, imm(cpu, 0)) end -- MOV BL, imm8
OPCODES[0xB4] = function(cpu) WR(cpu, 4, 0, imm(cpu, 0)) end -- MOV AH, imm8
OPCODES[0xB5] = function(cpu) WR(cpu, 5, 0, imm(cpu, 0)) end -- MOV CH, imm8
OPCODES[0xB6] = function(cpu) WR(cpu, 6, 0, imm(cpu, 0)) end -- MOV DH, imm8
OPCODES[0xB7] = function(cpu) WR(cpu, 7, 0, imm(cpu, 0)) end -- MOV BH, imm8
OPCODES[0xB8] = function(cpu) WR(cpu, 0, 1, imm(cpu, 1)) end -- MOV AX, imm16
OPCODES[0xB9] = function(cpu) WR(cpu, 1, 1, imm(cpu, 1)) end -- MOV CX, imm16
OPCODES[0xBA] = function(cpu) WR(cpu, 2, 1, imm(cpu, 1)) end -- MOV DX, imm16
OPCODES[0xBB] = function(cpu) WR(cpu, 3, 1, imm(cpu, 1)) end -- MOV BX, imm16
OPCODES[0xBC] = function(cpu) WR(cpu, 4, 1, imm(cpu, 1)) end -- MOV SP, imm16
OPCODES[0xBD] = function(cpu) WR(cpu, 5, 1, imm(cpu, 1)) end -- MOV BP, imm16
OPCODES[0xBE] = function(cpu) WR(cpu, 6, 1, imm(cpu, 1)) end -- MOV SI, imm16
OPCODES[0xBF] = function(cpu) WR(cpu, 7, 1, imm(cpu, 1)) end -- MOV DI, imm16

-- 0xC0: undefined
-- 0xC1: undefined

OPCODES[0xC2] = function(cpu) -- RET imm16
    local bytes = imm(cpu, 1)
    cpu.IP = pop(cpu)
    WR(cpu, 8, 1, bit32.band(RR(cpu, 8, 1) + bytes, 0xFFFF))
end

OPCODES[0xC3] = function(cpu) -- RET
    cpu.IP = pop(cpu)
end

OPCODES[0xC4] = function(cpu) -- LES r16, m
    local mod, reg, rm = ModRM(cpu)
    local addr = M(cpu, mod, rm)
    WR(cpu, reg, 1, RM(cpu, addr, 1))
    cpu.ES = RM(cpu, addr + 2, 1)
end

OPCODES[0xC5] = function(cpu) -- LDS r16, m
    local mod, reg, rm = ModRM(cpu)
    local addr = M(cpu, mod, rm)
    WR(cpu, reg, 1, RM(cpu, addr, 1))
    cpu.DS = RM(cpu, addr + 2, 1)
end

OPCODES[0xC6] = function(cpu) -- MOV r/m8, imm8
    local mod, _, rm = ModRM(cpu)
    local v = imm(cpu, 0)
    if mod == 3 then WR(cpu, rm, 0, v)
    else WM(cpu, M(cpu, mod, rm), 0, v) end
end

OPCODES[0xC7] = function(cpu) -- MOV r/m16, imm16
    local mod, _, rm = ModRM(cpu)
    local v = imm(cpu, 1)
    if mod == 3 then WR(cpu, rm, 1, v)
    else WM(cpu, M(cpu, mod, rm), 1, v) end
end

OPCODES[0xCA] = function(cpu) -- RETF imm16
    local bytes = imm(cpu, 1)
    cpu.IP = pop(cpu)
    cpu.CS = pop(cpu)
    WR(cpu, 8, 1, bit32.band(RR(cpu, 8, 1) + bytes, 0xFFFF))
end

OPCODES[0xCB] = function(cpu) -- RETF
    cpu.IP = pop(cpu)
    cpu.CS = pop(cpu)
end

OPCODES[0xCC] = function(cpu) interrupt(cpu, 3) end  -- INT 3
OPCODES[0xCD] = function(cpu) interrupt(cpu, imm(cpu, 0)) end -- INT imm8

OPCODES[0xCE] = function(cpu) -- INTO
    if readFlag(cpu, FLAGS.OF) then interrupt(cpu, 4) end
end

OPCODES[0xCF] = function(cpu) -- IRET
    cpu.IP = pop(cpu)
    cpu.CS = pop(cpu)
    cpu.FLAGS = bit32.bor(pop(cpu), 0b10)
end

OPCODES[0xD0] = function(cpu) group2(cpu, 0, false) end -- GROUP2 r/m8,  1
OPCODES[0xD1] = function(cpu) group2(cpu, 1, false) end -- GROUP2 r/m16, 1
OPCODES[0xD2] = function(cpu) group2(cpu, 0, true) end  -- GROUP2 r/m8,  CL
OPCODES[0xD3] = function(cpu) group2(cpu, 1, true) end  -- GROUP2 r/m16, CL

OPCODES[0xD4] = function(cpu) -- AAM
    local base = imm(cpu, 0)
    local al = RR(cpu, 0, 0)
    WR(cpu, 4, 0, al // base)       -- AH = AL / base
    WR(cpu, 0, 0, al % base)        -- AL = AL % base
    local result = RR(cpu, 0, 0)
    setFlag(cpu, FLAGS.SF, bit32.extract(result, 7) == 1)
    setFlag(cpu, FLAGS.ZF, result == 0)
    setFlag(cpu, FLAGS.PF, PARITY[result])
end

OPCODES[0xD5] = function(cpu) -- AAD
    local base = imm(cpu, 0)
    local al = RR(cpu, 0, 0)
    local ah = RR(cpu, 4, 0)
    local result = bit32.band(al + ah * base, 0xFF)
    WR(cpu, 0, 0, result)
    WR(cpu, 4, 0, 0)
    setFlag(cpu, FLAGS.SF, bit32.extract(result, 7) == 1)
    setFlag(cpu, FLAGS.ZF, result == 0)
    setFlag(cpu, FLAGS.PF, PARITY[result])
end

-- 0xD6: undefined

OPCODES[0xD7] = function(cpu) -- XLAT
    local bx = RR(cpu, 3, 1)
    local al = RR(cpu, 0, 0)
    WR(cpu, 0, 0, RM(cpu, physAddr(cpu.SegmentOverride or cpu.DS, bit32.band(bx + al, 0xFFFF)), 0))
end

-- 0xD8-0xDF: FPU escape (stub, undefined on 8086 without 8087)

OPCODES[0xE0] = function(cpu) -- LOOPNE/LOOPNZ
    local offset = buffer.readi8(cpu.RAM, physAddr(cpu.CS, cpu.IP))
    cpu.IP = bit32.band(cpu.IP + 1, 0xFFFF)
    local cx = bit32.band(buffer.readu16(cpu.Registers, 2) - 1, 0xFFFF)
    buffer.writeu16(cpu.Registers, 2, cx)
    if cx ~= 0 and bit32.extract(cpu.FLAGS, 6) == 0 then
        cpu.IP = bit32.band(cpu.IP + offset, 0xFFFF)
    end
end

OPCODES[0xE1] = function(cpu) -- LOOPE/LOOPZ
    local offset = buffer.readi8(cpu.RAM, physAddr(cpu.CS, cpu.IP))
    cpu.IP = bit32.band(cpu.IP + 1, 0xFFFF)
    local cx = bit32.band(buffer.readu16(cpu.Registers, 2) - 1, 0xFFFF)
    buffer.writeu16(cpu.Registers, 2, cx)
    if cx ~= 0 and bit32.extract(cpu.FLAGS, 6) == 1 then
        cpu.IP = bit32.band(cpu.IP + offset, 0xFFFF)
    end
end

OPCODES[0xE2] = function(cpu) -- LOOP
    local offset = buffer.readi8(cpu.RAM, physAddr(cpu.CS, cpu.IP))
    cpu.IP = bit32.band(cpu.IP + 1, 0xFFFF)
    local cx = bit32.band(buffer.readu16(cpu.Registers, 2) - 1, 0xFFFF)
    buffer.writeu16(cpu.Registers, 2, cx)
    if cx ~= 0 then
        cpu.IP = bit32.band(cpu.IP + offset, 0xFFFF)
    end
end

OPCODES[0xE3] = function(cpu) -- JCXZ
    local offset = buffer.readi8(cpu.RAM, physAddr(cpu.CS, cpu.IP))
    cpu.IP = bit32.band(cpu.IP + 1, 0xFFFF)
    if buffer.readu16(cpu.Registers, 2) == 0 then
        cpu.IP = bit32.band(cpu.IP + offset, 0xFFFF)
    end
end

OPCODES[0xE4] = function(cpu) -- IN AL, imm8
    local port = imm(cpu, 0)
    local handler = cpu.PortIn[port]
    WR(cpu, 0, 0, handler and handler(port) or 0)
end

OPCODES[0xE5] = function(cpu) -- IN AX, imm8
    local port = imm(cpu, 0)
    local handler = cpu.PortIn[port]
    WR(cpu, 0, 1, handler and handler(port) or 0)
end

OPCODES[0xE6] = function(cpu) -- OUT imm8, AL
    local port = imm(cpu, 0)
    local handler = cpu.PortOut[port]
    if handler then handler(port, RR(cpu, 0, 0)) end
end

OPCODES[0xE7] = function(cpu) -- OUT imm8, AX
    local port = imm(cpu, 0)
    local handler = cpu.PortOut[port]
    if handler then handler(port, RR(cpu, 0, 1)) end
end

OPCODES[0xE8] = function(cpu) -- CALL near
    local offset = buffer.readi16(cpu.RAM, physAddr(cpu.CS, cpu.IP))
    cpu.IP = bit32.band(cpu.IP + 2, 0xFFFF)
    push(cpu, cpu.IP)
    cpu.IP = bit32.band(cpu.IP + offset, 0xFFFF)
end

OPCODES[0xE9] = function(cpu) -- JMP near
    local offset = buffer.readi16(cpu.RAM, physAddr(cpu.CS, cpu.IP))
    cpu.IP = bit32.band(cpu.IP + 2, 0xFFFF)
    cpu.IP = bit32.band(cpu.IP + offset, 0xFFFF)
end

OPCODES[0xEA] = function(cpu) -- JMP far
    local ip = imm(cpu, 1)
    local cs = imm(cpu, 1)
    cpu.CS = cs
    cpu.IP = ip
end

OPCODES[0xEB] = function(cpu) -- JMP short
    local offset = buffer.readi8(cpu.RAM, physAddr(cpu.CS, cpu.IP))
    cpu.IP = bit32.band(cpu.IP + 1, 0xFFFF)
    cpu.IP = bit32.band(cpu.IP + offset, 0xFFFF)
end

OPCODES[0xEC] = function(cpu) -- IN AL, DX
    local port = RR(cpu, 2, 1)
    local handler = cpu.PortIn[port]
    WR(cpu, 0, 0, handler and handler(port) or 0)
end

OPCODES[0xED] = function(cpu) -- IN AX, DX
    local port = RR(cpu, 2, 1)
    local handler = cpu.PortIn[port]
    WR(cpu, 0, 1, handler and handler(port) or 0)
end

OPCODES[0xEE] = function(cpu) -- OUT DX, AL
    local port = RR(cpu, 2, 1)
    local handler = cpu.PortOut[port]
    if handler then handler(port, RR(cpu, 0, 0)) end
end

OPCODES[0xEF] = function(cpu) -- OUT DX, AX
    local port = RR(cpu, 2, 1)
    local handler = cpu.PortOut[port]
    if handler then handler(port, RR(cpu, 0, 1)) end
end

OPCODES[0xF4] = function(cpu) -- HLT
    cpu.Halted = true
end

OPCODES[0xF5] = function(cpu) -- CMC
    cpu.FLAGS = bit32.bxor(cpu.FLAGS, 1)
end

OPCODES[0xF6] = function(cpu) -- GROUP3 r/m8
    local mod, reg, rm = ModRM(cpu)
    if reg == 0 or reg == 1 then -- TEST r/m8, imm8
        local v = if mod == 3 then RR(cpu, rm, 0) else RM(cpu, M(cpu, mod, rm), 0)
        flagsLogic(cpu, bit32.band(v, imm(cpu, 0)), 0)
    elseif reg == 2 then -- NOT r/m8
        if mod == 3 then
            WR(cpu, rm, 0, bit32.band(bit32.bnot(RR(cpu, rm, 0)), 0xFF))
        else
            local addr = M(cpu, mod, rm)
            WM(cpu, addr, 0, bit32.band(bit32.bnot(RM(cpu, addr, 0)), 0xFF))
        end
    elseif reg == 3 then -- NEG r/m8
        local addr: number = if mod == 3 then 0 else M(cpu, mod, rm)
        local v = if mod == 3 then RR(cpu, rm, 0) else RM(cpu, addr, 0)
        local result = flagsSub(cpu, 0, v, 0)
        setFlag(cpu, FLAGS.CF, v ~= 0)
        if mod == 3 then WR(cpu, rm, 0, result) else WM(cpu, addr, 0, result) end
    elseif reg == 4 then -- MUL AL, r/m8
        local v = if mod == 3 then RR(cpu, rm, 0) else RM(cpu, M(cpu, mod, rm), 0)
        local result = RR(cpu, 0, 0) * v
        WR(cpu, 0, 1, bit32.band(result, 0xFFFF))
        local upper = bit32.rshift(result, 8)
        setFlag(cpu, FLAGS.CF, upper ~= 0)
        setFlag(cpu, FLAGS.OF, upper ~= 0)
    elseif reg == 5 then -- IMUL AL, r/m8
        local v = buffer.readi8(cpu.RAM, if mod == 3 then 0 else M(cpu, mod, rm))
        if mod == 3 then v = bit32.band(RR(cpu, rm, 0), 0xFF) >= 0x80 and (RR(cpu, rm, 0) - 256) or RR(cpu, rm, 0) end
        local raw = buffer.readi8(cpu.Registers, REG8_OFFSET[0]) * v
        WR(cpu, 0, 1, bit32.band(raw, 0xFFFF))
        local upper = bit32.arshift(bit32.lshift(bit32.band(raw, 0xFFFF), 16), 24)
        local al_signex = bit32.arshift(bit32.lshift(bit32.band(raw, 0xFF), 24), 24)
        setFlag(cpu, FLAGS.CF, upper ~= al_signex)
        setFlag(cpu, FLAGS.OF, upper ~= al_signex)
    elseif reg == 6 then -- DIV AX / r/m8
        local v = if mod == 3 then RR(cpu, rm, 0) else RM(cpu, M(cpu, mod, rm), 0)
        if v == 0 then interrupt(cpu, 0); return end
        local ax = RR(cpu, 0, 1)
        local q = ax // v
        local r = ax % v
        if q > 0xFF then interrupt(cpu, 0); return end
        WR(cpu, 0, 0, q)
        WR(cpu, 4, 0, r)
    elseif reg == 7 then -- IDIV AX / r/m8
        local vraw = if mod == 3 then RR(cpu, rm, 0) else RM(cpu, M(cpu, mod, rm), 0)
        local v = vraw >= 0x80 and (vraw - 256) or vraw
        if v == 0 then interrupt(cpu, 0); return end
        local ax = buffer.readi16(cpu.Registers, REG16_OFFSET[0])
        local q = ax // v
        local r = ax % v
        if q < -128 or q > 127 then interrupt(cpu, 0); return end
        WR(cpu, 0, 0, bit32.band(q, 0xFF))
        WR(cpu, 4, 0, bit32.band(r, 0xFF))
    end
end

OPCODES[0xF7] = function(cpu) -- GROUP3 r/m16
    local mod, reg, rm = ModRM(cpu)
    if reg == 0 or reg == 1 then -- TEST r/m16, imm16
        local v = if mod == 3 then RR(cpu, rm, 1) else RM(cpu, M(cpu, mod, rm), 1)
        flagsLogic(cpu, bit32.band(v, imm(cpu, 1)), 1)
    elseif reg == 2 then -- NOT r/m16
        if mod == 3 then
            WR(cpu, rm, 1, bit32.band(bit32.bnot(RR(cpu, rm, 1)), 0xFFFF))
        else
            local addr = M(cpu, mod, rm)
            WM(cpu, addr, 1, bit32.band(bit32.bnot(RM(cpu, addr, 1)), 0xFFFF))
        end
    elseif reg == 3 then -- NEG r/m16
        local addr: number = if mod == 3 then 0 else M(cpu, mod, rm)
        local v = if mod == 3 then RR(cpu, rm, 1) else RM(cpu, addr, 1)
        local result = flagsSub(cpu, 0, v, 1)
        setFlag(cpu, FLAGS.CF, v ~= 0)
        if mod == 3 then WR(cpu, rm, 1, result) else WM(cpu, addr, 1, result) end
    elseif reg == 4 then -- MUL DX:AX, r/m16
        local v = if mod == 3 then RR(cpu, rm, 1) else RM(cpu, M(cpu, mod, rm), 1)
        local result = RR(cpu, 0, 1) * v
        WR(cpu, 0, 1, bit32.band(result, 0xFFFF))
        WR(cpu, 2, 1, bit32.band(bit32.rshift(result, 16), 0xFFFF))
        local upper = RR(cpu, 2, 1)
        setFlag(cpu, FLAGS.CF, upper ~= 0)
        setFlag(cpu, FLAGS.OF, upper ~= 0)
    elseif reg == 5 then -- IMUL DX:AX, r/m16
        local vraw = if mod == 3 then RR(cpu, rm, 1) else RM(cpu, M(cpu, mod, rm), 1)
        local v = vraw >= 0x8000 and (vraw - 65536) or vraw
        local ax = buffer.readi16(cpu.Registers, REG16_OFFSET[0])
        local result = ax * v
        WR(cpu, 0, 1, bit32.band(result, 0xFFFF))
        WR(cpu, 2, 1, bit32.band(bit32.rshift(bit32.band(result, 0xFFFFFFFF), 16), 0xFFFF))
        local dx = buffer.readi16(cpu.Registers, REG16_OFFSET[2])
        local ax_signex = bit32.arshift(bit32.lshift(bit32.band(result, 0xFFFF), 16), 16)
        setFlag(cpu, FLAGS.CF, dx ~= (ax_signex < 0 and -1 or 0))
        setFlag(cpu, FLAGS.OF, dx ~= (ax_signex < 0 and -1 or 0))
    elseif reg == 6 then -- DIV DX:AX / r/m16
        local v = if mod == 3 then RR(cpu, rm, 1) else RM(cpu, M(cpu, mod, rm), 1)
        if v == 0 then interrupt(cpu, 0); return end
        local dxax = RR(cpu, 2, 1) * 0x10000 + RR(cpu, 0, 1)
        local q = dxax // v
        local r = dxax % v
        if q > 0xFFFF then interrupt(cpu, 0); return end
        WR(cpu, 0, 1, q)
        WR(cpu, 2, 1, r)
    elseif reg == 7 then -- IDIV DX:AX / r/m16
        local vraw = if mod == 3 then RR(cpu, rm, 1) else RM(cpu, M(cpu, mod, rm), 1)
        local v = vraw >= 0x8000 and (vraw - 65536) or vraw
        if v == 0 then interrupt(cpu, 0); return end
        local dx = buffer.readi16(cpu.Registers, REG16_OFFSET[2])
        local ax = buffer.readu16(cpu.Registers, REG16_OFFSET[0])
        local dxax = dx * 0x10000 + ax
        local q = dxax // v
        local r = dxax % v
        if q < -32768 or q > 32767 then interrupt(cpu, 0); return end
        WR(cpu, 0, 1, bit32.band(q, 0xFFFF))
        WR(cpu, 2, 1, bit32.band(r, 0xFFFF))
    end
end

OPCODES[0xF8] = function(cpu) setFlag(cpu, FLAGS.CF, false) end -- CLC
OPCODES[0xF9] = function(cpu) setFlag(cpu, FLAGS.CF, true) end  -- STC
OPCODES[0xFA] = function(cpu) setFlag(cpu, FLAGS.IF, false) end -- CLI
OPCODES[0xFB] = function(cpu) setFlag(cpu, FLAGS.IF, true) end  -- STI
OPCODES[0xFC] = function(cpu) setFlag(cpu, FLAGS.DF, false) end -- CLD
OPCODES[0xFD] = function(cpu) setFlag(cpu, FLAGS.DF, true) end  -- STD

OPCODES[0xFE] = function(cpu) -- GROUP4 r/m8 (INC/DEC only)
    local mod, reg, rm = ModRM(cpu)
    local addr: number = if mod == 3 then 0 else M(cpu, mod, rm)
    local v = if mod == 3 then RR(cpu, rm, 0) else RM(cpu, addr, 0)
    local sign = if reg == 0 then 1 else -1
    setFlag(cpu, FLAGS.OF, sign == 1 and v == 0x7F or v == 0x80)
    local result = flagsIncDec(cpu, v + sign, 0)
    setFlag(cpu, FLAGS.AF, if sign == 1
        then bit32.band(v, 0x0F) == 0x0F
        else bit32.band(v, 0x0F) == 0x00)
    if mod == 3 then WR(cpu, rm, 0, result) else WM(cpu, addr, 0, result) end
end

OPCODES[0xFF] = function(cpu) -- GROUP5
    local mod, reg, rm = ModRM(cpu)
    local addr: number = if mod == 3 then 0 else M(cpu, mod, rm)
    local v = if mod == 3 then RR(cpu, rm, 1) else RM(cpu, addr, 1)
    if reg == 0 then -- INC r/m16
        setFlag(cpu, FLAGS.OF, v == 0x7FFF)
        local result = flagsIncDec(cpu, v + 1, 1)
        setFlag(cpu, FLAGS.AF, bit32.band(v, 0x0F) == 0x0F)
        if mod == 3 then WR(cpu, rm, 1, result) else WM(cpu, addr, 1, result) end
    elseif reg == 1 then -- DEC r/m16
        setFlag(cpu, FLAGS.OF, v == 0x8000)
        local result = flagsIncDec(cpu, v - 1, 1)
        setFlag(cpu, FLAGS.AF, bit32.band(v, 0x0F) == 0x00)
        if mod == 3 then WR(cpu, rm, 1, result) else WM(cpu, addr, 1, result) end
    elseif reg == 2 then -- CALL near r/m16
        push(cpu, cpu.IP)
        cpu.IP = v
    elseif reg == 3 then -- CALL far m16:16
        local far_ip = RM(cpu, addr, 1)
        local far_cs = RM(cpu, addr + 2, 1)
        push(cpu, cpu.CS)
        push(cpu, cpu.IP)
        cpu.CS = far_cs
        cpu.IP = far_ip
    elseif reg == 4 then -- JMP near r/m16
        cpu.IP = v
    elseif reg == 5 then -- JMP far m16:16
        cpu.IP = RM(cpu, addr, 1)
        cpu.CS = RM(cpu, addr + 2, 1)
    elseif reg == 6 then -- PUSH r/m16
        push(cpu, v)
    end
end

return OPCODES