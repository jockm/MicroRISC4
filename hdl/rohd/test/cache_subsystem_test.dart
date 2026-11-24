import 'dart:async';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:minirisc4_rohd/cache_controllers.dart';
import 'package:minirisc4_rohd/cache_subsystem_top.dart';
import 'package:minirisc4_rohd/cpu_config.dart';
import 'package:minirisc4_rohd/ulx3s_top.dart';
import 'sdram_controller_test.dart' show JedecSdramSimModel;

void main() {
  group('BRAM ICache & Write-Back DCache Tests', () {
    setUp(() async {
      await Simulator.reset();
    });

    test('ICache cold miss, line hits, coreId partition, single-line invalidate, and flushAll', () async {
      const coreId = 3;
      const numLines = 64;
      const lineWords = 8;

      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final reqValid = Logic(name: 'req_valid');
      final reqAddr = Logic(name: 'req_addr', width: 16);
      final memCmdReady = Logic(name: 'mem_cmd_ready');
      final memRdata = Logic(name: 'mem_rdata', width: 16);
      final memRdataValid = Logic(name: 'mem_rdata_valid');
      final flushAll = Logic(name: 'flush_all');
      final invalValid = Logic(name: 'inval_valid');
      final invalAddr = Logic(name: 'inval_addr', width: 16);

      final dut = ICache(
        clk: clk,
        reset: reset,
        reqValid: reqValid,
        reqAddr: reqAddr,
        memCmdReady: memCmdReady,
        memRdata: memRdata,
        memRdataValid: memRdataValid,
        flushAll: flushAll,
        invalValid: invalValid,
        invalAddr: invalAddr,
        coreId: coreId,
        numLines: numLines,
        lineWords: lineWords,
      );
      await dut.build();

      // Simulated 24-bit SDRAM backing store
      final sdram = <int, int>{};
      for (var w = 0; w < 16; w++) {
        sdram[(coreId << 16) | (0x0400 + w)] = 0xA000 + w;
        sdram[(coreId << 16) | (0x0800 + w)] = 0xB000 + w;
      }

      reset.put(1);
      reqValid.put(0);
      reqAddr.put(0);
      memCmdReady.put(1);
      memRdata.put(0);
      memRdataValid.put(0);
      flushAll.put(0);
      invalValid.put(0);
      invalAddr.put(0);

      Simulator.setMaxSimTime(5000);
      unawaited(Simulator.run());

      Future<void> step() async {
        await clk.nextPosedge;
        await clk.nextNegedge;
      }

      var burstCount = 0;
      Future<(int, bool)> fetchWord(int addr) async {
        expect(dut.output('req_ready').value.toInt(), equals(1));
        reqAddr.put(addr);
        reqValid.put(1);
        await step();
        reqValid.put(0);

        for (var cyc = 0; cyc < 40; cyc++) {
          if (dut.output('resp_valid').value.toInt() == 1) {
            return (
              dut.output('resp_data').value.toInt(),
              dut.output('resp_hit').value.toInt() == 1,
            );
          }
          if (dut.output('mem_cmd_req').value.toInt() == 1) {
            expect(dut.output('mem_cmd_rw').value.toInt(), equals(0));
            final base24 = dut.output('mem_cmd_addr').value.toInt();
            final burstLen = dut.output('mem_cmd_burst_len').value.toInt();
            expect(base24 >> 16, equals(coreId));
            expect(burstLen, equals(lineWords));
            burstCount++;
            await step(); // accept cmd
            // Stream burst with 1 wait state in the middle
            for (var b = 0; b < burstLen; b++) {
              if (b == 3) {
                memRdataValid.put(0);
                await step();
              }
              memRdata.put(sdram[base24 + b] ?? 0);
              memRdataValid.put(1);
              await step();
            }
            memRdataValid.put(0);
            expect(dut.output('resp_valid').value.toInt(), equals(1));
            return (
              dut.output('resp_data').value.toInt(),
              dut.output('resp_hit').value.toInt() == 1,
            );
          }
          await step();
        }
        fail('ICache fetch timed out for 0x${addr.toRadixString(16)}');
      }

      await step();
      await step();
      reset.put(0);
      await step();

      // 1. Cold miss at 0x0405 -> refills line 0x0400..0x0407 from coreId=3 partition
      final (v0, h0) = await fetchWord(0x0405);
      expect(v0, equals(0xA005));
      expect(h0, isFalse);
      expect(burstCount, equals(1));

      // 2. All 8 words in line 0x0400..0x0407 must now HIT with 0 extra bursts
      for (var off = 0; off < lineWords; off++) {
        final (v, h) = await fetchWord(0x0400 + off);
        expect(v, equals(0xA000 + off));
        expect(h, isTrue);
      }
      expect(burstCount, equals(1));

      // 3. Also load second line at 0x0408..0x040F
      final (v1, h1) = await fetchWord(0x040A);
      expect(v1, equals(0xA00A));
      expect(h1, isFalse);
      expect(burstCount, equals(2));

      // 4. Modify SDRAM[0x030405] and invalidate ONLY line 0x0400 (self-modifying code)
      sdram[(coreId << 16) | 0x0405] = 0xCAFE;
      invalAddr.put(0x0405);
      invalValid.put(1);
      await step();
      invalValid.put(0);

      // Line 0x0408 must STILL hit, while 0x0405 misses and fetches updated 0xCAFE
      final (vStillHit, hStillHit) = await fetchWord(0x040A);
      expect(vStillHit, equals(0xA00A));
      expect(hStillHit, isTrue);

      final (vNew, hNew) = await fetchWord(0x0405);
      expect(vNew, equals(0xCAFE));
      expect(hNew, isFalse);
      expect(burstCount, equals(3));

      // 5. flushAll clears every valid line in 1 cycle
      flushAll.put(1);
      await step();
      flushAll.put(0);
      final (vFlushed, hFlushed) = await fetchWord(0x040A);
      expect(vFlushed, equals(0xA00A));
      expect(hFlushed, isFalse);
      expect(burstCount, equals(4));

      Simulator.endSimulation();
      await Simulator.simulationEnded;
    });

    test('DCache read/write hits, write-allocate miss, dirty writeback eviction, and non-overlapping per-core SDRAM', () async {
      const numLines = 32; // 32 lines x 8 words = 256 words (index wraps every 0x0100)
      const lineWords = 8;

      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');

      // Core 0 and Core 2 DCaches sharing one 24-bit SDRAM pool
      final c0Valid = Logic(name: 'c0_valid');
      final c0We = Logic(name: 'c0_we');
      final c0Addr = Logic(name: 'c0_addr', width: 16);
      final c0Wdata = Logic(name: 'c0_wdata', width: 16);
      final c0CmdRdy = Logic(name: 'c0_cmd_rdy');
      final c0Rdata = Logic(name: 'c0_rdata', width: 16);
      final c0Rvalid = Logic(name: 'c0_rvalid');
      final c0Wrdy = Logic(name: 'c0_wrdy');

      final c2Valid = Logic(name: 'c2_valid');
      final c2We = Logic(name: 'c2_we');
      final c2Addr = Logic(name: 'c2_addr', width: 16);
      final c2Wdata = Logic(name: 'c2_wdata', width: 16);
      final c2CmdRdy = Logic(name: 'c2_cmd_rdy');
      final c2Rdata = Logic(name: 'c2_rdata', width: 16);
      final c2Rvalid = Logic(name: 'c2_rvalid');
      final c2Wrdy = Logic(name: 'c2_wrdy');

      final dc0 = DCache(
        clk: clk,
        reset: reset,
        reqValid: c0Valid,
        reqWe: c0We,
        reqAddr: c0Addr,
        reqWdata: c0Wdata,
        memCmdReady: c0CmdRdy,
        memRdata: c0Rdata,
        memRdataValid: c0Rvalid,
        memWdataReady: c0Wrdy,
        coreId: 0,
        numLines: numLines,
        lineWords: lineWords,
        name: 'dcache_0',
      );
      final dc2 = DCache(
        clk: clk,
        reset: reset,
        reqValid: c2Valid,
        reqWe: c2We,
        reqAddr: c2Addr,
        reqWdata: c2Wdata,
        memCmdReady: c2CmdRdy,
        memRdata: c2Rdata,
        memRdataValid: c2Rvalid,
        memWdataReady: c2Wrdy,
        coreId: 2,
        numLines: numLines,
        lineWords: lineWords,
        name: 'dcache_2',
      );
      await dc0.build();
      await dc2.build();

      // Shared 24-bit SDRAM array: Core 0 at 0x00xxxx, Core 2 at 0x02xxxx
      final sdram = <int, int>{};
      for (var w = 0; w < 8; w++) {
        sdram[(0 << 16) | (0x1000 + w)] = 0x1000 + w; // Line A (index 0, tag 0x10)
        sdram[(0 << 16) | (0x2000 + w)] = 0x2000 + w; // Line B (same index 0, tag 0x20 -> evicts A!)
        sdram[(0 << 16) | (0x3010 + w)] = 0x3010 + w; // Line C (write-allocate miss test)
        sdram[(2 << 16) | (0x1000 + w)] = 0x9000 + w; // Core 2 same local addr 0x1000!
      }

      reset.put(1);
      for (final l in [c0Valid, c0We, c0Addr, c0Wdata, c0Rdata, c0Rvalid, c0Wrdy,
                       c2Valid, c2We, c2Addr, c2Wdata, c2Rdata, c2Rvalid, c2Wrdy]) {
        l.put(0);
      }
      c0CmdRdy.put(1);
      c2CmdRdy.put(1);

      Simulator.setMaxSimTime(8000);
      unawaited(Simulator.run());

      Future<void> step() async {
        await clk.nextPosedge;
        await clk.nextNegedge;
      }

      var wbCount = 0;
      var refillCount = 0;

      Future<(int, bool)> access(
        DCache dc,
        Logic v,
        Logic we,
        Logic addr,
        Logic wdata,
        Logic rdata,
        Logic rvalid,
        Logic wrdy,
        int a, {
        bool isWrite = false,
        int val = 0,
      }) async {
        expect(dc.output('req_ready').value.toInt(), equals(1));
        addr.put(a);
        we.put(isWrite ? 1 : 0);
        wdata.put(val);
        v.put(1);
        await step();
        v.put(0);

        for (var cyc = 0; cyc < 80; cyc++) {
          if (dc.output('resp_valid').value.toInt() == 1) {
            return (
              dc.output('resp_data').value.toInt(),
              dc.output('resp_hit').value.toInt() == 1,
            );
          }
          if (dc.output('mem_cmd_req').value.toInt() == 1) {
            final rw = dc.output('mem_cmd_rw').value.toInt();
            final base24 = dc.output('mem_cmd_addr').value.toInt();
            final burstLen = dc.output('mem_cmd_burst_len').value.toInt();
            expect(burstLen, equals(lineWords));
            await step(); // accept cmd
            if (rw == 1) {
              // Writeback burst with 1 stall cycle on beat 4 to test backpressure
              wbCount++;
              for (var b = 0; b < burstLen; b++) {
                if (b == 4) {
                  wrdy.put(0);
                  await step();
                }
                expect(dc.output('mem_wdata_valid').value.toInt(), equals(1));
                sdram[base24 + b] = dc.output('mem_wdata').value.toInt();
                wrdy.put(1);
                await step();
              }
              wrdy.put(0);
            } else {
              // Refill read burst
              refillCount++;
              for (var b = 0; b < burstLen; b++) {
                rdata.put(sdram[base24 + b] ?? 0);
                rvalid.put(1);
                await step();
              }
              rvalid.put(0);
            }
          } else {
            await step();
          }
        }
        fail('DCache access timed out at 0x${a.toRadixString(16)}');
      }

      await step();
      await step();
      reset.put(0);
      await step();

      // 1. Core 0 cold read miss at 0x1003
      final (r0, h0) = await access(dc0, c0Valid, c0We, c0Addr, c0Wdata, c0Rdata, c0Rvalid, c0Wrdy, 0x1003);
      expect(r0, equals(0x1003));
      expect(h0, isFalse);
      expect(refillCount, equals(1));
      expect(wbCount, equals(0));

      // 2. Core 0 write hit at 0x1003 = 0xDEAD (write-back -> SDRAM NOT updated yet!)
      final (_, h1) = await access(dc0, c0Valid, c0We, c0Addr, c0Wdata, c0Rdata, c0Rvalid, c0Wrdy, 0x1003,
          isWrite: true, val: 0xDEAD);
      expect(h1, isTrue);
      expect(sdram[(0 << 16) | 0x1003], equals(0x1003)); // still old value in SDRAM

      // Also write hit at 0x1007 = 0xBEEF
      final (_, h2) = await access(dc0, c0Valid, c0We, c0Addr, c0Wdata, c0Rdata, c0Rvalid, c0Wrdy, 0x1007,
          isWrite: true, val: 0xBEEF);
      expect(h2, isTrue);

      // Verify read hit sees 0xDEAD
      final (rDead, hDead) = await access(dc0, c0Valid, c0We, c0Addr, c0Wdata, c0Rdata, c0Rvalid, c0Wrdy, 0x1003);
      expect(rDead, equals(0xDEAD));
      expect(hDead, isTrue);

      // 3. Conflict miss on Core 0 at 0x2002 (same index 0, different tag!)
      //    Must evict & burst-writeback dirty line 0x001000..0x001007 to SDRAM, then refill 0x002000!
      final (rB, hB) = await access(dc0, c0Valid, c0We, c0Addr, c0Wdata, c0Rdata, c0Rvalid, c0Wrdy, 0x2002);
      expect(rB, equals(0x2002));
      expect(hB, isFalse);
      expect(wbCount, equals(1));
      expect(refillCount, equals(2));

      // Verify ALL 8 words of evicted dirty line landed accurately in Core 0's SDRAM partition!
      expect(sdram[(0 << 16) | 0x1000], equals(0x1000));
      expect(sdram[(0 << 16) | 0x1001], equals(0x1001));
      expect(sdram[(0 << 16) | 0x1002], equals(0x1002));
      expect(sdram[(0 << 16) | 0x1003], equals(0xDEAD));
      expect(sdram[(0 << 16) | 0x1004], equals(0x1004));
      expect(sdram[(0 << 16) | 0x1005], equals(0x1005));
      expect(sdram[(0 << 16) | 0x1006], equals(0x1006));
      expect(sdram[(0 << 16) | 0x1007], equals(0xBEEF));

      // 4. Core 2 accesses the EXACT same local address 0x1003 -> gets its own private 0x9003!
      final (rC2, hC2) = await access(dc2, c2Valid, c2We, c2Addr, c2Wdata, c2Rdata, c2Rvalid, c2Wrdy, 0x1003);
      expect(rC2, equals(0x9003));
      expect(hC2, isFalse);
      // Core 2 modifies its own 0x1003 = 0x5555 -> zero overlap with Core 0's 0xDEAD!
      await access(dc2, c2Valid, c2We, c2Addr, c2Wdata, c2Rdata, c2Rvalid, c2Wrdy, 0x1003,
          isWrite: true, val: 0x5555);
      expect(sdram[(0 << 16) | 0x1003], equals(0xDEAD));

      // 5. Write-allocate miss on Core 0 at 0x3014 = 0x7777 (merges during refill!)
      final (_, hWa) = await access(dc0, c0Valid, c0We, c0Addr, c0Wdata, c0Rdata, c0Rvalid, c0Wrdy, 0x3014,
          isWrite: true, val: 0x7777);
      expect(hWa, isFalse);
      final (rWa4, hWa4) = await access(dc0, c0Valid, c0We, c0Addr, c0Wdata, c0Rdata, c0Rvalid, c0Wrdy, 0x3014);
      final (rWa5, hWa5) = await access(dc0, c0Valid, c0We, c0Addr, c0Wdata, c0Rdata, c0Rvalid, c0Wrdy, 0x3015);
      expect(rWa4, equals(0x7777));
      expect(hWa4, isTrue);
      expect(rWa5, equals(0x3015)); // neighbor word preserved from refill!
      expect(hWa5, isTrue);

      Simulator.endSimulation();
      await Simulator.simulationEnded;
    });

    test('SdramCacheCluster 2-core I/D caches + round-robin arbiter + pin-level JEDEC SDRAM', () async {
      const numCores = 2;
      const numLines = 32;
      const lineWords = 8;

      final clk = SimpleClockGenerator(10).clk;
      final rstN = Logic(name: 'rst_n');
      final icV = List.generate(numCores, (i) => Logic(name: 'ic_v_$i'));
      final icA = List.generate(numCores, (i) => Logic(name: 'ic_a_$i', width: 16));
      final dcV = List.generate(numCores, (i) => Logic(name: 'dc_v_$i'));
      final dcWe = List.generate(numCores, (i) => Logic(name: 'dc_we_$i'));
      final dcA = List.generate(numCores, (i) => Logic(name: 'dc_a_$i', width: 16));
      final dcW = List.generate(numCores, (i) => Logic(name: 'dc_w_$i', width: 16));
      final sdramDqIn = Logic(name: 'sdram_dq_in', width: 16);

      final cluster = SdramCacheCluster(
        clk: clk,
        rstN: rstN,
        icReqValid: icV,
        icReqAddr: icA,
        dcReqValid: dcV,
        dcReqWe: dcWe,
        dcReqAddr: dcA,
        dcReqWdata: dcW,
        sdramDqIn: sdramDqIn,
        numCores: numCores,
        numLines: numLines,
        lineWords: lineWords,
        clkFreqMhz: 48,
        casLatency: 2,
        initWaitCycles: 10,
        refreshCycles: 200,
      );
      await cluster.build();

      // Pre-populate non-overlapping 64K-word SDRAM partitions for Core 0 & Core 1
      final sdramModel = JedecSdramSimModel()..attach(clk, cluster, sdramDqIn);
      for (var w = 0; w < 8; w++) {
        sdramModel.mem[(0 << 16) | (0x0100 + w)] = 0x1000 + w; // Core 0 code
        sdramModel.mem[(0 << 16) | (0x1000 + w)] = 0x2000 + w; // Core 0 data A
        sdramModel.mem[(0 << 16) | (0x2000 + w)] = 0x3000 + w; // Core 0 data B (evicts A)
        sdramModel.mem[(1 << 16) | (0x0100 + w)] = 0x5000 + w; // Core 1 code (same local addr!)
        sdramModel.mem[(1 << 16) | (0x1000 + w)] = 0x6000 + w; // Core 1 data A (same local addr!)
      }

      rstN.put(0);
      for (var c = 0; c < numCores; c++) {
        icV[c].put(0);
        icA[c].put(0);
        dcV[c].put(0);
        dcWe[c].put(0);
        dcA[c].put(0);
        dcW[c].put(0);
      }

      Simulator.setMaxSimTime(15000);
      unawaited(Simulator.run());

      Future<void> step() async {
        await clk.nextPosedge;
        await clk.nextNegedge;
      }

      await step();
      await step();
      rstN.put(1);

      // Issue simultaneous cold misses from BOTH Core 0 (I+D) AND Core 1 (I+D)
      // while SDRAM is still initializing — round-robin arbiter must serialize all 4 cleanly!
      icA[0].put(0x0103); icV[0].put(1);
      dcA[0].put(0x1002); dcWe[0].put(0); dcV[0].put(1);
      icA[1].put(0x0105); icV[1].put(1);
      dcA[1].put(0x1004); dcWe[1].put(0); dcV[1].put(1);
      await step();
      icV[0].put(0); dcV[0].put(0); icV[1].put(0); dcV[1].put(0);

      int? rIc0, rDc0, rIc1, rDc1;
      for (var cyc = 0; cyc < 300 && (rIc0 == null || rDc0 == null || rIc1 == null || rDc1 == null); cyc++) {
        if (cluster.output('ic_resp_valid_0').value.toInt() == 1) rIc0 = cluster.output('ic_resp_data_0').value.toInt();
        if (cluster.output('dc_resp_valid_0').value.toInt() == 1) rDc0 = cluster.output('dc_resp_data_0').value.toInt();
        if (cluster.output('ic_resp_valid_1').value.toInt() == 1) rIc1 = cluster.output('ic_resp_data_1').value.toInt();
        if (cluster.output('dc_resp_valid_1').value.toInt() == 1) rDc1 = cluster.output('dc_resp_data_1').value.toInt();
        await step();
      }
      expect(rIc0, equals(0x1003));
      expect(rDc0, equals(0x2002));
      expect(rIc1, equals(0x5005));
      expect(rDc1, equals(0x6004));

      // Core 0 writes 0xCAFE to 0x1002 (dirty hit), then reads 0x2001 (evicts dirty 0x1000 to real SDRAM!)
      dcA[0].put(0x1002); dcWe[0].put(1); dcW[0].put(0xCAFE); dcV[0].put(1);
      await step();
      dcV[0].put(0);
      await step();
      expect(cluster.output('dc_resp_valid_0').value.toInt(), equals(1));
      expect(cluster.output('dc_resp_hit_0').value.toInt(), equals(1));
      await step();

      dcA[0].put(0x2001); dcWe[0].put(0); dcV[0].put(1);
      await step();
      dcV[0].put(0);
      int? rEvict;
      for (var cyc = 0; cyc < 150 && rEvict == null; cyc++) {
        if (cluster.output('dc_resp_valid_0').value.toInt() == 1) {
          rEvict = cluster.output('dc_resp_data_0').value.toInt();
        }
        await step();
      }
      expect(rEvict, equals(0x3001));

      // Verify dirty line landed in Core 0's SDRAM partition (0x001002) while Core 1's (0x011002) is untouched!
      expect(sdramModel.mem[(0 << 16) | 0x1002], equals(0xCAFE));
      expect(sdramModel.mem[(0 << 16) | 0x1007], equals(0x2007));
      expect(sdramModel.mem[(1 << 16) | 0x1002], equals(0x6002));

      // Verify self-modifying code coherency: Core 0 D-write to 0x0103 invalidates Core 0 I-Cache line!
      dcA[0].put(0x0103); dcWe[0].put(1); dcW[0].put(0xBEEF); dcV[0].put(1);
      await step();
      dcV[0].put(0);
      for (var cyc = 0; cyc < 80 && cluster.output('dc_resp_valid_0').value.toInt() == 0; cyc++) {
        await step();
      }
      await step();
      // Now Core 0 I-Cache fetch of 0x0103 must MISS, snoop-writeback DCache's
      // dirty line to SDRAM, and return the freshly written 0xBEEF!
      icA[0].put(0x0103); icV[0].put(1);
      await step();
      icV[0].put(0);
      int? hitAfterInval;
      int? dataAfterInval;
      for (var cyc = 0; cyc < 160 && hitAfterInval == null; cyc++) {
        if (cluster.output('ic_resp_valid_0').value.toInt() == 1) {
          hitAfterInval = cluster.output('ic_resp_hit_0').value.toInt();
          dataAfterInval = cluster.output('ic_resp_data_0').value.toInt();
        }
        await step();
      }
      expect(hitAfterInval, equals(0));
      expect(dataAfterInval, equals(0xBEEF));
      expect(sdramModel.mem[(0 << 16) | 0x0103], equals(0xBEEF));

      Simulator.endSimulation();
      await Simulator.simulationEnded;
    });

    test('Live Ulx3sTop (2K local BRAM + I/D Cache + SDRAM): stack, dirty eviction, and SDRAM code execution', () async {
      // MiniRISC4 encoding helpers
      int ldReg(int rr, int rl) => (0x0 << 4) | (rr << 2) | rl;
      int ldi4(int imm) => (0x1 << 4) | (imm & 0xF);
      int peek(int rr, int rl) => (0x2 << 4) | (rr << 2) | rl;
      int poke(int rr, int rl) => (0x3 << 4) | (rr << 2) | rl;
      int pop(int rr, int rl) => (0x4 << 4) | (rr << 2) | rl;
      int push(int rr, int rl) => (0x5 << 4) | (rr << 2) | rl;
      int add(int rr, int rl) => (0x6 << 4) | (rr << 2) | rl;
      int jmp(int rl) => (0xF << 4) | (0x0 << 2) | rl;
      int push8(int rl, int imm8) =>
          ((imm8 & 0xFF) << 8) | (0xF << 4) | (0x2 << 2) | rl;
      int pack(int b0, int b1) => ((b1 & 0xFF) << 8) | (b0 & 0xFF);
      List<int> load16(int reg, int val) => [
            push8(reg, (val >> 8) & 0xFF),
            push8(reg, val & 0xFF),
          ];

      // Build SDRAM subroutine words to be written by CPU into SDRAM @ 0x5000:
      //   0x5000: LDI4 R0, 0xA ; LD R1, R0
      //   0x5001: LDI4 R0, 0x5 ; ADD R0, R1  (R0 = 0x000F)
      //   0x5002..3: R2 = 0x0202 (local BRAM result slot)
      //   0x5004: LD (R2), R0 ; NOP (LD R0, R0)
      //   0x5005..6: R2 = 0x0180 (return to local BRAM done loop)
      //   0x5007: JMP R2 ; NOP
      final sdramCode = <int>[
        pack(ldi4(0xA), ldReg(1, 0)),
        pack(ldi4(0x5), add(0, 1)),
        ...load16(2, 0x0202),
        pack(poke(2, 0), ldReg(0, 0)),
        ...load16(2, 0x0180),
        pack(jmp(2), ldReg(0, 0)),
      ];

      // Local 2K BRAM program starting at reset vector 0x0100:
      final mem = <int, int>{};
      var addr = 0x0100;
      void emit(List<int> words) {
        for (final w in words) {
          mem[addr++] = w;
        }
      }

      // 1. Test SDRAM stack: R3 = 0xFF00; PUSH 0xCAFE; POP -> R1; store to local 0x0200
      emit(load16(3, 0xFF00));
      emit(load16(0, 0xCAFE));
      emit([pack(push(3, 0), pop(1, 3))]);
      emit(load16(2, 0x0200));
      emit([pack(poke(2, 1), ldReg(0, 0))]);

      // 2. Test SDRAM dirty eviction & refill:
      //    mem[0x4000] = 0x1234; mem[0x8000] = 0x5678 (same cache index 0 -> evicts 0x4000!);
      //    read back mem[0x4000] -> store to local 0x0201
      emit(load16(2, 0x4000));
      emit(load16(0, 0x1234));
      emit([pack(poke(2, 0), ldReg(0, 0))]);
      emit(load16(2, 0x8000));
      emit(load16(0, 0x5678));
      emit([pack(poke(2, 0), ldReg(0, 0))]);
      emit(load16(2, 0x4000));
      emit([pack(peek(1, 2), ldReg(0, 0))]);
      emit(load16(2, 0x0201));
      emit([pack(poke(2, 1), ldReg(0, 0))]);

      // 3. Self-modifying code into SDRAM @ 0x5000..0x5007, then jump to 0x5000!
      for (var i = 0; i < sdramCode.length; i++) {
        emit(load16(2, 0x5000 + i));
        emit(load16(0, sdramCode[i]));
        emit([pack(poke(2, 0), ldReg(0, 0))]);
      }
      emit(load16(2, 0x5000));
      emit([pack(jmp(2), ldReg(0, 0))]);

      // Done spin loop at 0x0180 (sets local 0x0203 = 0xACED, then spins at 0x0185)
      addr = 0x0180;
      emit(load16(2, 0x0203));
      emit(load16(0, 0xACED));
      emit([pack(poke(2, 0), ldReg(0, 0))]);
      final spinPc = addr;
      emit(load16(2, spinPc));
      emit([pack(jmp(2), ldReg(0, 0))]);

      final clk = SimpleClockGenerator(10).clk;
      final btnPwrN = Logic(name: 'btn_pwr_n');
      final ftdiTxd = Logic(name: 'ftdi_txd');
      final sdramD = LogicNet(name: 'sdram_d', width: 16);

      final top = Ulx3sTop(
        clk25mhz: clk,
        btnPwrN: btnPwrN,
        ftdiTxd: ftdiTxd,
        sdramD: sdramD,
        config: const CpuConfig(
          coreId: 0,
          enableCpuid: false,
          enableUart: true,
          enableCrossTraps: false,
          enableMathAccel: false,
          enableSdramCache: true,
          cacheLines: 32,
          cacheLineWords: 8,
          trapTableBase: 0x0100,
          memWords: 2048,
        ),
        resetHoldBits: 2,
        sdramInitWaitCycles: 6,
        sdramRefreshCycles: 250,
        initHexFile: null,
        initialMemory: mem,
      );
      await top.build();

      final sdramModel = JedecSdramSimModel()
        ..attachPins(
          clk: top.cpu.input('clk'),
          csN: top.sdramCsn,
          rasN: top.sdramRasn,
          casN: top.sdramCasn,
          weN: top.sdramWen,
          ba: top.sdramBa,
          a: top.sdramA,
          dqOut: top.sdramDqOutDebug!,
          dqOe: top.sdramDqOeDebug!,
          sdramDNet: sdramD,
        );

      btnPwrN.put(0);
      ftdiTxd.put(1);

      Simulator.setMaxSimTime(40000);
      unawaited(Simulator.run());

      Future<void> step() async {
        await clk.nextPosedge;
        await clk.nextNegedge;
      }

      for (var i = 0; i < 4; i++) {
        await step();
      }
      btnPwrN.put(1);

      var reachedDone = false;
      for (var cyc = 0; cyc < 1800; cyc++) {
        if (top.cpu.ram.mem[0x0203] == 0xACED) {
          reachedDone = true;
          break;
        }
        await step();
      }

      expect(reachedDone, isTrue,
          reason: 'CPU timed out at PC=0x${top.cpu.debugPc.value.toInt().toRadixString(16)}');
      // 1. SDRAM stack PUSH/POP verified
      expect(top.cpu.ram.mem[0x0200], equals(0xCAFE));
      // 2. SDRAM dirty eviction (0x4000 evicted by 0x8000) & refill verified
      expect(top.cpu.ram.mem[0x0201], equals(0x1234));
      expect(sdramModel.mem[(0 << 16) | 0x4000], equals(0x1234));
      // 3. Self-modifying code in SDRAM @ 0x5000 snooped, executed via ICache, returned!
      expect(top.cpu.ram.mem[0x0202], equals(0x000F));
      expect(sdramModel.mem[(0 << 16) | 0x5000], equals(sdramCode[0]));

      Simulator.endSimulation();
      await Simulator.simulationEnded;
    });

    test('Live 2-core Ulx3sTop (2x 2K BRAM + shared SDRAM): non-overlapping 64K partitions', () async {
      int ldReg(int rr, int rl) => (0x0 << 4) | (rr << 2) | rl;
      int peek(int rr, int rl) => (0x2 << 4) | (rr << 2) | rl;
      int poke(int rr, int rl) => (0x3 << 4) | (rr << 2) | rl;
      int jmp(int rl) => (0xF << 4) | (0x0 << 2) | rl;
      int push8(int rl, int imm8) =>
          ((imm8 & 0xFF) << 8) | (0xF << 4) | (0x2 << 2) | rl;
      int pack(int b0, int b1) => ((b1 & 0xFF) << 8) | (b0 & 0xFF);
      List<int> load16(int reg, int val) => [
            push8(reg, (val >> 8) & 0xFF),
            push8(reg, val & 0xFF),
          ];

      Map<int, int> makeCoreProg(int pattern) {
        final m = <int, int>{};
        var a = 0x0100;
        void emit(List<int> words) {
          for (final w in words) {
            m[a++] = w;
          }
        }

        // Write pattern to SDRAM 0x4000, evict via 0x8000, read back 0x4000 -> local 0x0200
        emit(load16(2, 0x4000));
        emit(load16(0, pattern));
        emit([pack(poke(2, 0), ldReg(0, 0))]);
        emit(load16(2, 0x8000));
        emit(load16(0, pattern ^ 0x00FF));
        emit([pack(poke(2, 0), ldReg(0, 0))]);
        emit(load16(2, 0x4000));
        emit([pack(peek(1, 2), ldReg(0, 0))]);
        emit(load16(2, 0x0200));
        emit([pack(poke(2, 1), ldReg(0, 0))]);
        final spin = a;
        emit(load16(2, spin));
        emit([pack(jmp(2), ldReg(0, 0))]);
        return m;
      }

      final clk = SimpleClockGenerator(10).clk;
      final btnPwrN = Logic(name: 'btn_pwr_n');
      final ftdiTxd = Logic(name: 'ftdi_txd');
      final sdramD = LogicNet(name: 'sdram_d', width: 16);

      final top = Ulx3sTop(
        clk25mhz: clk,
        btnPwrN: btnPwrN,
        ftdiTxd: ftdiTxd,
        sdramD: sdramD,
        config: const CpuConfig(
          coreId: 0,
          enableCpuid: true,
          enableUart: true,
          enableCrossTraps: true,
          enableNoc: true,
          enableSdramCache: true,
          cacheLines: 32,
          cacheLineWords: 8,
          nocFifoDepth: 16,
          trapTableBase: 0x0100,
          memWords: 2048,
        ),
        nocCores: 2,
        workerMemWords: 2048,
        resetHoldBits: 2,
        sdramInitWaitCycles: 6,
        sdramRefreshCycles: 250,
        initHexFile: null,
        initialMemory: makeCoreProg(0xAAAA),
        workerInitialMemories: [makeCoreProg(0xBBBB)],
      );
      await top.build();

      final sdramModel = JedecSdramSimModel()
        ..attachPins(
          clk: top.cpu.input('clk'),
          csN: top.sdramCsn,
          rasN: top.sdramRasn,
          casN: top.sdramCasn,
          weN: top.sdramWen,
          ba: top.sdramBa,
          a: top.sdramA,
          dqOut: top.sdramDqOutDebug!,
          dqOe: top.sdramDqOeDebug!,
          sdramDNet: sdramD,
        );

      btnPwrN.put(0);
      ftdiTxd.put(1);

      Simulator.setMaxSimTime(40000);
      unawaited(Simulator.run());

      Future<void> step() async {
        await clk.nextPosedge;
        await clk.nextNegedge;
      }

      for (var i = 0; i < 4; i++) {
        await step();
      }
      btnPwrN.put(1);

      var bothDone = false;
      for (var cyc = 0; cyc < 1800; cyc++) {
        if (top.cores[0].ram.mem[0x0200] == 0xAAAA &&
            top.cores[1].ram.mem[0x0200] == 0xBBBB) {
          bothDone = true;
          break;
        }
        await step();
      }

      expect(bothDone, isTrue,
          reason:
              'c0=0x${top.cores[0].ram.mem[0x0200].toRadixString(16)}, c1=0x${top.cores[1].ram.mem[0x0200].toRadixString(16)}');
      // Verify physical SDRAM partitions {coreId[7:0], addr[15:0]} did not overlap!
      expect(sdramModel.mem[(0 << 16) | 0x4000], equals(0xAAAA));
      expect(sdramModel.mem[(1 << 16) | 0x4000], equals(0xBBBB));

      Simulator.endSimulation();
      await Simulator.simulationEnded;
    });

    test('Ulx3sTop parameterized PLL/UART/SDRAM synthesis across 48/60/72/84/96 MHz', () async {
      for (final mhz in [48, 60, 72, 84, 96]) {
        await Simulator.reset();
        final clk = Logic(name: 'clk25_$mhz');
        final btnPwrN = Logic(name: 'btn_$mhz');
        final ftdiTxd = Logic(name: 'rx_$mhz');
        final top = Ulx3sTop(
          clk25mhz: clk,
          btnPwrN: btnPwrN,
          ftdiTxd: ftdiTxd,
          clkFreqMhz: mhz,
          config: const CpuConfig(
            coreId: 0,
            enableUart: true,
            enableSdramCache: true,
            cacheLines: 32,
            memWords: 2048,
          ),
          initHexFile: null,
          initialMemory: const {0x0100: 0x0000},
        );
        await top.build();
        final sv = top.generateSynth();
        expect(sv, contains('FREQUENCY_PIN_CLKOS="$mhz"'));
        if (mhz > 48) {
          expect(sv, contains('FREQUENCY_PIN_CLKOS2="$mhz"'));
          expect(sv, contains('.CLKOS2_ENABLE("ENABLED")'));
          expect(sv, contains('.D0(1\'b1)')); // Ecp5OddrClkFwd
        } else {
          expect(sv, contains('.CLKOS2_ENABLE("DISABLED")'));
          expect(sv, contains('.D0(1\'b0)')); // Ecp5OddrClkInv
        }
      }
    });
  });
}
