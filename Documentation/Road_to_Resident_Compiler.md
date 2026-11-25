# Road to a Resident ACT4 Compiler

## Purpose

This document defines a specification and staged plan for an ACT4 compiler that
runs as a resident Mr4OS application. Its implementation language will be ACT4,
and its primary target will be MicroRISC4 assembly accepted by the project
assembler.

The goal is to preserve as much of the behavior and language coverage of the
host compiler, [`tools/act4c.py`](../tools/act4c.py), as the resident memory and
I/O environment permits. The host compiler remains the bootstrap tool and
reference implementation until the resident compiler is proven.

There are two distinct completion goals:

1. **Resident compilation:** `ACT4C.PRG` runs under Mr4OS, reads ACT4 source,
   and writes assembly.
2. **Resident build workflow:** the resident assembler can assemble that output
   into a runnable program, without host-side preprocessing or assembly.

The first goal does not depend on solving every assembler/runtime integration
issue. The second does, and is a later milestone.

## Design principles

### Preserve ACT4's allocation model

ACT4's static allocation of function locals and parameters is an intentional
fit for MicroRISC4 and its Action!-inspired calling model. This project does
not require converting ACT4 programs to dynamic stack frames.

The resident compiler must, however, manage its *own* nested work safely.
Compiler routines should not assume that ordinary function-local variables
survive a nested call. Use explicit state where nesting is required:

- Per-invocation frame arrays and a frame pointer for recursive parser or
  emitter routines.
- Explicit operator, expression, and block stacks where an iterative
  algorithm is simpler.
- Fixed maximum depths with clear diagnostics when exceeded.

These are implementation techniques, not restrictions on the ACT4 language.
The host compiler's existing call and storage semantics remain the language
baseline; recursion and re-entrant user code must not be silently changed by
the resident port.

### Bounded resources, explicit failures

The compiler will use declared fixed capacities for source buffers, tokens,
AST nodes, symbols, strings, import nesting, parser frames, and output buffers.
Every capacity must be checked before writing. A limit must produce a
file-and-line diagnostic where possible; it must never silently truncate or
emit success-shaped partial output.

The OS loader currently defines `APP_MAX_WORDS` as `0xF600` words in
[`os_proc.a4`](../mr4src/act4/os/os_proc.a4), and the OS syscall transfer buffer
is 64 words in [`os_main.a4`](../mr4src/act4/os/os_main.a4). These are important
constraints, not a target allocation for the compiler. Measure the executable,
static work areas, and worst-case temporary use on the actual OS build.
File I/O must work in chunks rather than assuming a source file fits in one
syscall buffer.

### Maintain a host oracle

During development, compile the same test inputs with the host compiler and
resident compiler. Compare diagnostics, normalized assembly, assembled
binaries, and runtime behavior as appropriate. Do not remove or replace the
host compiler until the resident compiler has a stable, reproducible
bootstrap.

## Compatibility target

The host compiler and
[`ACT4 language/compiler reference manual`](act4_language_compiler_reference_manual.md)
define the intended language. Before porting a feature, record its actual
behavior in `act4c.py` and tests; resolve any manual/compiler discrepancies
rather than accidentally choosing one.

The parity target includes:

| Area | Target coverage |
| --- | --- |
| Types and declarations | `u16`, `void`, pointers, fixed and inferred-size arrays, array initializers, `const`, globals, locals, and `@` fixed-address declarations |
| Aggregate and indirect types | `type` structures, member and pointer-member access, function-pointer declarations, assignment, and calls |
| Functions and storage | Function definitions, parameters, return values, static local/parameter storage, direct calls, function pointers, and the existing calling convention |
| Statements | Blocks, expression/assignment statements, `if`/`else`, `while`, `break`, `continue`, `return`, inline assembly, and trap statements |
| Expressions | Literal forms, string deduplication, unary and binary operators, precedence, short-circuit logical operations, comparisons, shifts, indexing, member access, calls, `sizeof`, `getbyte`, and `setbyte` |
| Trap support | Runtime traps and functions bound to trap vectors, including their validation and vector-table output |
| Imports | Relative and `-I` search, nested imports, duplicate suppression, shared constants/types, and useful missing-file diagnostics |
| Code generation | Startup/vector preamble, `--org`, `--nopreamble`, BSS initialization, data/strings, dead-function elimination, and optional `--hw-math` lowering/guard |
| Output | Deterministic assembly, matching the host compiler's target ABI and accepted by the selected assembler path |

This is a parity target, not a requirement to implement every feature in the
first resident release. A feature may be marked unavailable at an intermediate
stage, but the final compiler should support it or document a specific
architecture/resource reason why it cannot.

## Proposed implementation architecture

### Front end

Use compact numeric token kinds and indices into fixed storage rather than
allocating one object per token. Preserve source file, line, and column
information so errors remain actionable. The lexer must handle chunk boundaries
inside identifiers, literals, comments, and CR/LF sequences.

Represent symbols and types in indexed tables. Store strings and names in a
bounded pool and use offsets rather than copied, null-terminated buffers for
every record. Intern string literals so duplicate literals retain the host
compiler's behavior.

An indexed AST arena is the recommended starting point: nodes contain a tag
and indices to children or list links. Parse frames and expression/operator
stacks are separate from the AST arena. This supports the current two-stage
parse/codegen design without requiring the whole program's source text to stay
resident. If measurements show the AST is too expensive, evaluate per-function
parse-and-emit with a declaration/call-graph pass before changing the language
semantics.

Imports require a bounded import stack and a set/table of already-seen files.
Preserve the host compiler's relative-path and include-directory rules where
the OS filesystem supports them. Report import cycles or excessive nesting
explicitly; duplicate imports should not duplicate declarations or strings.

### Semantic analysis

Keep parsing, constant evaluation, and code generation as distinct logical
passes, even if they share tables:

1. Collect imports, type declarations, constants, globals, and function
   signatures.
2. Validate declarations, initializers, constant expressions, trap bindings,
   function calls, and type use.
3. Build function references needed for dead-function elimination.
4. Generate code and static storage from validated records.

This ordering preserves forward references and allows errors to be reported
before an output file is treated as complete. Where the host compiler accepts
constructs without full type checking, document and test the behavior before
deciding whether to preserve or tighten it.

### Back end and output

Preserve the host compiler's code-generation conventions, label names where
practical, register/stack use, runtime helper calls, static storage layout,
startup vectors, and entry behavior. Keep the output deterministic to support
differential testing.

Write assembly through a bounded output buffer and chunked file writes. Every
generated source line must fit the resident assembler's current 127-byte line
limit, or the assembler limit must be intentionally raised and tested. Large
array initializers must be split across lines.

The host compiler emits `.include "M4R_LIB.asm"`; the resident assembler
currently rejects general `.INCLUDE` directives and only accepts
`common.inc`. The resident build milestone must choose and test one of these
approaches:

- Add bounded, path-aware include support to the resident assembler and make
  the runtime library available on the SD card.
- Have the compiler emit only the required runtime helpers inline.
- Define another explicit link/runtime mechanism compatible with the resident
  toolchain.

Do not silently treat `M4R_LIB.asm` as an empty include. The resident
assembler's current 384-symbol limit must also be measured against real
compiler output and adjusted if needed.

## Delivery plan

Each stage should leave the repository buildable and keep the existing host
compiler and OS tests passing. The stages are ordered by dependency; exact
source-file organization can be decided during implementation.

### Stage 0: Freeze behavior and establish test oracles

- Inventory the host compiler's accepted syntax, diagnostics, output options,
  runtime dependencies, and known limitations.
- Reconcile the compiler, language manual, and existing tests where their
  behavior differs.
- Create a compact fixture corpus covering each language feature and relevant
  edge cases.
- Record host compiler assembly and assembled-binary baselines where stable.
- Add tests for malformed inputs and host compiler behavior that will serve as
  the compatibility oracle.

**Status: Complete.** The focused host suite is
[`tools/test_act4c.py`](../tools/test_act4c.py), runnable with
`make test-act4c` and included in `make os-test`. It covers deterministic
assembly, assembly acceptance, code-generation options, relative and
include-directory imports, duplicate import suppression, trap payloads, and
source diagnostics. Its default-output fixture pins both assembly and
assembled-binary SHA-256 baselines. `make test-act4c` passed 6/6 fixtures, and
`make os-test` passed all 19 OS regression scenarios. The existing OS suite
remains the runtime oracle.

The audit found two manual/compiler discrepancies and reconciled them:
`trap(vector)` now emits a zero payload as documented, and the CLI reference
now lists `--hw-math` and accurately describes the default output filename.
The host compiler's 19 OS regression scenarios are described in
[`GettingStarted.md`](../GettingStarted.md).

**Exit criteria:** the intended compatibility target is explicit, tested, and
small enough to run for every resident compiler change.

### Stage 1: Resident application and reliable I/O

- Build a minimal ACT4 compiler shell as `ACT4C.PRG`, bootstrapped with the
  host compiler and added to the Mr4OS application workflow.
- Accept input/output paths and the compiler options selected for the initial
  target.
- Implement chunked source reads, chunked output writes, argument handling,
  clean file closure, and useful OS error reporting.
- Prove that the resident application can read a source file and write a
  complete deterministic output file before adding language support.

**Exit criteria:** the program runs under Mr4OS, handles files larger than one
syscall transfer, and leaves no partial output presented as a successful
compile after an error.

### Stage 2: Lexer, tables, imports, and declarations

- Implement the lexer, source locations, string/identifier pools, bounded
  symbol/type tables, constant evaluation, and parser frame/stack primitives.
- Add imports, duplicate suppression, and the supported include search rules.
- Parse constants, primitive and aggregate types, globals, and function
  signatures.
- Emit constants, initialized data, BSS, and strings.

**Exit criteria:** declaration-focused fixtures produce matching host/resident
symbols and data, with explicit diagnostics for malformed syntax and capacity
overflow.

### Stage 3: Core functions and control flow

- Implement function bodies, parameters, static local storage, calls, returns,
  assignments, `if`/`else`, `while`, `break`, and `continue`.
- Implement expression parsing with explicit nesting state; verify nested
  parentheses and operator precedence at configured maximum depth.
- Preserve the host compiler's calling convention and return-address behavior.

**Exit criteria:** resident-generated programs for core language fixtures
assemble with the host assembler and match host-generated binaries or
observable behavior.

### Stage 4: Full language semantics

- Add all remaining operators, compound assignments, increment/decrement,
  pointers, array indexing and initializers, structures, member access,
  function pointers, `sizeof`, byte operations, and string deduplication.
- Add inline assembly, runtime traps, trap-bound functions, and vector-table
  generation.
- Add compile-time checks and diagnostics consistent with the host compiler.

**Exit criteria:** every language feature in the compatibility table has at
least one positive fixture and relevant negative/edge-case tests.

### Stage 5: Code-generation and command-line parity

- Match startup/vector generation and the `--org` and `--nopreamble` modes.
- Match BSS zeroing, runtime helper use, dead-function elimination, and
  `--hw-math` behavior.
- Match output path defaults, import search ordering, and error exit behavior.
- Compare host and resident outputs across the complete fixture corpus.

**Exit criteria:** no unexplained semantic, binary, or runtime differences
remain in the selected compatibility corpus.

### Stage 6: Resident assembler and runtime integration

- Select and implement the `M4R_LIB.asm` inclusion/runtime strategy.
- Validate all emitted directives, macro expansions, expressions, labels, and
  line lengths against the resident assembler.
- Measure and adjust assembler symbol and image capacities using generated
  programs, not only hand-written examples.
- Add end-to-end tests that compile and assemble on Mr4OS, then execute the
  result.

**Exit criteria:** the resident compiler and resident assembler produce a
runnable program without host-side transformation.

### Stage 7: Bootstrap and maintenance workflow

- Compile the resident compiler source with the host compiler, assemble it,
  and install the resulting `ACT4C.PRG`.
- Run that compiler under Mr4OS on its own source; assemble the output using
  the resident assembler.
- Run the resulting compiler and repeat at least one generation to establish
  a stable bootstrap.
- Add a reproducible OS integration test and document how to update the
  checked-in resident compiler binary/image.
- Keep host-vs-resident differential tests in the normal test workflow.

**Exit criteria:** a clean checkout can reproduce the bootstrap, and the
resident-generated compiler passes the same smoke and compatibility tests as
the host-generated one.

## Verification strategy

Use several levels of evidence rather than relying on successful compilation
alone:

1. **Front-end fixtures:** token boundaries, precedence, constants, imports,
   strings, nested syntax, diagnostics, and every capacity boundary.
2. **Differential tests:** compile the same source with host and resident
   compilers; compare normalized assembly and, where possible, assembled
   binaries.
3. **Runtime tests:** execute representative generated programs under the
   simulator and Mr4OS, including file I/O, strings, arrays, calls, traps, and
   imports.
4. **Assembler compatibility tests:** exercise maximum line length, symbol
   count, include behavior, and large initializers.
5. **Bootstrap tests:** build compiler generation N with generation N-1, run
   generation N on the same fixtures, and confirm stable output and behavior.
6. **Failure tests:** invalid syntax, missing imports, bad constant
   expressions, malformed assembly blocks, file errors, and every configured
   resource limit must fail clearly and close open files.

The OS integration tests should be added to the existing test workflow in
[`tools/test_os.py`](../tools/test_os.py). The resident build work also advances
the on-board development goal in
[`Roadmap_Phase3.md`](Roadmap_Phase3.md), Track H.3.

## Completion definition

The project is complete when the compiler:

- Runs as an Mr4OS application and has documented, measured resource limits.
- Supports the compatibility target or lists precisely justified exceptions.
- Produces deterministic, diagnosable output without silent truncation.
- Can use the resident assembler to produce runnable applications.
- Can be rebuilt and bootstrapped from a clean checkout with automated tests.

Static locals and the absence of implicit per-call frames are architectural
choices to preserve. Compiler-internal nesting is handled with explicit
bounded state, not by weakening the language target.
