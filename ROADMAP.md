# Roadmap

This document outlines a phased plan for evolving adacomp from a minimal
self-hosting compiler (~3K LOC, tiny Ada subset, C-only emission) into a
fully functional Ada compiler targeting many architectures.

The plan is honest about scale: a production-grade multi-target Ada
compiler is a multi-year, multi-person effort. GNAT — the GPL Ada
compiler used by AdaCore — sets the bar at hundreds of thousands of
lines, riding on GCC's backend. Each phase below names concrete
deliverables; cumulative effort is roughly noted but assumes one
focused full-time developer.

## Contents

- [Strategic framing](#strategic-framing)
- [Phase 0 — Today](#phase-0--today)
- [Phase 1 — Foundation](#phase-1--foundation)
- [Phase 2 — Frontend completeness](#phase-2--frontend-completeness)
- [Phase 3 — Backend pivot](#phase-3--backend-pivot)
- [Phase 4 — Generics and dispatch](#phase-4--generics-and-dispatch)
- [Phase 5 — Tasking and runtime](#phase-5--tasking-and-runtime)
- [Phase 6 — Standard library](#phase-6--standard-library)
- [Phase 7 — Toolchain and ecosystem](#phase-7--toolchain-and-ecosystem)
- [Cross-cutting: conformance and quality](#cross-cutting-conformance-and-quality)
- [Honest realism](#honest-realism)
- [Minimal viable next step](#minimal-viable-next-step)

## Strategic framing

Two questions should be answered before committing to the rest of the
plan, because they shape every later decision.

### 1. Niche

GNAT already exists and is excellent. What's adacomp's reason to exist?
Plausible answers, each implying a different scope:

- **Educational** — readable, single-author tractable, ~10K LOC ceiling.
- **Embedded** — tiny runtime, no GCC dependency, deterministic resource
  use. Implies dropping tasking and most of the standard library.
- **Wasm / web target** — produce browser-runnable Ada.
- **Formal-verification subset** — SPARK-style, kills generics and
  exceptions on purpose.
- **Bootstrap chain that doesn't go through GCC** — value of its own
  for some distributions and operating systems.

Different niches imply different stopping points. Pick one early; let
the rest of the plan adjust around it.

### 2. Backend strategy

Three paths, pick early. The longer this is deferred the more code
fuses to a single backend assumption.

- **(a) Keep emitting C.** Cheap. Inherits every C compiler's target
  list (x86, ARM, RISC-V, MIPS, AVR, Wasm via Emscripten). Loses
  control over codegen quality, debug info, and Ada-specific
  optimizations.
- **(b) Switch to LLVM IR.** ~6 months of work, but opens every LLVM
  target with one codegen, plus a real optimizer and DWARF emission.
  This is the path most new languages have chosen (Rust, Swift, Zig,
  Crystal).
- **(c) Custom native backend per architecture.** Maximum work,
  maximum control. Worth it only if (a) and (b) won't meet your
  goals — typically embedded targets that LLVM doesn't cover well.

**Recommendation: (b) LLVM**, but only after the frontend has an AST.
Until then the codegen is fused into parsing, and that fusion is the
binding constraint on everything.

## Phase 0 — Today

Single-pass recursive-descent, parse-and-emit-C interleaved, no AST,
no semantic checks, fixed-size buffers, error reporting capped at
`"unexpected token"`. Compiles its own ~1.5K-line Ada subset plus
hello-world. Self-hosting is verified.

A good foundation, but a bad starting point for growth without
restructuring first.

## Phase 1 — Foundation

**Duration:** ~3–6 months.
**Goal:** make the existing compiler robust enough to evolve, without
yet adding language features.

- **Replace fixed buffers with dynamic growth** (source, token, name
  pool, symbol table). Without this, every later language feature is
  artificially capped.
- **AST.** Move from "parse → emit" to "parse → tree → walk → emit."
  The single highest-leverage change in the whole roadmap; everything
  below depends on it.
- **Real diagnostics.** Source locations on every token, error
  recovery (synchronize on `;`/`end`), multi-error reports, "did you
  mean" hints.
- **Test infrastructure.** A runner that executes N `.adb` fixtures
  and compares emitted C, runtime output, and expected diagnostics.
  Aim for ~200 fixtures by end of phase.
- **Continuous integration**: matrix build (Linux/macOS, gcc/clang)
  on every push.
- **Documented internal IR.** Even a one-page schema is valuable;
  future contributors are blocked without it.

## Phase 2 — Frontend completeness

**Duration:** ~6–12 months.
**Goal:** fill out the Ada language enough to compile small real-world
programs, not just adacomp itself.

Order by leverage:

- **Packages with spec/body** (`package X is ... end X;` plus the
  corresponding `package body`). Huge unlock — without packages every
  program is one file.
- **Records**, including discriminated and variant records.
- **Access types** (Ada's pointers): `access constant`, `access all`,
  pool-specific.
- **Subtypes with ranges and predicates**
  (`subtype Day is Integer range 1 .. 31`). Drives runtime checks.
- **Enumerations** beyond `Boolean`. Drives idiomatic Ada.
- **Proper exception model.** Define, raise, propagate, handle by
  class. Stack unwinding with finalization. Foundational for the
  next phase.
- **Use-clauses, renaming, child packages.**
- **Numeric representation**: `Integer` is `int` today; needs
  `Long_Long_Integer`, modular types, fixed-point, decimal.

End of phase: adacomp should compile small real Ada programs (a few
thousand lines), not just itself.

## Phase 3 — Backend pivot

**Duration:** ~6 months.
**Goal:** stop being a C-only compiler.

The single biggest architectural change. Two sub-paths:

- **Option B-light:** keep emitting C but introduce a clean IR between
  AST and emission, so multiple backends are *possible* without
  rewriting yet.
- **Option B-full:** add an LLVM backend behind the same IR. Wire up
  DWARF debug info and exception unwinding via LLVM intrinsics. The C
  emitter becomes one of several backends.

End of phase: `adacomp --target=aarch64-linux-gnu`,
`--target=wasm32`, `--target=riscv64` all work via the same codepath.
Cross-compilation is a flag, not a fork.

## Phase 4 — Generics and dispatch

**Duration:** ~12+ months.
**Goal:** cover the hard half of Ada.

- **Generics.** Ada's generics are structurally different from C++
  templates — explicitly instantiated, with formal parameters
  (including the unusual `generic with function ... is <>` form).
  Semantically rich and implementation-wise non-trivial.
- **Tagged types + dynamic dispatch.** Ada's OO: tagged types,
  primitives, class-wide types (`T'Class`), abstract types,
  dispatch tables.
- **Generalized iterators, contracts** (`Pre`, `Post`,
  `Type_Invariant`), aspects.
- **Limited types and controlled types** (proper finalization).

A full year is plausible for a single implementer here. This is also
where running ACATS (Ada's official conformance suite) becomes a real
target — start running it early, accept a low pass rate, then climb.

## Phase 5 — Tasking and runtime

**Duration:** ~12+ months.
**Goal:** implement Ada's concurrency model.

Ada's tasking (`task`, `protected`, rendezvous, entries, `select`,
`delay`) is a defining feature and probably the biggest single chunk
of work in the language.

- **Lightweight runtime** that maps Ada tasks to OS threads (or to a
  green-thread scheduler for embedded). GNAT's GNARL/GNULL split is a
  proven design worth studying.
- **Protected objects** with proper mutex/condition implementation.
- **Real-time annexes** (priorities, ceiling protocols) — only if
  your niche requires them.

**Decision point:** if the chosen niche is embedded or
formal-verification, deliberately omitting tasking (like SPARK) is a
legitimate choice and saves roughly a year.

## Phase 6 — Standard library

**Duration:** continuous, year+.
**Goal:** make the language usable for real work.

Ada's standard library (`Ada.Containers`, `Ada.Strings.Unbounded`,
`Ada.Numerics`, `Ada.Streams`, `Ada.Calendar`, `Ada.Directories`,
`Ada.Wide_Text_IO`, …) is significant. Strategy options:

- **Wrap libc/POSIX where reasonable**, write pure Ada elsewhere.
- **Adopt GNAT's libgnat** if license-compatible (GPL with runtime
  exception) — fastest path to coverage.
- **Subset deliberately** if the niche allows.

## Phase 7 — Toolchain and ecosystem

**Duration:** continuous.
**Goal:** support adoption.

A compiler without these is not used in practice:

- **Linker / driver / build system integration**
  (`gprbuild`-equivalent, or Alire integration).
- **LSP** for IDE editing (VS Code, Emacs, Vim).
- **DWARF debug info** plus GDB-tested debugging experience.
- **Sanitizer/profiler integration** — at the LLVM IR level you get
  ASan, MSan, UBSan effectively for free.
- **Documentation generator.**
- **Package manager / library distribution.**

## Cross-cutting: conformance and quality

These run alongside every phase, not as a single block.

- **ACATS** (Ada Conformance Assessment Test Suite, ~4000 tests) is
  the industry standard for "is this really an Ada compiler?" Run it
  from Phase 3 onward; aim for >90% pass before claiming "Ada 95
  compiler", >95% for Ada 2012, and so on.
- **Fuzz testing**: AFL/libFuzzer against the frontend. Catches the
  long tail of crashes that ACATS won't surface.
- **Self-hosting at every phase** — never break it. It's both a
  regression test and the project's identity.

## Honest realism

- A single full-time developer might reach the **end of Phase 2** in
  ~2 years and produce something that compiles a meaningful Ada
  subset.
- A 3–5 person team could reach a credible **Ada 95-conformant
  compiler in 3–5 years**.
- **Full Ada 2022** with all annexes is decade-scale without
  leveraging existing work.
- Reusing parts of GNAT (the AST library, the runtime) under its
  GPL-with-runtime-exception license is a legitimate accelerator if
  the project's license is compatible.

## Minimal viable next step

If only one move is funded, make it this: **add an AST**. Roughly
three weeks of work. Without it, every later improvement fights the
single-pass parser. With it, you can write a parser, a printer, a
checker, three backends, an LSP, and a fuzzer — all walking the same
data structure.

Every later phase in this document is gated on having one.

## Status

Tactical view of what's done, in progress, and next. Update when
landing changes; the dated commits in `git log` are the source of
truth for "when".

### Phase 0 — Today

Done. Self-hosting verified; bootstrap, stage1, and stage2 produce
identical C output on `make verify`.

### Phase 1 — Foundation

In progress.

- [x] **Step 1.** AST infrastructure and expression-tree parsing in
  `bootstrap/adacomp.c`. Walker `emit_expression_ast` reproduces the
  same C output (modulo aggressive parens on binary nodes). Self-
  hosting still verifies.
- [x] **Step 2.** Same AST conversion ported to `src/adacomp.adb`.
  The Ada self-host now walks the same data structure: flat parallel
  `Node_Store` arrays, an `NPool` character buffer for names and
  string literals, and `Emit_Expression_AST` as the walker. All
  external callers still use the public `Parse_Expression`, which is
  a build / emit / reset wrapper. Self-hosting verifies — stage1 and
  stage2 produce identical output.
- [x] **Step 3 (partial).** Leaf statements — null, return, raise,
  exit, assignment, call, parameterless call, array assignment —
  become AST nodes (`S_NULL` … `S_ARRAY_ASSIGN`) in both files. The
  public `Parse_Statement` is now a build / walk / reset wrapper,
  and `Parse_Statement_AST` returns the node id (or 0 for compound
  and dotted paths, which still emit directly). Each statement is
  processed independently so per-statement order is preserved.
  Compound statements (`if`/`while`/`for`/`loop`/`declare`/`begin`)
  and dotted package calls (`Ada.Text_IO.Put_Line`, …) are *not yet*
  AST nodes — they couple to declarations (`declare` blocks embed
  decls that direct-emit during parse) and will be reworked alongside
  step 4. Self-hosting still verifies.
- [x] **Step 4 (Pass A).** Variable declarations become AST nodes
  (`D_VAR_SIMPLE` … `D_VAR_DOTTED`) in both files. `Parse_Declarations`
  is now a build / walk / reset loop driven by `Parse_Declaration_AST`,
  same hybrid pattern as statements: leaf-decl flavors (simple, named-
  array, anonymous-array, String, File_Type, other dotted) build nodes;
  type definitions and procedure / function declarations still emit
  directly during parse and return 0. Self-hosting still verifies and
  all 14 fixtures pass under both compilers.
- [x] **Step 4 (Pass B.1).** Decouple the AST walkers from the symbol
  table: every walker now reads symbol-derived values (array bounds,
  element type, paramless-function flag) from the node itself, resolved
  at build time into two new scratch fields (`n_aux1`/`n_aux2`). Pure
  refactor — byte-identical output — but it makes a node self-contained
  so the walk can be deferred. Both files; self-hosting verifies.
- [x] **Step 4 (Pass B.2).** Compound statements (`if`/`while`/`for`/
  `loop`/`declare`/`begin`) and dotted package calls
  (`Ada.Text_IO.Put_Line`, `Put`, `New_Line`, `Open`/`Create`/`Close`/
  `Get`/`Get_Line`, generic `Pkg.Op`) become subtree nodes
  (`S_IF` … `S_PKG`). `parse_statements` now builds a whole program
  unit's body as a chain of statement nodes (compound nodes holding
  sub-chains) and walks it once, after the unit is fully parsed.
  A program unit's statement body is now a single AST tree. Both
  files; self-hosting verifies and all 15 fixtures pass under both
  compilers. (Declarations remain streamed at program-unit level —
  proc/func decls drive the recursion rather than being nodes — which
  is why their bodies, not the decls themselves, are the trees.)
- [ ] Replace fixed-size buffers (source, token, name pool, symbol
  table) with dynamic growth. **In progress** — true dynamic growth in
  the *self-hosted* compiler needs heap allocation, which the subset
  lacked, so this was split:
  - [x] **Buffers/1: access types.** Added a minimal, C-mappable
    access-type subset to both compilers — unconstrained array types
    (`array (Integer range <>) of E`), access types (`type P is access
    A`), access-typed variables (`Elem *p = NULL;`), and the `new T
    (lo..hi)` allocator (`malloc((hi-lo+1)*sizeof(E))`). An access-to-
    array variable reuses the existing array index/assign machinery
    (it's a 1-based pointer), so only declaration and allocation are
    new. Fixture `access_types.adb` builds a growable buffer; the
    self-hosted stage1 compiles it with byte-identical codegen to the
    bootstrap. adacomp.adb does not use the feature yet, so self-hosting
    stays byte-identical. 16/16 fixtures under both compilers.
  - [~] **Buffers/2: use it.** Converting adacomp.adb's own fixed
    buffers to access-typed, grown on demand, one at a time:
    - [x] **Source buffer.** `Src` is now an access-to-`Char_Vec` grown
      geometrically (×2 + 64 KB) in `Read_Source`; the bootstrap's `src`
      likewise became a `realloc`-grown `char *`. Both compilers now read
      a 359 KB source (past the old 200 KB cap); `make verify` already
      exercises the regrowth path since adacomp.adb (~95 KB) exceeds the
      64 KB initial cap. (Off-by-one caught in review: grow before
      bumping `Src_Len` so the copy loop never reads the still-null old
      buffer — C `realloc` hid this in the bootstrap.)
    - [ ] Name pool + symbol table (cumulative; the next real cap).
    - [ ] AST node store + NPool (per-unit-body; large bodies).
    - [ ] Token buffer (`Tok_Buffer`) — fixed max token length; lowest
      priority. *Next concrete item: name pool + symbol table.*
- [ ] Real diagnostics: source locations on every token, error
  recovery, multi-error reports.
- [x] Test infrastructure: per-feature `.adb` fixtures with expected
  output, runnable against bootstrap (`make test`) and stage1
  (`make test-stage1`). 15 fixtures shipped; grows as features land.
- [ ] CI: matrix build on every push.
- [ ] Documented internal IR (one-page schema).

### Phases 2–7

Not started. Touched only when Phase 1 is done.

### Cross-cutting

- [ ] **ACATS** — not yet running. Pick this up at Phase 3 once
  there's enough language coverage for the runs to be meaningful.
- [ ] **Fuzzing** — defer until dynamic buffers land (Phase 1); a
  fuzzer hitting fixed 200KB source buffers learns mostly nothing.
- [x] **Self-hosting preserved** — currently true at every commit;
  intent is to keep it that way through Phase 1.
