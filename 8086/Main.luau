--!strict
local CPU = require("./CPU")
local biosStr = require("./BiosData")

local RAM_SIZE = 0x100000
local ram = buffer.create(RAM_SIZE)
local biosBuf = buffer.fromstring(biosStr)
local BIOS_BASE = 0xF0000
buffer.copy(ram, BIOS_BASE, biosBuf)

print(string.format("[loader] BIOS loaded: %d bytes at 0x%05X", buffer.len(biosBuf), BIOS_BASE))

local cpu = CPU.new(ram)
cpu.CS = 0xF000
cpu.IP = 0x0000

-- CGA status port 0x03DA: alternate between display-enable and vsync
-- so the BIOS retrace-wait loop exits instead of spinning forever
local cgaToggle = 0
cpu.PortIn[0x03DA] = function(_)
    cgaToggle = 1 - cgaToggle
    return cgaToggle == 0 and 0x01 or 0x08
end
cpu.PortIn[0x03BA] = cpu.PortIn[0x03DA] -- MDA status same behaviour

-- 8086tiny debug port: char output
local lineBuf = ""
cpu.PortOut[0xE9] = function(_, val)
    if val == 10 or val == 13 then
        print(lineBuf)
        lineBuf = ""
    else
        lineBuf ..= string.char(val)
    end
end

-- catch-all: silent stub for all other ports
setmetatable(cpu.PortOut, { __index = function(_, _) return function() end end })
setmetatable(cpu.PortIn,  { __index = function(_, _) return function() return 0x00 end end })

print("[loader] Starting CPU at CS=0xF000 IP=0x0000")
print("------------------------------------------------------------")

local steps = 0
local MAX_STEPS = 10_000_000

while not cpu.Halted and steps < MAX_STEPS do
    cpu:Step()
    steps += 1
end

if #lineBuf > 0 then print(lineBuf) end
print("------------------------------------------------------------")
if cpu.Halted then
    print(string.format("[loader] HLT after %d steps  CS=%04X IP=%04X", steps, cpu.CS, cpu.IP))
else
    local phys = bit32.band(cpu.CS * 16 + cpu.IP, 0xFFFFF)
    print(string.format("[loader] Step limit. CS=%04X IP=%04X phys=%05X", cpu.CS, cpu.IP, phys))
end
