import 'dart:async';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:minirisc4_rohd/cache_controllers.dart';

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
  });
}
