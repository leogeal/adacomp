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
- [x] Replace fixed-size buffers (source, token, name pool, symbol
  table) with dynamic growth. Every cap that bites real programs is gone
  in both compilers; only the per-token length (4096) remains as a
  deliberate fixed limit. True dynamic growth in the *self-hosted*
  compiler needed heap allocation, which the subset lacked, so this was
  split:
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
  - [x] **Buffers/2: use it.** Converted adacomp.adb's own fixed
    buffers to access-typed, grown on demand, one at a time:
    - [x] **Source buffer.** `Src` is now an access-to-`Char_Vec` grown
      geometrically (×2 + 64 KB) in `Read_Source`; the bootstrap's `src`
      likewise became a `realloc`-grown `char *`. Both compilers now read
      a 359 KB source (past the old 200 KB cap); `make verify` already
      exercises the regrowth path since adacomp.adb (~95 KB) exceeds the
      64 KB initial cap. (Off-by-one caught in review: grow before
      bumping `Src_Len` so the copy loop never reads the still-null old
      buffer — C `realloc` hid this in the bootstrap.)
    - [x] **Name pool + symbol table.** The 9 per-symbol arrays grow in
      lock-step via `Ensure_Sym_Cap` (access-to-`Int_Vec`), and the name
      pool via `Ensure_Name_Pool_Cap` (access-to-`Char_Vec`); the
      bootstrap reallocs its 10 parallel arrays in `grow_syms`. Both
      ensure capacity *before* bumping the count (the `Src` off-by-one
      lesson). stage1 now compiles a 3000-symbol program (past the old
      2000-symbol / 64 KB name-pool caps); self-hosting verifies, 16/16
      fixtures under both compilers.
    - [x] **AST node store + string pool.** The 13 parallel node arrays
      grow in lock-step (`Ensure_Node_Cap`, access-to-`Int_Vec`) and the
      AST string pool via `Ensure_NPool_Cap` (access-to-`Char_Vec`); the
      bootstrap reallocs its 13 arrays + pool in `grow_nodes`/`pool_str`.
      `Reset_AST` keeps the grown capacity and only rewinds the lengths,
      so the per-unit peak is allocated once and reused. stage1 compiles
      a single ~20 K-node procedure body (past the old 10 K cap);
      self-hosting verifies, 16/16 fixtures under both compilers.
    - [ ] Token buffer (`Tok_Buffer`) — fixed max token length; lowest
      priority (a single identifier/string over 4096 chars; not a real
      constraint, left as a known cap).
- [~] Real diagnostics. **Located errors done; recovery/multi-error
  deferred.**
  - [x] **Located errors with a source caret.** Errors now print in the
    gcc-style `file:line:col: error: msg` form, followed by the offending
    source line and a `^` under the column, in both compilers. Every
    token records its start line/offset (`tok_line`/`tok_pos`); `error()`
    derives the column and slices the source line out of the (in-memory)
    source buffer. The error path doesn't touch the emitted C, so
    self-hosting stays byte-identical. Needed a small language addition —
    char dispatch for the one-argument `Ada.Text_IO.Put` (`ada_put_char`
    vs `ada_put_str`) — so the self-host can print the caret line.
    Two error fixtures (`err_expr`, `err_semi`) regression-test the
    located output under both compilers.
  - [ ] Error recovery (sync to `;`/`end`) + multi-error reporting.
    Harder here: declarations still stream-emit C as they parse, so
    recovering after an error would emit partial output. Best tackled
    once declarations are AST-driven like statement bodies are.
- [x] Test infrastructure: per-feature `.adb` fixtures (valid programs
  via `.expected`, diagnostics via `.experr`), runnable against bootstrap
  (`make test`) and stage1 (`make test-stage1`). 18 fixtures; grows as
  features land.
- [x] CI: GitHub Actions runs bootstrap + fixtures + self-hosting verify
  + stage1 fixtures on every push to main and every PR.
- [ ] Documented internal IR (one-page schema).

### Phase 2 — Frontend completeness

Started.

- [x] **Records (v1).** `type T is record F : Integer; ... end record;`
  -> a C `struct`; record variables (`struct t v = {0};`), field read /
  write (`v.f`), whole-record copy (`v = w;`), and by-value record
  parameters. Both compilers; fixture `records.adb`; the self-hosted
  stage1 compiles it with byte-identical codegen to the bootstrap;
  self-hosting still verifies (adacomp.adb doesn't use records yet).
  Deferred: nested/array record fields, aggregates (`(X => 1, ...)`),
  `in out` (by-reference) record params, variant records.
- [~] Packages with spec/body (multi-file) — the biggest remaining
  unlock. Doing it in two stages:
  - [x] **Stage 1: packages as namespaces (single file).** `package P is
    ... end P;` / `package body P is ... end P;` declared in a unit's
    declarations; subprograms become `<pkg>_<op>` C functions; qualified
    calls `P.Op(x)` and unqualified intra-package calls both mangle to
    match (the callee is tagged with its package so call sites resolve at
    build time). Both compilers; fixture `packages.adb` (Math.Square /
    Math.Cube, incl. an intra-package call) → 27/25; self-hosted stage1
    compiles it byte-identically to the bootstrap; self-hosting verifies.
    Deferred to stage 2 / later: separate compilation (.c+.h, `with` ->
    #include, linking), package-level variables/types, package init
    `begin`, library-level & child packages, `use` visibility.
  - [x] **Stage 2: separate compilation.** A compilation unit can now be
    a library-level package: a spec `package P is ... end P;` compiles to
    a `.h` (include-guarded prototypes + `#include "ada_runtime.h"`), a
    body `package body P is ... end P;` to a `.c` (its own `#include
    "p.h"` + the definitions). A simple `with P;` in any unit emits
    `#include "p.h"` (dotted `with Ada.Text_IO;` stays a builtin, ignored,
    so adacomp.adb self-hosts byte-identically). Demo `test/mf/`
    (mathpkg.ads/.adb + mfmain.adb) builds spec->.h, body->.c, main->.c
    and links them; `make test-multifile[-stage1]` runs it under both
    compilers (and in CI). The self-hosted stage1 emits all three units
    byte-identically to the bootstrap. Deferred: package-level
    variables/types in specs (need extern handling), package init `begin`,
    child packages, `use` visibility.
- [x] **Enumerations (v1).** `type T is (A, B, C);` -> a C `enum { a, b,
  c };`; the type is an int, literals are registered constants that emit
  their lowercased C name, so assignment and comparison just work. Both
  compilers; fixture `enums.adb` (Color/Day, if-comparisons) -> green/
  friday/2; self-hosted stage1 byte-identical to the bootstrap; verify
  passes. Deferred: overloaded literals across types (see enum
  attributes / iteration below for `'Image` etc.).
- [x] **Case statements (v1).** `case E is when C1 | C2 => ... when
  others => ... end case;` -> a C `switch` with each arm in a block and
  an explicit `break;` (Ada has no fall-through), `when others` ->
  `default`. New tokens `case`, `=>`, `|`; subtree nodes S_CASE / S_WHEN;
  arm bodies reuse the statement-chain parser (it already stops at
  `when`/`end`). Both compilers; fixture `case_stmt.adb` (enum case with
  alternatives + integer case with others) -> weekday/weekend/two or
  three; stage1 byte-identical to bootstrap; verify passes.
- [x] **Case range choices.** `when 1 .. 5 =>` (also mixed with
  alternatives: `when 11 .. 20 | 30 .. 40 =>`) via a new A_RANGE choice
  node emitted as a GNU C case range (`case 1 ... 5:` — gcc and clang
  both accept it, warning-free without -pedantic). Both compilers;
  fixture `case_ranges.adb` -> low / even-ish / odd-ish / teens or
  thirties (x2) / other. Stage1 byte-identical to the bootstrap;
  verify passes; 31/31 fixtures under both compilers.
- [x] **Access types v2 (records, .all, deallocation).** Access-to-record
  types with implicit dereference — the shape linked lists and trees
  need. `type Node;` (incomplete declaration, assumed record),
  `type Node_Ptr is access Node;`, access-typed record fields
  (`Next : Node_Ptr;` -> `struct node *next;` — self-reference works
  because C structs don't need a forward declaration for pointer
  members), `P : Node_Ptr := new Node;` -> `struct node *p =
  calloc(1, sizeof(struct node))` (zeroed, matching the compiler's
  zero-default convention), `P.Field` -> `p->field` (read and write),
  `P.all` -> `(*p)` including `P.all := e;` -> `*p = e;` for scalar
  access types, `null` as an expression (-> 0) so `P := null` and
  `P /= null` work, and `procedure Free is new
  Ada.Unchecked_Deallocation (T, PT);` whose call `Free (P);` emits
  `free(p); p = NULL;` (the only supported generic instantiation,
  tagged in the symbol table; matches Ada's null-out post-condition).
  Access-to-record variables register as TY_ACCESS so `.` resolves to
  `->` instead of the array-indexing machinery; access-to-array keeps
  its v1 TY_ARRAY modelling. New node kinds A_ALL / S_ALL_ASSIGN /
  S_FREE; `.all` after an access-to-array value is disambiguated by a
  one-token lookahead (all_follows_dot). Both compilers; fixture
  `access_records.adb` (build a 3-node list by head insertion, traverse
  and sum, free it node by node, then a scalar Int_Ptr with .all
  arithmetic and Free) -> 3 / 2 / 1 / 6 / freed / 42 / int freed.
  Stage1 byte-identical to the bootstrap; verify passes; 27/27 fixtures
  under both compilers. Deferred: initialized allocators
  (`new T'(...)`), access-to-subprogram, `.all` on record access values
  (`P.all.Field` — use `P.Field`), general access (`'Access` /
  `'Unchecked_Access`), and dereference null-checks (a null `P.Field`
  is a C segfault, not Constraint_Error).
- [x] **use-clauses (v1: Ada.Text_IO).** `use Ada.Text_IO;` in the
  context clause makes the statement-level Text_IO builtins (Put_Line,
  Put, New_Line, Get_Line, Get, Open, Close, Create) visible without
  the package prefix; bare and dotted forms coexist, and a
  user-declared subprogram with the same name still wins (the bare
  path only fires for unresolved identifiers). Implemented by
  extracting the dotted builtin dispatch into a shared
  `build_pkg_stmt` used by both paths — dotted output is unchanged.
  Both compilers; fixture `use_textio.adb` (bare Put_Line / Put with
  int and char args / New_Line alongside a dotted call) -> hello /
  n =7 / x / dotted. Stage1 byte-identical to the bootstrap; verify
  passes; 28/28 fixtures under both compilers. Deferred: `use` of user
  packages (bare calls into a with'ed package), `use` in declarative
  parts (context clause only), expression-side builtins via use, and
  `use type`.
- [x] **Exceptions (v1).** `Name : exception;` declarations, `raise E`,
  bare `raise;` (re-raise), and `begin ... exception when E1 | E2 => ...
  when others => ... end` handlers on block statements, subprogram
  bodies, and the main unit. Modelled on `setjmp`/`longjmp`: a handled
  frame pushes an `ada_handler` onto a global stack and runs its body
  under `setjmp`; `raise` sets the in-flight exception id/name and
  `longjmp`s to the top frame (printing + `exit(1)` if none is
  installed). Handler dispatch is an if/else-if chain on `ada_cur_exc`;
  `when others` is the final `else`; an unmatched exception
  re-propagates. The four predefined exceptions (Constraint_Error,
  Program_Error, Storage_Error, Tasking_Error) are seeded with fixed ids
  1..4; user exceptions take ids from 5. New token `exception`, symbol
  kind SK_EXCEPTION, node kind S_EXC_ID; runtime support in
  `ada_runtime.h`. Both compilers; fixture `exceptions.adb` (user +
  predefined exceptions, by-name and alternative dispatch, `when others`,
  re-raise, cross-procedure unwinding) -> ok / caught my_error in risky /
  caught constraint_error / caught alt / logged, re-raising / outer
  caught reraised / caught others. Stage1 byte-identical to the
  bootstrap; verify passes; 23/23 fixtures under both compilers.
  Deferred: a `return`/`exit`/`goto` that leaves a handled region while
  a handler is still installed (it would skip the stack pop — fixtures
  avoid this).
- [x] **Exception messages.** `raise E with "msg"` carries the message
  into the runtime (`ada_raise_msg` sets `ada_cur_exc_msg`); a bare
  re-raise `raise;` preserves the whole occurrence, message included;
  an unhandled exception prints `raised E : msg` to stderr. Handlers
  accept the occurrence parameter (`when E : others =>` — the name is
  cosmetic since one exception is in flight), and
  `Ada.Exceptions.Exception_Message (E)` / `Exception_Name (E)` read
  the in-flight globals as expression builtins. Both compilers;
  fixture `exc_messages.adb` (message read in handler, re-raise
  preserving it, plain raise yielding an empty message) -> bad line 5
  / Config_Error / inner / plain / (empty). Stage1 byte-identical to
  the bootstrap; verify passes; 29/29 fixtures. Deferred:
  `Exception_Name` is the simple declared-case name (real Ada gives a
  fully-qualified upper-case name), message expressions are evaluated
  but only string-valued ones are meaningful, and occurrence objects
  are not first-class values (no saving/copying occurrences).
- [x] **Subtypes / ranges with checks (v1).** `subtype S is Integer
  range L .. H;`, `type T is range L .. H;`, and inline `X : Integer
  range L .. H;` constraints, plus variables of a named ranged subtype
  (`X : S;`). The constraint rides on the symbol (sym_has_range /
  sym_range_lo / sym_range_hi) and is resolved onto the assignment /
  declaration node at build time. Assigning or initializing such a
  variable emits `ada_range_check(v, lo, hi)`, a runtime helper that
  returns `v` if it lies in `[lo, hi]` and otherwise raises
  Constraint_Error (id 1) — so the bad store never happens and the
  exception machinery catches it. This makes Constraint_Error fire for
  real. New token `subtype`; integer subtypes map to C `int` (no C type
  emitted). Both compilers; fixture `subtypes.adb` (subtype + `type ...
  is range` + inline range + named-subtype var, in-range assigns, two
  out-of-range assigns caught by handlers) -> 5 / 10 / 75 / 100 / x out
  of range / z out of range / 10. Stage1 byte-identical to the
  bootstrap; verify passes; 24/24 fixtures under both compilers.
  Deferred: dynamic / named-constant bounds (bounds must be static
  integer literals); range checks on parameter passing and subtype
  conversions; ranged subtypes of enum / character types; `'First` /
  `'Last` / `'Range` on subtypes; initializer checks on main-level
  locals (emitted as C globals, so the check is skipped there).
- [x] **Natural / Positive implicit constraints.** `Natural` and
  `Positive` are now real tokens carrying their implicit ranges
  (0 .. Integer'Last and 1 .. Integer'Last) through the existing
  sym_has_range machinery: variables of either type get
  Constraint_Error checks on assignment, `subtype S is Natural;`
  inherits the range (an explicit `range L .. H` on either base wins),
  and they are accepted everywhere Integer is (parameters, record
  fields, `array (Positive range <>)`, `Natural'Image`). Both
  compilers; fixture `natural_positive.adb` (in-range arithmetic, a
  Natural underflow to -1 and a Positive underflow to 0 both caught) ->
  10 / 3 / 5 / natural underflow / positive underflow / 10 / 3.
  Stage1 byte-identical to the bootstrap; verify passes; 30/30
  fixtures under both compilers.
- [x] **Array index bounds checks (v1).** Indexing a fixed-size array —
  on read (`A (I)`), 2D read (`M (I)(J)`), and write (`A (I) := ...`) —
  now emits `ada_range_check(idx, lo, hi)` against the array's
  statically-known bounds before the `- lo` that forms the 0-based C
  index, so an out-of-bounds subscript raises Constraint_Error instead
  of corrupting memory. Bounds (high stored in N_Aux2 / inner high in
  N_Int) are resolved onto the index/assign node at build time, reusing
  the same `ada_range_check` helper and the existing subtrahend
  machinery via a shared `emit_checked_index`. Arrays with no static
  upper bound (access-type/dynamic buffers, strings, unresolved names —
  all carrying hi = 0) are left unchecked, as are arrays whose declared
  high bound is exactly 0. Both compilers; fixture `array_bounds.adb`
  (fill 1..5, read back, then a write at 6 and a read at 0 each caught
  by a handler) -> 1 / 4 / 9 / 16 / 25 / write out of bounds / read out
  of bounds / 9 / 0. Notably the self-host now bounds-checks its own
  fixed arrays (`Tok_Buffer`, scope stack, ...) and still self-compiles
  byte-identically: stage1 == stage2, 25/25 fixtures under both
  compilers. Deferred: comma-form 2D array *types* (`array (1..N,
  1..M)`, whose inner bound isn't tracked), and bounds checks on
  slices.
- [x] **Enum attributes + iteration (v1).** `T'First` / `T'Last` /
  `T'Pos (X)` / `T'Val (N)` / `T'Image (X)` on enumeration types, and
  `for X in T loop` / `for X in reverse T loop` (also `T'Range`). An
  enum type now records its position range [0, n-1] by reusing the
  subtype machinery (sym_has_range / lo / hi), so `'First` / `'Last`
  resolve to integer literals, iteration lowers to the existing numeric
  for-loop, and — as a bonus — enum *variables* inherit the range and
  get Constraint_Error checks on assignment (so a bad `T'Val` is
  caught). Since the C representation is `int`, `'Pos` and `'Val` are
  identities (the argument passes through unchanged). `'Image` emits a
  per-type `static const char *<type>_image(int v)` switch returning the
  upper-cased literal name, generated at the enum's definition (file
  scope only — a nested C function would be illegal). Both compilers;
  fixture `enum_attrs.adb` (First/Last, forward + reverse iteration with
  Image, Pos, Val) -> 0 / 2 / RED / GREEN / BLUE / 1 / BLUE / BLUE /
  GREEN / RED. Stage1 byte-identical to the bootstrap; verify passes;
  26/26 fixtures under both compilers. Deferred: `'Image` on a
  proc-local enum type (would need a hoisted or nested function),
  `'Value` (string -> enum), and range-checking `'Val` itself (only
  the assignment target is checked).
- [x] **'Succ / 'Pred.** `T'Succ (X)` / `T'Pred (X)` as +1 / -1. On an
  enum type the result is range-checked against the type's position
  range, so stepping past `T'Last` / before `T'First` raises
  Constraint_Error (matching Ada); on Integer (and Natural/Positive /
  Character / Boolean type names) they are plain unchecked +-1. Both
  compilers; fixture `succ_pred.adb` (enum walk up and down,
  Integer'Succ/'Pred, both out-of-range edges caught) -> BLUE / RED /
  11 / 10 / pred out of range / succ out of range / BLUE. Stage1
  byte-identical to the bootstrap; verify passes; 32/32 fixtures.

### Phases 3–7

Not started.

### Cross-cutting

- [ ] **ACATS** — not yet running. Pick this up at Phase 3 once
  there's enough language coverage for the runs to be meaningful.
- [ ] **Fuzzing** — defer until dynamic buffers land (Phase 1); a
  fuzzer hitting fixed 200KB source buffers learns mostly nothing.
- [x] **Self-hosting preserved** — currently true at every commit;
  intent is to keep it that way through Phase 1.
