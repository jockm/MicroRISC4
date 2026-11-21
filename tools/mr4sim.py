import math
#!/usr/bin/env python3
"""
tools/mr4sim.py - Instruction-level simulator for the MiniRISC4 architecture.

Features:
  - 16-bit word-addressed memory space (64K words: 0x0000 - 0xFFFF).
  - Little-endian binary file loading (Slot 0 in byte 0, Slot 1 in byte 1).
  - Dual-slot instruction packing per word.
  - Native AND (Opcode 0xA).
  - Dedicated hardware shadow registers and exchange (XCHG Rr, Opcode 0xB, sub 0x3).
  - Full Descending stack:
      * LD Rr, (Rl++) -> Post-increment load (Pop, Opcode 0x4)
      * LD (--Rr), Rl -> Pre-decrement store (Push, Opcode 0x5)
  - Word-aligned instructions: PUSH8, LINK, TRAP (Slot 1 violation faulting).
  - Non-blocking MMIO UART at 0x000E (RX) and 0x000F (TX).
  - Interactive (m4db) debugger with symbol mapping, breakpoints, watchpoints,
    load, save, and arbitrary jump execution.
"""

import sys
from pathlib import Path
import os
import argparse
import select
from collections import deque

try:
    import readline
except ImportError:
    pass

IS_WINDOWS = sys.platform.startswith("win")
if IS_WINDOWS:
    import msvcrt
else:
    import tty
    import termios

MEM_WORDS       = 65536
WORD_MASK       = 0xFFFF
ADDR_MASK       = 0xFFFF
BYTE_MASK       = 0xFF

ADDR_UART_RX    = 0x000E
ADDR_UART_TX    = 0x000F
ADDR_RESET_VEC  = 0x0010
TRAP_BASE       = 0x0010

# MiniRISC4 Primary Opcodes (Bits [7:4] / [15:12])
OP_LD_REG       = 0x0
OP_LD_IMM4      = 0x1
OP_LD_PEEK      = 0x2
OP_LD_POKE      = 0x3
OP_LD_POP       = 0x4  # LD Rr, (Rl++)
OP_LD_PUSH      = 0x5  # LD (--Rr), Rl
OP_ADD          = 0x6
OP_SUB          = 0x7
OP_OR           = 0x8
OP_XOR          = 0x9
OP_AND          = 0xA  # Native single-cycle AND
OP_SHIFT        = 0xB
OP_ROT_INC_DEC  = 0xC
OP_JMP_Z        = 0xD
OP_JMP_M        = 0xE
OP_JMP_SPECIAL  = 0xF

# Sub-Opcodes for OP_SHIFT (0xB)
SUB_SHIFT_L     = 0x0
SUB_SHIFT_R     = 0x1
SUB_SHIFT_AR    = 0x2
SUB_SHIFT_XCHG  = 0x3

# Sub-Opcodes for OP_ROT_INC_DEC (0xC)
SUB_ROT_L       = 0x0
SUB_ROT_R       = 0x1
SUB_INC         = 0x2
SUB_DEC         = 0x3

# Sub-Opcodes for OP_JMP_SPECIAL (0xF)
SUB_JMP         = 0x0
SUB_LINK        = 0x1
SUB_PUSH8       = 0x2
SUB_TRAP        = 0x3


class RawTerminal:
    """Context manager for raw terminal I/O on POSIX platforms."""
    def __enter__(self):
        if not IS_WINDOWS and sys.stdin.isatty():
            self.old_settings = termios.tcgetattr(sys.stdin)
            tty.setcbreak(sys.stdin.fileno())
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        if not IS_WINDOWS and sys.stdin.isatty():
            termios.tcsetattr(sys.stdin, termios.TCSADRAIN, self.old_settings)



class SpiSdCard:
    """Minimal SDHC/SDv2 SPI block device model for mr4sim (--sd-image)."""
    def __init__(self, image_bytes: bytes):
        self.image = bytearray(image_bytes)
        if len(self.image) % 512 != 0:
            self.image.extend(b"\x00" * (512 - (len(self.image) % 512)))
        self.cs_n = 1
        self.fast_clk = 0
        self.cmd_buf = []
        self.tx_queue = []
        self.app_cmd = False

    def set_ctrl(self, val: int):
        prev_cs = self.cs_n
        self.cs_n = val & 1
        self.fast_clk = (val >> 1) & 1
        if self.cs_n == 1 and prev_cs == 0:
            self.cmd_buf.clear()
            self.tx_queue.clear()

    def status(self) -> int:
        return 0  # never busy

    def xfer(self, byte_val: int) -> int:
        b = byte_val & 0xFF
        if self.cs_n == 1:
            return 0xFF

        if not self.cmd_buf:
            if (b & 0xC0) == 0x40:
                self.cmd_buf.append(b)
                return 0xFF
            return self.tx_queue.pop(0) if self.tx_queue else 0xFF

        self.cmd_buf.append(b)
        if len(self.cmd_buf) < 6:
            return 0xFF

        cmd = self.cmd_buf[0] & 0x3F
        arg = (self.cmd_buf[1] << 24) | (self.cmd_buf[2] << 16) | (self.cmd_buf[3] << 8) | self.cmd_buf[4]
        self.cmd_buf.clear()

        if cmd == 0:  # CMD0: GO_IDLE_STATE
            self.app_cmd = False
            self.tx_queue = [0x01]
        elif cmd == 8:  # CMD8: SEND_IF_COND
            self.app_cmd = False
            self.tx_queue = [0x01, 0x00, 0x00, 0x01, (arg & 0xFF)]
        elif cmd == 55:  # CMD55: APP_CMD
            self.app_cmd = True
            self.tx_queue = [0x01]
        elif cmd == 41 and self.app_cmd:  # ACMD41: SD_SEND_OP_COND
            self.app_cmd = False
            self.tx_queue = [0x00]
        elif cmd == 17:  # CMD17: READ_SINGLE_BLOCK (SDHC = block address)
            self.app_cmd = False
            lba = arg & 0xFFFFFFFF
            off = lba * 512
            sector = bytes(self.image[off:off + 512])
            if len(sector) < 512:
                sector = sector + (b"\x00" * (512 - len(sector)))
            self.tx_queue = [0x00, 0xFF, 0xFE] + list(sector) + [0xFF, 0xFF]
        else:
            self.app_cmd = False
            self.tx_queue = [0x00]

        return 0xFF

# === Multi-Core NoC & Priority MBOX Simulator ===
ADDR_NOC_TX_DATA    = 0x0020  # W: push payload word to selected local ch (NOC_SEL_CH)
ADDR_NOC_SEL_CH     = 0x0021  # R/W: select local channel index [0..num_ch-1]
ADDR_NOC_RX_DATA    = 0x0022  # R: FIFO.R (pop from selected local RX channel FIFO)
ADDR_NOC_RX_STAT    = 0x0023  # R: FIFO.STAT (b0=not_empty, b1=full, b2=tx_ready, b[15:8]=rx_count)
ADDR_NOC_RX_TRYR    = 0x0024  # R: FIFO.TRYR (non-blocking pop; returns 0x0000 if empty)
ADDR_NOC_MBOX_SEND  = 0x0025  # W: send priority MBOX word to mapped (dst_core, dst_ch)
ADDR_NOC_MBOX_DATA  = 0x0026  # R: pop oldest incoming MBOX payload word (0x0000 if none)
ADDR_NOC_MBOX_SRC   = 0x0027  # R: {src_core[7:0], src_ch[7:0]} of last/queued MBOX
ADDR_NOC_CFG_CH_IDX = 0x0028  # W: select channel table entry local_ch to configure
ADDR_NOC_CFG_CH_MAP = 0x0029  # R/W: {dst_core[7:0], dst_ch[7:0]} for selected local_ch

class NocPacket:
    __slots__ = ("pkt_type", "src_core", "src_ch", "dst_core", "dst_ch", "payload", "hops", "_stage_node")
    def __init__(self, pkt_type: int, src_core: int, src_ch: int,
                 dst_core: int, dst_ch: int, payload: int, hops: int = 0):
        self.pkt_type = pkt_type      # 0 = DATA, 1 = MBOX (priority)
        self.src_core = src_core & 0xFF
        self.src_ch = src_ch & 0xFF
        self.dst_core = dst_core & 0xFF
        self.dst_ch = dst_ch & 0xFF
        self.payload = payload & WORD_MASK
        self.hops = hops
        self._stage_node = None

class CoreNetworkInterface:
    """Per-core NI with channel table, per-channel RX FIFOs, and priority MBOX queue."""
    def __init__(self, core_id: int, num_ch: int = 8, fifo_depth: int = 32,
                 mbox_trap_vec_offset: int = 0x0E):
        self.core_id = core_id
        self.num_ch = num_ch
        self.fifo_depth = fifo_depth
        self.mbox_trap_vec_offset = mbox_trap_vec_offset & 0x0F

        self.sel_ch = 0
        self.cfg_ch_idx = 0
        # channel_table[local_ch] = (dst_core, dst_ch, valid)
        self.channel_table = [(core_id, ch % num_ch, False) for ch in range(num_ch)]

        self.rx_fifos = [deque() for _ in range(num_ch)]
        self.tx_outbox = deque()          # DATA packets waiting for local router injection
        self.mbox_outbox = deque()        # Priority MBOX packets waiting for local router
        self.mbox_inbox = deque()         # Delivered (src_core, src_ch, payload) tuples
        self.last_mbox_src = 0
        self.pending_mbox_trap = False

    def set_route(self, local_ch: int, dst_core: int, dst_ch: int, valid: bool = True):
        if 0 <= local_ch < self.num_ch:
            self.channel_table[local_ch] = (dst_core & 0xFF, dst_ch & 0xFF, bool(valid))

    def rx_stat(self, ch: int | None = None) -> int:
        idx = (self.sel_ch if ch is None else ch) % self.num_ch
        q = self.rx_fifos[idx]
        not_empty = 1 if len(q) > 0 else 0
        full = 1 if len(q) >= self.fifo_depth else 0
        tx_ready = 1 if len(self.tx_outbox) < self.fifo_depth else 0
        cnt = min(len(q), 0xFF) << 8
        return cnt | (tx_ready << 2) | (full << 1) | not_empty

    def fifo_r(self, ch: int | None = None) -> int:
        idx = (self.sel_ch if ch is None else ch) % self.num_ch
        q = self.rx_fifos[idx]
        if hasattr(self, "_rx_meta") and self._rx_meta[idx]:
            self._rx_meta[idx].popleft()
        return q.popleft() if q else 0x0000

    def fifo_tryr(self, ch: int | None = None) -> int:
        # Per spec: non-blocking read returns 0x0000 when empty
        return self.fifo_r(ch)

    def send_data(self, payload: int, ch: int | None = None) -> bool:
        idx = (self.sel_ch if ch is None else ch) % self.num_ch
        if len(self.tx_outbox) >= self.fifo_depth:
            return False
        dst_core, dst_ch, valid = self.channel_table[idx]
        if not valid:
            dst_core, dst_ch = self.core_id, idx
        self.tx_outbox.append(NocPacket(0, self.core_id, idx, dst_core, dst_ch, payload))
        return True

    def send_mbox(self, payload: int, ch: int | None = None) -> bool:
        idx = (self.sel_ch if ch is None else ch) % self.num_ch
        if len(self.mbox_outbox) >= self.fifo_depth:
            return False
        dst_core, dst_ch, valid = self.channel_table[idx]
        if not valid:
            dst_core, dst_ch = self.core_id, idx
        self.mbox_outbox.append(NocPacket(1, self.core_id, idx, dst_core, dst_ch, payload))
        return True

    def accept_packet(self, pkt: NocPacket) -> bool:
        if pkt.pkt_type == 1:
            self.mbox_inbox.append((pkt.src_core, pkt.src_ch, pkt.payload))
            self.last_mbox_src = ((pkt.src_core & 0xFF) << 8) | (pkt.src_ch & 0xFF)
            self.pending_mbox_trap = True
            return True
        ch = pkt.dst_ch % self.num_ch
        q = self.rx_fifos[ch]
        if len(q) >= self.fifo_depth:
            return False  # backpressure / hold in router
        q.append(pkt.payload)
        if not hasattr(self, "_rx_meta"):
            self._rx_meta = [deque() for _ in range(self.num_ch)]
        self._rx_meta[ch].append((pkt.src_core, pkt.src_ch))
        return True

    def pop_mbox(self) -> int:
        if self.mbox_inbox:
            _, _, payload = self.mbox_inbox.popleft()
            return payload
        return 0x0000

class NocCluster:
    """Registered ring or 2D-mesh multi-core simulator (1 cycle per registered hop)."""
    def __init__(self, num_cores: int, topology: str = "ring",
                 mesh_cols: int | None = None, fifo_depth: int = 32, num_ch: int = 8,
                 mem_words: int = MEM_WORDS,
                 sdram_cache: "SdramCacheSubsystem | None" = None,
                 cache_core_id: int | None = None,
                 cache_base_addr: int | None = 0x4000,
                 cache_fetch: bool = False):
        assert num_cores >= 1
        self.num_cores = num_cores
        self.topology = topology
        if topology == "mesh":
            self.cols = mesh_cols if mesh_cols else math.ceil(math.sqrt(num_cores))
            self.rows = math.ceil(num_cores / self.cols)
        else:
            self.cols = num_cores
            self.rows = 1

        self.cores: list[MiniRISC4Sim] = []
        self.nis: list[CoreNetworkInterface] = []
        # Registered link pipeline stage (1 hop per cluster tick)
        self._in_flight: list[NocPacket] = []
        self.completed_packets: list[NocPacket] = []
        self.cluster_cycles = 0

        self.sdram_cache = sdram_cache
        for cid in range(num_cores):
            ni = CoreNetworkInterface(cid, num_ch=num_ch, fifo_depth=fifo_depth)
            use_cache = (sdram_cache is not None) and (cache_core_id is None or cid == cache_core_id)
            sim = MiniRISC4Sim(
                core_id=cid,
                noc_ni=ni,
                mem_words=mem_words,
                sdram_cache=sdram_cache if use_cache else None,
                cache_base_addr=cache_base_addr if use_cache else None,
                cache_fetch=cache_fetch if use_cache else False,
            )
            self.nis.append(ni)
            self.cores.append(sim)

    def configure_route(self, src_core: int, local_ch: int, dst_core: int, dst_ch: int):
        self.nis[src_core].set_route(local_ch, dst_core, dst_ch, valid=True)

    def _next_hop(self, curr_core: int, dst_core: int) -> int:
        if curr_core == dst_core:
            return dst_core
        if self.topology == "ring":
            # Shortest direction on ring (CW vs CCW)
            cw_dist = (dst_core - curr_core) % self.num_cores
            ccw_dist = (curr_core - dst_core) % self.num_cores
            if cw_dist <= ccw_dist:
                return (curr_core + 1) % self.num_cores
            return (curr_core - 1) % self.num_cores
        elif self.topology == "mesh":
            # Dimension-ordered XY routing on 2D mesh
            cx, cy = curr_core % self.cols, curr_core // self.cols
            dx, dy = dst_core % self.cols, dst_core // self.cols
            if cx != dx:
                nx = cx + (1 if dx > cx else -1)
                return cy * self.cols + nx
            if cy != dy:
                ny = cy + (1 if dy > cy else -1)
                return ny * self.cols + cx
            return dst_core
        raise ValueError(f"Unknown NoC topology: {self.topology}")

    def tick_noc(self):
        """Advance registered router stages by 1 clock cycle (MBOX prioritized)."""
        self.cluster_cycles += 1
        next_flight: list[NocPacket] = []

        # 1. Advance packets currently on registered inter-router links
        for pkt in self._in_flight:
            pkt.hops += 1
            if pkt.dst_core == pkt._stage_node:
                accepted = self.nis[pkt.dst_core].accept_packet(pkt)
                if accepted:
                    self.completed_packets.append(pkt)
                else:
                    next_flight.append(pkt)
            else:
                hop_to = self._next_hop(pkt._stage_node, pkt.dst_core)
                pkt._stage_node = hop_to
                next_flight.append(pkt)

        # 2. Inject from each core's NI (MBOX priority ahead of DATA)
        for cid, ni in enumerate(self.nis):
            pkt = None
            if ni.mbox_outbox:
                pkt = ni.mbox_outbox.popleft()
            elif ni.tx_outbox:
                pkt = ni.tx_outbox.popleft()

            if pkt is not None:
                if pkt.dst_core == cid:
                    pkt.hops += 1
                    if not self.nis[cid].accept_packet(pkt):
                        # Re-queue at head if full
                        if pkt.pkt_type == 1:
                            ni.mbox_outbox.appendleft(pkt)
                        else:
                            ni.tx_outbox.appendleft(pkt)
                    else:
                        self.completed_packets.append(pkt)
                else:
                    pkt._stage_node = self._next_hop(cid, pkt.dst_core)
                    next_flight.append(pkt)

        self._in_flight = next_flight

        # 3. Trigger priority MBOX trap on destination cores if pending
        for cid, (sim, ni) in enumerate(zip(self.cores, self.nis)):
            if ni.pending_mbox_trap and not sim.halted:
                ni.pending_mbox_trap = False
                trap_vec = sim.trap_base + ni.mbox_trap_vec_offset
                sim.r[0] = sim.pc & WORD_MASK
                sim._branch_to(sim.read_mem(trap_vec))

    def step_cycle(self):
        """Step each active core, advance background SDRAM write-behind, and tick the NoC."""
        for sim in self.cores:
            if not sim.halted:
                sim.step()
        if self.sdram_cache is not None:
            self.sdram_cache.tick(1)
        self.tick_noc()


class MiniRISC4Sim:
    def __init__(self, trace: bool = False, core_id: int = 0, noc_ni: "CoreNetworkInterface | None" = None, mem_words: int = MEM_WORDS, sdram_cache: "SdramCacheSubsystem | None" = None, cache_base_addr: int | None = None, cache_fetch: bool = False):
        assert 1 <= mem_words <= MEM_WORDS, "Per-core memory capped at 64K words (128K bytes)"
        self.mem_words = mem_words
        self.mem = [0] * mem_words
        self.sdram_cache = sdram_cache
        self.cache_base_addr = cache_base_addr
        self.cache_fetch = cache_fetch
        self.cache_stall_cycles = 0
        self.r = [0] * 4
        self.shadow_r = [0] * 4
        self.pc = 0
        self.trap_base = 0x0100
        self.core_id = core_id & 0xFFFF
        self.noc_ni = noc_ni if noc_ni is not None else CoreNetworkInterface(self.core_id)
        self.enable_cpuid = True
        self.enable_uart = True
        self.slot = 0          # 0 = Slot 0 [7:0], 1 = Slot 1 [15:8]
        self.trace = trace
        self.running = True
        self.halted = False
        self.rx_queue = deque()
        self.sd_card = None
        self.cycles = 0

        # Debugger state
        self.breakpoints = set()
        self.watchpoints = set()
        self.sym_to_addr = {}
        self.addr_to_sym = {}

    def load_binary(self, filename: str, offset: int = 0):
        """Loads a binary file into 16-bit word memory (little-endian: Slot 0 low, Slot 1 high)."""
        with open(filename, "rb") as f:
            data = f.read()
        if len(data) % 2 != 0:
            data += b"\x00"
        words = len(data) // 2
        for i in range(words):
            slot0 = data[i * 2]
            slot1 = data[i * 2 + 1]
            addr = (offset + i) & ADDR_MASK
            self.mem[addr] = (slot1 << 8) | slot0

    def load_symbols(self, lst_filename: str):
        """Parses an assembler listing file (.lst) to resolve symbolic labels."""
        if not os.path.exists(lst_filename):
            return
        with open(lst_filename, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) >= 2:
                    try:
                        addr = int(parts[0], 16)
                        token = parts[1]
                        if token.endswith(":"):
                            label = token[:-1]
                            self.sym_to_addr[label] = addr
                            self.addr_to_sym[addr] = label
                    except ValueError:
                        continue

    def parse_addr_or_symbol(self, token: str):
        """Resolves a hex address, decimal address, or symbol string to a 16-bit address."""
        if token in self.sym_to_addr:
            return self.sym_to_addr[token]
        try:
            return int(token, 0) & ADDR_MASK
        except ValueError:
            return None

    def _uses_sdram_cache(self, addr: int) -> bool:
        if self.sdram_cache is None:
            return False
        if self.cache_base_addr is not None:
            return (addr & ADDR_MASK) >= (self.cache_base_addr & ADDR_MASK)
        return False

    def read_mem(self, addr: int) -> int:
        addr &= ADDR_MASK
        if addr == ADDR_UART_RX:
            self._poll_stdin()
            if self.rx_queue:
                ch = self.rx_queue.popleft()
                return 0x8000 | (ch & BYTE_MASK)
            return 0x0000
        elif addr == ADDR_UART_TX:
            return 0x0000  # UART TX status: 0x0000 = idle / ready
        if addr == 0x000D and getattr(self, 'enable_cpuid', True):
            return getattr(self, 'core_id', 0) & 0xFFFF
        if addr == 0x0018 and self.sd_card is not None:
            return (1 if self.sd_card.cs_n else 0) | ((1 if self.sd_card.fast_clk else 0) << 1)
        if addr == 0x0019 and self.sd_card is not None:
            return self.sd_card.status()
        if addr == 0x001A and self.sd_card is not None:
            v = getattr(self.sd_card, "_last_rx", 0xFF)
            self.sd_card._last_rx = 0xFF
            return v
        if addr == ADDR_NOC_SEL_CH:
            return self.noc_ni.sel_ch & WORD_MASK
        if addr == ADDR_NOC_RX_DATA:
            return self.noc_ni.fifo_r() & WORD_MASK
        if addr == ADDR_NOC_RX_STAT:
            return self.noc_ni.rx_stat() & WORD_MASK
        if addr == ADDR_NOC_RX_TRYR:
            return self.noc_ni.fifo_tryr() & WORD_MASK
        if addr == ADDR_NOC_MBOX_DATA:
            return self.noc_ni.pop_mbox() & WORD_MASK
        if addr == ADDR_NOC_MBOX_SRC:
            return self.noc_ni.last_mbox_src & WORD_MASK
        if addr == ADDR_NOC_CFG_CH_IDX:
            return self.noc_ni.cfg_ch_idx & WORD_MASK
        if addr == ADDR_NOC_CFG_CH_MAP:
            dst_c, dst_ch, _ = self.noc_ni.channel_table[self.noc_ni.cfg_ch_idx % self.noc_ni.num_ch]
            return ((dst_c & 0xFF) << 8) | (dst_ch & 0xFF)
        if self._uses_sdram_cache(addr):
            val, lat = self.sdram_cache.read_data_word(addr)
            if lat > 1:
                self.cache_stall_cycles += (lat - 1)
                self.cycles += (lat - 1)
            return val & WORD_MASK
        return self.mem[addr % self.mem_words]

    def write_mem(self, addr: int, val: int):
        addr &= ADDR_MASK
        val &= WORD_MASK
        if addr in self.watchpoints:
            print(f"\n[WATCHPOINT] Write to 0x{addr:04X}: Old=0x{self.mem[addr]:04X}, New=0x{val:04X}")
            self.interactive_cli()

        if addr == ADDR_UART_TX:
            char = chr(val & BYTE_MASK)
            sys.stdout.write(char)
            sys.stdout.flush()
        elif addr == 0x0018 and self.sd_card is not None:
            self.sd_card.set_ctrl(val)
            self.mem[addr] = val
        elif addr == 0x001A and self.sd_card is not None:
            self.sd_card._last_rx = self.sd_card.xfer(val)
        elif addr == ADDR_NOC_TX_DATA:
            self.noc_ni.send_data(val)
            self.mem[addr] = val
        elif addr == ADDR_NOC_SEL_CH:
            self.noc_ni.sel_ch = val % self.noc_ni.num_ch
            self.mem[addr] = self.noc_ni.sel_ch
        elif addr == ADDR_NOC_MBOX_SEND:
            self.noc_ni.send_mbox(val)
            self.mem[addr] = val
        elif addr == ADDR_NOC_CFG_CH_IDX:
            self.noc_ni.cfg_ch_idx = val % self.noc_ni.num_ch
            self.mem[addr] = self.noc_ni.cfg_ch_idx
        elif addr == ADDR_NOC_CFG_CH_MAP:
            dst_c = (val >> 8) & 0xFF
            dst_ch = val & 0xFF
            self.noc_ni.set_route(self.noc_ni.cfg_ch_idx, dst_c, dst_ch, valid=True)
            self.mem[addr] = val
        elif self._uses_sdram_cache(addr):
            _, lat = self.sdram_cache.write_data_word(addr, val)
            if lat > 1:
                self.cache_stall_cycles += (lat - 1)
                self.cycles += (lat - 1)
        else:
            self.mem[addr % self.mem_words] = val

    def _poll_stdin(self):
        """Polls host terminal for incoming characters."""
        if IS_WINDOWS:
            while msvcrt.kbhit():
                ch = msvcrt.getch()
                self.rx_queue.append(ord(ch))
        else:
            r, _, _ = select.select([sys.stdin], [], [], 0)
            if r:
                data = os.read(sys.stdin.fileno(), 1024)
                for b in data:
                    self.rx_queue.append(b)

    def _branch_to(self, target_word_addr: int):
        self.pc = target_word_addr & ADDR_MASK
        self.slot = 0

    def step(self):
        """Executes a single instruction slot."""
        if self.halted:
            return

        current_pc = self.pc
        current_slot = self.slot
        if self.sdram_cache is not None and (self.cache_fetch or self._uses_sdram_cache(current_pc)):
            word, flat = self.sdram_cache.fetch_inst_word(current_pc)
            if flat > 1:
                self.cache_stall_cycles += (flat - 1)
                self.cycles += (flat - 1)
        else:
            word = self.mem[current_pc % self.mem_words]

        if current_slot == 0:
            instr = word & BYTE_MASK
        else:
            instr = (word >> 8) & BYTE_MASK

        opcode = (instr >> 4) & 0x0F
        arg = instr & 0x0F
        rr = (arg >> 2) & 0x03
        rl = arg & 0x03

        if self.trace and current_slot == 0:
            sym = f" <{self.addr_to_sym[current_pc]}>" if current_pc in self.addr_to_sym else ""
            print(f"\nPC:0x{current_pc:04X}{sym} [0x{word:04X}] | R0:{self.r[0]:04X} R1:{self.r[1]:04X} R2:{self.r[2]:04X} R3:{self.r[3]:04X}")

        # Advance slot / PC tracking default
        next_pc = current_pc
        next_slot = current_slot + 1
        if next_slot > 1:
            next_slot = 0
            next_pc = (current_pc + 1) & ADDR_MASK

        self.pc = next_pc
        self.slot = next_slot
        self.cycles += 1

        # ----------------------------------------------------------------------
        # Opcode Decoding
        # ----------------------------------------------------------------------
        if opcode == OP_LD_REG:
            self.r[rr] = self.r[rl]

        elif opcode == OP_LD_IMM4:
            self.r[0] = arg

        elif opcode == OP_LD_PEEK:
            self.r[rr] = self.read_mem(self.r[rl])

        elif opcode == OP_LD_POKE:
            self.write_mem(self.r[rr], self.r[rl])

        elif opcode == OP_LD_POP:
            # LD Rr, (Rl++)
            ptr = self.r[rl]
            self.r[rr] = self.read_mem(ptr)
            self.r[rl] = (ptr + 1) & ADDR_MASK

        elif opcode == OP_LD_PUSH:
            # LD (--Rr), Rl
            ptr = (self.r[rr] - 1) & ADDR_MASK
            val_to_write = self.r[rl]
            self.r[rr] = ptr
            self.write_mem(ptr, val_to_write)

        elif opcode == OP_ADD:
            res = (self.r[rr] + self.r[rl]) & WORD_MASK
            self.r[rr] = res

        elif opcode == OP_SUB:
            res = (self.r[rr] - self.r[rl]) & WORD_MASK
            self.r[rr] = res

        elif opcode == OP_OR:
            self.r[rr] = (self.r[rr] | self.r[rl]) & WORD_MASK

        elif opcode == OP_XOR:
            self.r[rr] = (self.r[rr] ^ self.r[rl]) & WORD_MASK

        elif opcode == OP_AND:
            # Native single-cycle AND
            self.r[rr] = (self.r[rr] & self.r[rl]) & WORD_MASK

        elif opcode == OP_SHIFT:
            if rr == SUB_SHIFT_L:
                self.r[rl] = (self.r[rl] << 1) & WORD_MASK
            elif rr == SUB_SHIFT_R:
                self.r[rl] = (self.r[rl] >> 1) & WORD_MASK
            elif rr == SUB_SHIFT_AR:
                sign = self.r[rl] & 0x8000
                self.r[rl] = (self.r[rl] >> 1) | sign
            elif rr == SUB_SHIFT_XCHG:
                tmp = self.r[rl]
                self.r[rl] = self.shadow_r[rl]
                self.shadow_r[rl] = tmp

        elif opcode == OP_ROT_INC_DEC:
            if rr == SUB_ROT_L:
                msb = (self.r[rl] >> 15) & 1
                self.r[rl] = ((self.r[rl] << 1) | msb) & WORD_MASK
            elif rr == SUB_ROT_R:
                lsb = self.r[rl] & 1
                self.r[rl] = ((self.r[rl] >> 1) | (lsb << 15)) & WORD_MASK
            elif rr == SUB_INC:
                self.r[rl] = (self.r[rl] + 1) & WORD_MASK
            elif rr == SUB_DEC:
                self.r[rl] = (self.r[rl] - 1) & WORD_MASK

        elif opcode == OP_JMP_Z:
            # JMP.Z Rr, Rl -> Branch to Rr if Rl == 0
            if self.r[rl] == 0:
                self._branch_to(self.r[rr])

        elif opcode == OP_JMP_M:
            # JMP.M Rr, Rl -> Branch to Rr if Rl is negative (bit 15 set)
            if (self.r[rl] & 0x8000) != 0:
                self._branch_to(self.r[rr])

        elif opcode == OP_JMP_SPECIAL:
            if current_slot != 0 and rr != SUB_JMP:
                # Word-alignment fault for PUSH8, LINK, TRAP
                print(f"\n[FAULT] Slot 1 alignment violation at PC:0x{current_pc:04X}")
                self.pc = self.read_mem(0xFFFF)
                self.slot = 0
                return

            if rr == SUB_JMP:
                self._branch_to(self.r[rl])

            elif rr == SUB_LINK:
                target = self.r[rl]
                self.r[0] = (current_pc + 1) & ADDR_MASK
                self._branch_to(target)

            elif rr == SUB_PUSH8:
                imm8 = (word >> 8) & BYTE_MASK
                self.r[rl] = ((self.r[rl] << 8) | imm8) & WORD_MASK
                self.pc = (current_pc + 1) & ADDR_MASK
                self.slot = 0

            elif rr == SUB_TRAP:
                trap_vector = TRAP_BASE + (self.r[rl] & 0x0F)
                self.r[0] = (current_pc + 1) & ADDR_MASK
                self._branch_to(self.read_mem(trap_vector))

    def interactive_cli(self):
        """Interactive debugger command loop ((m4db))."""
        print(f"\n--- MiniRISC4 Debugger (m4db) ---")
        print(f"PC: 0x{self.pc:04X} (Slot {self.slot}), Cycles: {self.cycles}")

        while True:
            try:
                cmd_line = input("(m4db) ").strip()
            except (EOFError, KeyboardInterrupt):
                print()
                return

            if not cmd_line:
                continue

            parts = cmd_line.split()
            cmd = parts[0].lower()
            args = parts[1:]

            if cmd in ("h", "help", "?"):
                self.print_help()

            elif cmd in ("c", "cont", "continue"):
                print("Continuing execution (Press Ctrl+C to halt into debugger)...")
                return

            elif cmd in ("s", "step"):
                self.step()
                sym = f" <{self.addr_to_sym[self.pc]}>" if self.pc in self.addr_to_sym else ""
                print(f"Step -> PC: 0x{self.pc:04X}{sym} Slot:{self.slot}")

            elif cmd in ("stepw", "next", "n"):
                start_pc = self.pc
                while self.pc == start_pc and not self.halted:
                    self.step()
                sym = f" <{self.addr_to_sym[self.pc]}>" if self.pc in self.addr_to_sym else ""
                print(f"Step Word -> PC: 0x{self.pc:04X}{sym}")

            elif cmd in ("r", "regs"):
                print(f"R0: 0x{self.r[0]:04X}  R1: 0x{self.r[1]:04X}  R2: 0x{self.r[2]:04X}  R3: 0x{self.r[3]:04X}")
                print(f"s0: 0x{self.shadow_r[0]:04X}  s1: 0x{self.shadow_r[1]:04X}  s2: 0x{self.shadow_r[2]:04X}  s3: 0x{self.shadow_r[3]:04X}")
                print(f"PC: 0x{self.pc:04X}  Slot: {self.slot}  RSP: 0x{self.mem[4]:04X}  ASP: 0x{self.mem[5]:04X}")

            elif cmd in ("m", "mem", "dump"):
                if not args:
                    print("Usage: m <addr/label> [count]")
                    continue
                start = self.parse_addr_or_symbol(args[0])
                if start is None:
                    print(f"Invalid address: {args[0]}")
                    continue
                cnt = int(args[1], 0) if len(args) > 1 else 8
                for i in range(cnt):
                    addr = (start + i) & ADDR_MASK
                    val = self.mem[addr]
                    lo = val & 0xFF
                    hi = (val >> 8) & 0xFF
                    c_lo = chr(lo) if 32 <= lo <= 126 else "."
                    c_hi = chr(hi) if 32 <= hi <= 126 else "."
                    sym = f" <{self.addr_to_sym[addr]}>" if addr in self.addr_to_sym else ""
                    print(f"  0x{addr:04X}{sym:20s}: 0x{val:04X}  [{lo:02X} {hi:02X}]  '{c_lo}{c_hi}'")

            elif cmd in ("b", "break"):
                if not args:
                    print("Usage: b <addr/label>")
                    continue
                addr = self.parse_addr_or_symbol(args[0])
                if addr is None:
                    print(f"Invalid address: {args[0]}")
                    continue
                self.breakpoints.add(addr)
                print(f"Breakpoint set at 0x{addr:04X}")

            elif cmd in ("blist",):
                print(f"Active breakpoints: {[f'0x{a:04X}' for a in sorted(self.breakpoints)]}")

            elif cmd in ("bdel",):
                if not args:
                    print("Usage: bdel <addr/label>")
                    continue
                addr = self.parse_addr_or_symbol(args[0])
                if addr in self.breakpoints:
                    self.breakpoints.remove(addr)
                    print(f"Removed breakpoint at 0x{addr:04X}")

            elif cmd in ("watch",):
                if not args:
                    print("Usage: watch <addr/label>")
                    continue
                addr = self.parse_addr_or_symbol(args[0])
                if addr is not None:
                    self.watchpoints.add(addr)
                    print(f"Watchpoint set for writes to 0x{addr:04X}")

            elif cmd in ("g", "jump", "goto"):
                if not args:
                    print("Usage: g <addr/label>  or  jump <addr/label>")
                    continue
                target = self.parse_addr_or_symbol(args[0])
                if target is None:
                    print(f"Invalid target address or symbol: {args[0]}")
                    continue
                self.pc = target & ADDR_MASK
                self.slot = 0
                sym_info = f" <{self.addr_to_sym[self.pc]}>" if self.pc in self.addr_to_sym else ""
                print(f"Jumping to 0x{self.pc:04X}{sym_info} and continuing execution...")
                return

            elif cmd == "load":
                if len(args) < 2:
                    print("Usage: load <filename> <addr/label>")
                    continue

                filename = args[0]
                target_addr = self.parse_addr_or_symbol(args[1])

                if target_addr is None:
                    print(f"Error: Invalid load address or symbol '{args[1]}'")
                    continue

                if not os.path.exists(filename):
                    print(f"Error: File '{filename}' not found")
                    continue

                try:
                    with open(filename, "rb") as f:
                        raw_data = f.read()

                    # Pad to even number of bytes for 16-bit word alignment
                    if len(raw_data) % 2 != 0:
                        raw_data += b"\x00"

                    words_count = len(raw_data) // 2
                    for i in range(words_count):
                        slot0 = raw_data[i * 2]
                        slot1 = raw_data[i * 2 + 1]
                        dest_addr = (target_addr + i) & ADDR_MASK
                        self.mem[dest_addr] = (slot1 << 8) | slot0

                    end_addr = (target_addr + words_count - 1) & ADDR_MASK
                    print(f"Loaded {words_count} words ({len(raw_data)} bytes) from '{filename}' into [0x{target_addr:04X}..0x{end_addr:04X}]")

                except Exception as e:
                    print(f"Error loading file: {e}")

            elif cmd == "save":
                if len(args) < 3:
                    print("Usage: save <addr/label> <length> <filename>")
                    continue

                start_addr = self.parse_addr_or_symbol(args[0])
                if start_addr is None:
                    print(f"Error: Invalid start address or symbol '{args[0]}'")
                    continue

                try:
                    length = int(args[1], 0)
                except ValueError:
                    print(f"Error: Invalid length '{args[1]}'")
                    continue

                filename = args[2]

                try:
                    out_bytes = bytearray()
                    for i in range(length):
                        src_addr = (start_addr + i) & ADDR_MASK
                        word_val = self.mem[src_addr]
                        slot0 = word_val & BYTE_MASK
                        slot1 = (word_val >> 8) & BYTE_MASK
                        out_bytes.append(slot0)
                        out_bytes.append(slot1)

                    with open(filename, "wb") as f:
                        f.write(out_bytes)

                    end_addr = (start_addr + length - 1) & ADDR_MASK
                    print(f"Saved {length} words ({len(out_bytes)} bytes) from [0x{start_addr:04X}..0x{end_addr:04X}] to '{filename}'")

                except Exception as e:
                    print(f"Error saving file: {e}")

            elif cmd in ("q", "quit", "exit"):
                print("Exiting simulator.")
                self.running = False
                if not IS_WINDOWS and sys.stdin.isatty() and hasattr(self, "_orig_term_settings") and self._orig_term_settings is not None:
                    try:
                        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, self._orig_term_settings)
                    except Exception:
                        pass
                sys.exit(0)

            else:
                print(f"Unknown command: '{cmd}'. Type 'help' for debugger commands.")

    def print_help(self):
        print("""
Execution & Stepping:
  s, step                        Step 1 instruction slot
  n, next, stepw                 Step 1 full 16-bit word
  c, cont                        Continue execution until breakpoint or Ctrl+C
  g, jump <addr/label>           Set PC to arbitrary address/label and continue

Breakpoints & Watchpoints:
  b, break <addr/label>          Set breakpoint at word address
  blist                          List all breakpoints
  bdel <addr/label>              Delete breakpoint
  watch <addr/label>             Set watchpoint on memory writes

Inspection & Memory:
  r, regs                        Display all general and shadow registers
  m, mem <addr/label> [count]    Dump memory words in hex and ASCII

File Operations:
  load <filename> <addr/label>         Load binary file into memory at address
  save <addr/label> <length> <filename> Save length words from memory to binary file

Control:
  q, quit                        Exit simulator
""")


def main():
    parser = argparse.ArgumentParser(description="MiniRISC4 Instruction-Level Python Simulator (mr4sim)")
    parser.add_argument("binary", help="Path to binary file (.bin)")
    parser.add_argument("--memwords", type=lambda x: int(x, 0), default=65536, help="Physical memory capacity in words (default: 65536)")
    parser.add_argument("--core-id", type=lambda x: int(x, 0), default=0, help="Hardware Core ID (default: 0)")
    parser.add_argument("--disable-cpuid", action="store_true", help="Disable CPUID at 0x000D (treat as RAM)")
    parser.add_argument("--disable-uart", action="store_true", help="Disable UART MMIO at 0x000E/0x000F (treat as RAM)")
    parser.add_argument("--trapbase", type=lambda x: int(x, 0), default=0x0100, help="Vector table base address (default: 0x0010)")
    parser.add_argument("--startaddr", type=lambda x: int(x, 0), default=None,
                        help="Starting word address (hex e.g. 0x0100). Default: reset vector at mem[0xFFF0]")
    parser.add_argument("--loadaddr", type=lambda x: int(x, 0), default=0,
                        help="Word offset at which to load the binary into memory (default: 0x0000)")
    parser.add_argument("--debug", action="store_true", help="Halt into debugger immediately before execution")
    parser.add_argument("--trace", action="store_true", help="Print PC and register state on every cycle")
    parser.add_argument("--sym", default=None, help="Assembler listing file (.lst) for symbol resolution")
    parser.add_argument("--sd-image", default=None, help="Path to FAT32 SD disk image for SPI SD card emulation")
    args = parser.parse_args()

    if not os.path.exists(args.binary):
        print(f"Error: Binary file '{args.binary}' not found.", file=sys.stderr)
        sys.exit(1)

    sim = MiniRISC4Sim(trace=args.trace)
    if args.sd_image:
        sim.sd_card = SpiSdCard(Path(args.sd_image).read_bytes())
    sim.load_binary(args.binary, offset=args.loadaddr)

    if args.sym:
        sim.load_symbols(args.sym)

    if args.startaddr is not None:
        sim.pc = args.startaddr & ADDR_MASK
    else:
        sim.pc = 0x0100

    if args.debug:
        sim.interactive_cli()

    old_settings = termios.tcgetattr(sys.stdin) if not IS_WINDOWS and sys.stdin.isatty() else None
    sim._orig_term_settings = old_settings
    try:
        while sim.running:
            try:
                if not IS_WINDOWS and sys.stdin.isatty():
                    tty.setcbreak(sys.stdin.fileno())

                while sim.running:
                    # Check breakpoints
                    if sim.slot == 0 and sim.pc in sim.breakpoints:
                        if old_settings:
                            termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)
                        print(f"\n[BREAKPOINT] Reached breakpoint at 0x{sim.pc:04X}")
                        sim.interactive_cli()
                        if not IS_WINDOWS and sys.stdin.isatty():
                            tty.setcbreak(sys.stdin.fileno())

                    sim.step()

            except KeyboardInterrupt:
                if old_settings:
                    termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)
                print("\n[INTERRUPT] Pausing execution into debugger.")
                sim.interactive_cli()

    finally:
        if old_settings:
            termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)


if __name__ == "__main__":
    main()



# === Lean-Core I/D-Cache & SDRAM Burst/Write-Behind Model ===
class DirectMappedCache:
    """Direct-mapped cache line model with burst refill and write-behind support."""
    def __init__(self, num_lines: int = 32, line_words: int = 8, write_back: bool = True):
        assert num_lines > 0 and (num_lines & (num_lines - 1)) == 0, "num_lines must be power of 2"
        assert line_words > 0 and (line_words & (line_words - 1)) == 0, "line_words must be power of 2"
        self.num_lines = num_lines
        self.line_words = line_words
        self.write_back = write_back
        # Each entry: dict(tag=int|None, valid=bool, dirty=bool, words=list[int])
        self.lines = [
            {"tag": None, "valid": False, "dirty": False, "words": [0] * line_words}
            for _ in range(num_lines)
        ]
        self.hits = 0
        self.misses = 0
        self.writebacks = 0

    def _split_addr(self, word_addr: int):
        offset = word_addr & (self.line_words - 1)
        idx_mask = self.num_lines - 1
        index = (word_addr >> self.line_words.bit_length() - 1) & idx_mask
        tag = word_addr >> ((self.line_words.bit_length() - 1) + (self.num_lines.bit_length() - 1))
        return tag, index, offset

    def lookup(self, word_addr: int):
        tag, index, offset = self._split_addr(word_addr)
        line = self.lines[index]
        if line["valid"] and line["tag"] == tag:
            self.hits += 1
            return True, index, offset, line["words"][offset]
        self.misses += 1
        return False, index, offset, 0

    def fill_line(self, word_addr: int, burst_words: list[int]):
        tag, index, _ = self._split_addr(word_addr)
        line = self.lines[index]
        evicted = None
        if line["valid"] and line["dirty"] and self.write_back:
            base_addr = ((line["tag"] << ((self.line_words.bit_length() - 1) + (self.num_lines.bit_length() - 1)))
                         | (index << (self.line_words.bit_length() - 1)))
            evicted = (base_addr, list(line["words"]))
            self.writebacks += 1
        padded = list(burst_words[:self.line_words])
        if len(padded) < self.line_words:
            padded.extend([0] * (self.line_words - len(padded)))
        line["tag"] = tag
        line["valid"] = True
        line["dirty"] = False
        line["words"] = padded
        return evicted

    def write_word(self, word_addr: int, val: int) -> bool:
        """Returns True if hit in cache and updated locally; False if miss."""
        tag, index, offset = self._split_addr(word_addr)
        line = self.lines[index]
        if line["valid"] and line["tag"] == tag:
            self.hits += 1
            line["words"][offset] = val & WORD_MASK
            line["dirty"] = True
            return True
        self.misses += 1
        return False

class SdramCacheSubsystem:
    """Models lean local RAM + I/D caches + SDRAM burst reads + write-behind queue."""
    def __init__(self, local_words: int = 2048, sdram_words: int = 16 * 1024 * 1024,
                 line_words: int = 8, i_lines: int = 32, d_lines: int = 32,
                 write_behind_depth: int = 16, act_cycles: int = 2,
                 cas_cycles: int = 2, pre_cycles: int = 2, refresh_interval: int = 374):
        assert 1 <= local_words <= 65536, "Core memory capped at 64K words (128K bytes)"
        self.local_words = local_words
        self.sdram = [0] * min(sdram_words, 262144)  # backing store (capped array for fast sim)
        self._sdram_full_words = sdram_words
        self.line_words = line_words
        self.icache = DirectMappedCache(num_lines=i_lines, line_words=line_words, write_back=False)
        self.dcache = DirectMappedCache(num_lines=d_lines, line_words=line_words, write_back=True)

        # Write-behind queue entries: (sdram_word_addr, val16)
        self.write_behind = deque()
        self.write_behind_depth = write_behind_depth

        # SDRAM timing parameters (in system/controller cycles)
        self.act_cycles = act_cycles
        self.cas_cycles = cas_cycles
        self.pre_cycles = pre_cycles
        self.refresh_interval = refresh_interval
        self._refresh_countdown = refresh_interval
        self._busy_cycles = 0
        self.total_cycles = 0
        self.sdram_burst_reads = 0
        self.sdram_writes = 0
        self.sdram_refreshes = 0

    def _sdram_idx(self, addr: int) -> int:
        return addr % len(self.sdram)

    def _burst_read_cycles(self) -> int:
        # ACT + CAS + 1 cycle/word burst streaming + PRE
        return self.act_cycles + self.cas_cycles + self.line_words + self.pre_cycles

    def _single_write_cycles(self) -> int:
        return self.act_cycles + 1 + self.pre_cycles

    def tick(self, n: int = 1):
        for _ in range(n):
            self.total_cycles += 1
            if self._busy_cycles > 0:
                self._busy_cycles -= 1
            self._refresh_countdown -= 1
            if self._refresh_countdown <= 0:
                self._refresh_countdown = self.refresh_interval
                self.sdram_refreshes += 1
                self._busy_cycles += (self.pre_cycles + self.act_cycles)
            # Drain one write-behind item when SDRAM is idle and no miss is active
            if self._busy_cycles == 0 and self.write_behind:
                w_addr, w_val = self.write_behind.popleft()
                self.sdram[self._sdram_idx(w_addr)] = w_val & WORD_MASK
                self.sdram_writes += 1
                self._busy_cycles += self._single_write_cycles()

    def fetch_inst_word(self, word_addr: int) -> tuple[int, int]:
        """Returns (word16, latency_cycles) via I-Cache with SDRAM burst refill on miss."""
        hit, _, _, val = self.icache.lookup(word_addr)
        if hit:
            self.tick(1)
            return val, 1
        base = word_addr & ~(self.line_words - 1)
        burst = [self.sdram[self._sdram_idx(base + i)] for i in range(self.line_words)]
        self.icache.fill_line(word_addr, burst)
        lat = self._burst_read_cycles()
        self.sdram_burst_reads += 1
        self.tick(lat)
        _, _, _, val_after = self.icache.lookup(word_addr)
        self.icache.hits -= 1  # don't double-count fill lookup as hit
        return val_after, lat

    def read_data_word(self, word_addr: int) -> tuple[int, int]:
        """Returns (word16, latency_cycles) via D-Cache (with write-behind forwarding)."""
        # Check write-behind queue for matching address (RAW hazard forwarding)
        for w_addr, w_val in reversed(self.write_behind):
            if w_addr == word_addr:
                self.tick(1)
                return w_val, 1

        hit, _, _, val = self.dcache.lookup(word_addr)
        if hit:
            self.tick(1)
            return val, 1

        base = word_addr & ~(self.line_words - 1)
        burst = [self.sdram[self._sdram_idx(base + i)] for i in range(self.line_words)]
        evicted = self.dcache.fill_line(word_addr, burst)
        lat = self._burst_read_cycles()
        self.sdram_burst_reads += 1
        if evicted is not None:
            ev_base, ev_words = evicted
            for idx_w, ew in enumerate(ev_words):
                self.write_behind.append((ev_base + idx_w, ew))
            lat += self.pre_cycles
        self.tick(lat)
        _, _, _, val_after = self.dcache.lookup(word_addr)
        self.dcache.hits -= 1
        return val_after, lat

    def write_data_word(self, word_addr: int, val: int) -> tuple[bool, int]:
        """Writes to D-Cache if hit; enqueues write-behind if queue has room. Returns (hit, lat)."""
        hit = self.dcache.write_word(word_addr, val)
        if not hit:
            # Allocate line via burst read, apply write, and enqueue write-behind if space allows
            base = word_addr & ~(self.line_words - 1)
            burst = [self.sdram[self._sdram_idx(base + i)] for i in range(self.line_words)]
            self.dcache.fill_line(word_addr, burst)
            self.dcache.write_word(word_addr, val)
            self.dcache.hits -= 1
            if len(self.write_behind) < self.write_behind_depth:
                self.write_behind.append((word_addr, val & WORD_MASK))
            lat = self._burst_read_cycles()
            self.sdram_burst_reads += 1
            self.tick(lat)
            return False, lat

        # Queue write-behind entry if not full (keeps core moving without waiting for SDRAM write)
        if len(self.write_behind) < self.write_behind_depth:
            self.write_behind.append((word_addr, val & WORD_MASK))
            self.tick(1)
            return True, 1

        # If write-behind queue is full, drain one entry first
        w_addr, w_val = self.write_behind.popleft()
        self.sdram[self._sdram_idx(w_addr)] = w_val
        self.sdram_writes += 1
        self.write_behind.append((word_addr, val & WORD_MASK))
        lat = self._single_write_cycles()
        self.tick(lat)
        return True, lat

# === SdramCacheSubsystem Integration ===


# === Multi-Client NoC Cache/Memory Service ===
# Simple 16-bit request encoding over DATA channel:
#   bits [15:14]: op (0 = READ, 1 = WRITE)
#   bits [13:0] : 14-bit word address offset (added to base_addr)
MEM_REQ_OP_READ  = 0
MEM_REQ_OP_WRITE = 1

def encode_mem_req(op: int, addr_offset: int) -> int:
    return ((op & 0x3) << 14) | (addr_offset & 0x3FFF)

def decode_mem_req(word: int) -> tuple[int, int]:
    return (word >> 14) & 0x3, word & 0x3FFF

class NocCacheServer:
    """Service loop/step helper on a server core that handles NoC memory/cache requests."""
    def __init__(self, cluster: NocCluster, server_core_id: int, req_ch: int,
                 sdram_cache: SdramCacheSubsystem, base_addr: int = 0x4000,
                 notify_mbox_ch: int | None = None):
        self.cluster = cluster
        self.server_core_id = server_core_id
        self.req_ch = req_ch
        self.sdram_cache = sdram_cache
        self.base_addr = base_addr & ADDR_MASK
        self.notify_mbox_ch = notify_mbox_ch
        self.served_reads = 0
        self.served_writes = 0
        self._pending_write_addr: int | None = None
        self._pending_write_offset: int = 0
        self._pending_write_src: tuple[int, int] | None = None

    def _emit_mbox_notify(self, ni: CoreNetworkInterface, req_src_core: int, req_src_ch: int, payload: int):
        if self.notify_mbox_ch is not None:
            m_core, m_ch, m_valid = ni.channel_table[self.notify_mbox_ch % ni.num_ch]
            if m_valid:
                ni.mbox_outbox.append(
                    NocPacket(1, self.server_core_id, self.notify_mbox_ch, m_core, m_ch, payload & WORD_MASK)
                )
                return
        # Fallback: send priority MBOX directly back to requesting core/ch
        ni.mbox_outbox.append(
            NocPacket(1, self.server_core_id, self.req_ch, req_src_core, req_src_ch, payload & WORD_MASK)
        )

    def poll_once(self) -> bool:
        """Process one request from req_ch or one write data word if awaiting write payload."""
        ni = self.cluster.nis[self.server_core_id]
        if self._pending_write_addr is not None:
            if not ni.rx_fifos[self.req_ch]:
                return False
            wdata = ni.rx_fifos[self.req_ch].popleft()
            if hasattr(ni, "_rx_meta") and ni._rx_meta[self.req_ch]:
                ni._rx_meta[self.req_ch].popleft()
            self.sdram_cache.write_data_word(self._pending_write_addr, wdata)
            w_offset = self._pending_write_offset
            w_src = self._pending_write_src or (0, self.req_ch % ni.num_ch)
            self._pending_write_addr = None
            self._pending_write_offset = 0
            self._pending_write_src = None
            self.served_writes += 1
            self._emit_mbox_notify(ni, w_src[0], w_src[1], 0x8000 | (w_offset & 0x3FFF))
            return True

        if not ni.rx_fifos[self.req_ch]:
            return False

        req_word = ni.rx_fifos[self.req_ch].popleft()
        req_src_core, req_src_ch = 0, self.req_ch % ni.num_ch
        if hasattr(ni, "_rx_meta") and ni._rx_meta[self.req_ch]:
            req_src_core, req_src_ch = ni._rx_meta[self.req_ch].popleft()
        op, offset = decode_mem_req(req_word)
        target_addr = (self.base_addr + offset) & ADDR_MASK
        # Route reply via channel_table if configured for req_ch, else back to requester's (src_core, src_ch)
        dst_core, dst_ch, valid = ni.channel_table[self.req_ch % ni.num_ch]
        if not valid:
            dst_core, dst_ch = req_src_core, req_src_ch

        if op == MEM_REQ_OP_READ:
            val, _ = self.sdram_cache.read_data_word(target_addr)
            # Push response word into server's tx_outbox using configured route
            self.cluster.nis[self.server_core_id].tx_outbox.append(
                NocPacket(0, self.server_core_id, self.req_ch, dst_core, dst_ch, val)
            )
            self.served_reads += 1
            self._emit_mbox_notify(ni, req_src_core, req_src_ch, val)
            return True

        elif op == MEM_REQ_OP_WRITE:
            self._pending_write_addr = target_addr
            self._pending_write_offset = offset
            self._pending_write_src = (req_src_core, req_src_ch)
            return True

        return False

class NocCacheClient:
    """Helper for a client core issuing cached SDRAM read/write requests over the NoC."""
    def __init__(self, cluster: NocCluster, client_core_id: int, tx_ch: int, rx_ch: int):
        self.cluster = cluster
        self.client_core_id = client_core_id
        self.tx_ch = tx_ch
        self.rx_ch = rx_ch

    def issue_write(self, addr_offset: int, val: int):
        ni = self.cluster.nis[self.client_core_id]
        ni.send_data(encode_mem_req(MEM_REQ_OP_WRITE, addr_offset), ch=self.tx_ch)
        ni.send_data(val & WORD_MASK, ch=self.tx_ch)

    def issue_read(self, addr_offset: int):
        ni = self.cluster.nis[self.client_core_id]
        ni.send_data(encode_mem_req(MEM_REQ_OP_READ, addr_offset), ch=self.tx_ch)

    def try_recv_read_data(self) -> int | None:
        q = self.cluster.nis[self.client_core_id].rx_fifos[self.rx_ch]
        return q.popleft() if q else None
