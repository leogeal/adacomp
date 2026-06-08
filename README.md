# adacomp

A minimal self-hosting Ada-to-C compiler. It implements just enough of Ada
to compile itself, written twice in parallel:

- `bootstrap/adacomp.c` — a hand-written C implementation (~1.7K LOC).
- `src/adacomp.adb` — the same compiler written in the Ada subset it
  supports (~1.5K LOC).

The two are kept algorithmically in sync so the canonical bootstrap chain
holds:

```
C compiler                                       (gcc)
   │ compiles
   ▼
bootstrap (Ada→C, written in C)
   │ compiles src/adacomp.adb
   ▼
stage1 (Ada→C, the Ada compiler compiled by bootstrap)
   │ compiles src/adacomp.adb
   ▼
stage2 (Ada→C, the Ada compiler compiled by itself)

`diff stage1's-output stage2's-output` is empty → self-hosting verified.
```

## Status

Self-hosting works. `make verify` builds the whole chain and diffs the
two generated C files; the diff is empty.

## Build and verify

```sh
make bootstrap   # gcc bootstrap/adacomp.c → build/bootstrap
make test        # bootstrap compiles test/hello.adb and test/factorial.adb
make stage1      # bootstrap compiles src/adacomp.adb → stage1
make stage2      # stage1 compiles src/adacomp.adb → stage2
make verify      # diffs stage1's and stage2's outputs; prints
                 # "SELF-HOSTING VERIFIED" on success
make clean       # rm -rf build
```

Requires `gcc` and GNU `make`. No Ada toolchain needed — the Ada compiler
emits C, and the C output is built by gcc.

## Ada subset supported

Enough to compile this compiler.

- **Types**: `Integer` (+ aliases `Natural`, `Positive`), `Character`,
  `Boolean`, `String`, 1D arrays of any of the above, nested arrays
  (`array (...) of NamedArrayType`), `Ada.Text_IO.File_Type` (mapped to
  `FILE *`).
- **Subprograms**: procedures, functions, parameters by value, named-array
  parameters (decayed to pointers), forward declarations.
- **Control flow**: `if / elsif / else`, `while`, `loop`, `for X in lo..hi
  loop`, `for X in reverse lo..hi loop`, `exit`, `exit when`, `return`.
- **Scoping**: nested `declare` / `begin` / `end` blocks.
- **Attributes**: `Integer'Image`, `Character'Pos`, `Character'Val`,
  `S'Length`, `S'First`, `S'Last`.
- **I/O**: `Ada.Text_IO.Put`, `Put_Line`, `New_Line`, `Get`, `Get_Line`,
  `Open`, `Create`, `Close`, `End_Of_File`, both 1-arg (stdout) and 2-arg
  (file) forms, and `Ada.Command_Line.Argument` / `Argument_Count`.
- **Exceptions**: `raise X;` emits an `exit(1)`; exception handler blocks
  are recognised and skipped.

Not in the subset (deliberately): records, tagged types, generics,
discriminants, controlled types, tasking, fixed-point types, ranges
narrower than `Integer`, separate compilation units, packages with
specs/bodies, `with` clauses beyond skipping them as context.

## Layout

```
.
├── bootstrap/adacomp.c   # C bootstrap compiler (Ada subset → C)
├── src/adacomp.adb       # Same compiler in Ada
├── runtime/ada_runtime.h # Tiny runtime header used by emitted C
├── test/                 # Sample programs (hello.adb, factorial.adb)
├── Makefile              # Build orchestration
└── build/                # Compiler outputs (gitignored)
```

## How the compiler works

Single-pass, recursive-descent, no AST. The lexer produces a stream of
typed tokens; the parser walks it and emits C source directly to the
output file as it goes. A flat symbol table with scope stacking tracks
types, array bounds (outer and inner for 2D), and subprogram kinds.

The single-pass model needs occasional bounded lookahead — the two-arg
`Put` dispatch is the clearest example: we save lex state, scan for a
top-level comma before the matching `)`, and restore. That lets one pass
decide whether to emit `ada_put_line(s)` or `ada_fput_line(f, s)` before
parsing the first argument.

Ada attributes (`'Image`, `'Length`, etc.) are handled in the parser
rather than the lexer, so the prefix identifier is still available when
the attribute fires — `S'Length` becomes `(int)strlen(s)`, with `S` in
hand.

## Caveats

- Error messages are minimal; the single-pass design surrenders most of
  the structure that would let it recover or pinpoint causes.
- Buffers are fixed-size (200K source, 4K token, 64K name pool, 2K
  symbols). Self-compilation fits comfortably; larger inputs may not.
- The emitted C is not pretty, but it is compiled with `-O2 -Wall` and
  is warning-clean for the self-hosting input.

## Roadmap

See [ROADMAP.md](ROADMAP.md) for a phased plan to grow this into a
fully functional Ada compiler with multi-architecture support.
