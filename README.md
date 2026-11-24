# MicroRISC4 Processor & Software System

A minimalist, in-order, 16-bit word-addressed Von Neumann processor architecture implemented in Intel ROHD (Dart), currently targeted at FPGA synthesis on the Lattice ECP5 (ULX3S board) using OSS CAD Suite.

The project origin was to explore the idea of a small fast multi core system that could emulate other CPUs while being isolated from each other and communicating only by FIFOs — encouraging a Transputer like CSP approach. When it became it was unsuited for this job — because of it's odd architecture and hardware limits — the focus shifted.

Now it is a testbed for CSP multi-core systems, and exploring the engineering required to make a core that can operate at gigahertz speeds.

MicroRISC4 (MR4 or "Mister 4") is a 16 bit, word addressed system with 8-bit instructions.  It has 4 regitsers and a total of 25 possible instructions.  It relies on MMIO for any additional functions.  It is like a cross between early Data General minicomputers and early RISC designs, with a little CSP for flavor.

In addition to assembler there is a small systems language called Act4, inpsired by the Action! programming language for Atari 8-bit computers.

The idea of using small risc cores to emulate larger architectures is being carried forward in the *Particle* project.
