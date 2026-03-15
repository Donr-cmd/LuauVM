# x86-32 Luau Emulator — Style Guide

## File Headers
Every file starts with:
```lua
--!optimize 2
--!native
```
`Opcodes.lua` additionally has `--!nocheck` as the second line.

## Naming
- Constants and lookup tables: `UPPER_SNAKE_CASE` (e.g. `REG_GET`, `BUF_READ`, `IMM_ALU`, `SEG_BASE`)
- Functions and locals: `camelCase` (e.g. `readR`, `writeRM`, `setFlagsAdd`, `loadSeg`)
- CPU state fields: `UPPER` for registers, bases, limits, access (e.g. `cpu.EAX`, `cpu.CSBase`, `cpu.CSLimit`, `cpu.CSAccess`, `cpu.CSD`)
- Opcode tables: `OPCODES` and `OPCODES_0F`

## Module Return
`Opcodes.lua` returns two values:
```lua
return OPCODES, INT
```
`CPU.lua` receives both:
```lua
local OPCODES, INT_IMPL = require(script:WaitForChild("Opcodes"))
CPU.INT = INT_IMPL
```

## Opcode Handlers
Each handler is a one-argument closure taking `cpu`:
```lua
OPCODES[0xNN] = function(cpu) ... end
```

For short one-liners, the body stays on the same line. The opcode mnemonic goes in a comment at the end, aligned to column 45:
```lua
OPCODES[0x40] = function(cpu) incR(cpu, 0) end -- INC EAX
```

For multi-line handlers, the comment goes on the `function(cpu)` line:
```lua
OPCODES[0x60] = function(cpu)                             -- PUSHA
    ...
end
```

## Helpers vs Inline
- Extract repeated logic into a named helper when it appears 2+ times.
- Opcode dispatch functions call helpers with constant literal arguments so Luau can inline and specialize (e.g. `incR(cpu, 0)` not `incR(cpu, i)` from a loop).
- Never use a loop to populate the OPCODES table — closures capturing loop variables destroy inlining.

## Lookup Tables for Dispatch
When `reg` or another field selects one of N operations, prefer a lookup table over an elseif chain when N > 3:
```lua
local IMM_ALU = {
    [0] = function(cpu, mod, rm, a, b, bits) ... end,
    ...
}
IMM_ALU[reg](cpu, mod, rm, a, b, bits)
```
Use an elseif chain only when N ≤ 3 or branches share state that is awkward to pass as arguments.

## Segment Name Tables
Never concatenate segment names with string suffixes. Use the pre-built tables:
```lua
local SEG_BASE   = { ES="ESBase",   CS="CSBase",   ... }
local SEG_LIMIT  = { ES="ESLimit",  CS="CSLimit",  ... }
local SEG_ACCESS = { ES="ESAccess", CS="CSAccess", ... }
```
`cpu[SEG_BASE[seg]]` not `cpu[seg.."Base"]`.

The same principle applies to control and debug registers — use `CR_NAME` and `DR_NAME` tables rather than inline conditionals:
```lua
local CR_NAME = { [0]="CR0", [2]="CR2", [3]="CR3" }
local DR_NAME = { [6]="DR6", [7]="DR7" }
```

## Segment Loading
All segment register writes go through `loadSeg(cpu, seg, selector)`. Never write `cpu[seg] = val; cpu[SEG_BASE[seg]] = val * 16` directly in an opcode handler. `loadSeg` handles both real mode (`selector * 16`) and protected mode (GDT/LDT descriptor walk) transparently.

## Prefix and Segment Handling
All prefix bytes are handled in `CPU:Step()` via the `PREFIXES` table. Leave a comment at the opcode slot:
```lua
-- 0x26 = ES: prefix, handled in CPU:Step() prefix loop
```

## Flag Helpers
Flag functions are named `setFlags<Op>`:
- `setFlagsAdd(cpu, a, b, result, bits)` — ADD, ADC
- `setFlagsSub(cpu, a, b, result, bits)` — SUB, SBB, CMP
- `setFlagsLogic(cpu, result, bits)` — OR, AND, XOR, TEST (clears CF, OF, AF)
- `setFlagsIncDec(cpu, a, result, bits, of)` — INC, DEC (never touches CF)
- `setFlagsIMUL(cpu, result, bits)` — CF and OF only

## Memory Access
Use `BUF_READ[bits]` and `BUF_WRITE[bits]` for sized access.

All addresses must go through `phys(cpu, addr)` before being passed to buffer functions:
```lua
local function phys(cpu, addr)
    return cpu.A20 and addr or bit32.band(addr, 0xFFEFFFFF)
end
```

- Code fetches: `phys(cpu, cpu.CSBase + cpu.EIP)`
- Stack: `phys(cpu, cpu.SSBase + cpu.ESP)`
- Data: result of `LA16(cpu, mod, rm)` — already phys'd internally
- String ops: `phys(cpu, cpu.ESBase + di)`, `phys(cpu, seg + si)`
- Any `addr + offset` derived from a phys'd base must also be wrapped: `phys(cpu, addr + bits // 8)`

## 64-bit Arithmetic Helpers
Luau doubles have 53-bit mantissa. 32×32 multiply and 64÷32 divide require helpers:
- `mul32to64(a, b)` — unsigned 32×32 → (hi, lo)
- `imul32to64(a, b)` — signed 32×32 → (hi, lo)
- `udiv64(hiNum, loNum, d)` — unsigned 64÷32 → (quot, rem)

Use these only in the `bits == 32` branch of MUL/IMUL/DIV/IDIV.

## String Operations
All string ops use:
- `strStep(cpu, bits)` — returns ±step based on DF flag
- `repNext(cpu)` — decrements CX and rewinds EIP by 1 if REP active and CX ≠ 0

REPNE only applies to `SCAS` and `CMPS`. Do not apply it to INS/OUTS.

## CPU State Reference

### Segment descriptor cache (per segment ES/CS/SS/DS/FS/GS)
| Field | Example | Meaning |
|---|---|---|
| `cpu.CS` | selector | 16-bit logical value |
| `cpu.CSBase` | 0–0xFFFFFFFF | linear base from descriptor |
| `cpu.CSLimit` | 0–0xFFFFFFFF | effective limit (granularity applied) |
| `cpu.CSAccess` | 0x9B / 0x93 | access byte from descriptor |
| `cpu.CSD` | 0 or 1 | default operand size bit |

### System registers
| Field | Init | Notes |
|---|---|---|
| `cpu.CR0` | 0 | bit 0 = PE, bit 31 = PG |
| `cpu.CR2` | 0 | page fault linear address |
| `cpu.CR3` | 0 | page directory base |
| `cpu.DR6` | 0xFFFF0FF0 | debug status |
| `cpu.DR7` | 0x00000400 | debug control |
| `cpu.GDTRBase/Limit` | 0/0 | global descriptor table |
| `cpu.IDTRBase/Limit` | 0/0x3FF | interrupt descriptor table |
| `cpu.TR/TRBase/TRLimit/TRAccess` | 0 | task register |
| `cpu.LDTR/LDTRBase/LDTRLimit/LDTRAccess` | 0 | LDT register |
| `cpu.CPL` | 0 | current privilege level |
| `cpu.TLB` | {} | page translation cache |
| `cpu._exception_depth` | 0 | double-fault guard |

## Exception / Interrupt Dispatch (`INT`)
`INT(cpu, n)` is defined as a local in `Opcodes.lua` (needs `loadSeg`, `BUF_WRITE`, `phys` in scope) and assigned to `CPU.INT` in `CPU.lua`.

- `_exception_depth >= 2` → silent abort (double-fault guard)
- Real mode: reads IVT at `n*4`, pushes FLAGS/CS/IP as 16-bit, clears TF+IF
- Protected mode: reads IDT gate at `IDTRBase + n*8`, checks present bit, dispatches by gate type
  - Gate D bit (bit 3 of type) → 32-bit push when set, 16-bit otherwise
  - CS is always pushed as 16-bit (2 bytes) regardless of gate size
  - Interrupt gate (0xE) and trap-16 gate (0x6) additionally clear IF
  - Task gates (0x5) not yet implemented

## Skipped / Unimplemented Opcodes
- Protected-mode-only with no real-mode behaviour: `cpu:INT(6)` (LLDT, LTR)
- Prefix bytes already handled: leave a comment
- Unimplemented opcodes error naturally (`attempt to call nil`) — no explicit assert needed