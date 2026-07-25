# The adacomp IR

The compiler's intermediate representation is its **resolved AST**: a
flat, index-linked node store that is fully *symbol-free* by the time it
is walked. The parser builds nodes while the symbol table is live and
resolves everything a backend could need — array bounds, range-check
limits, package-mangled call names, pointer-vs-value field access,
enum position ranges, parameter defaults — onto the nodes themselves.
A backend is any set of walkers over this store; it never consults the
symbol table. The C emitter is the first such backend.

Both compilers (`bootstrap/adacomp.c` and `src/adacomp.adb`) implement
the same store with the same kind numbers and field conventions.

## The node store

Eleven parallel dynamic int arrays plus one character pool. Index 0 is
the null node; `new_node(kind)` zeroes every field.

| Field       | Meaning (by convention)                                    |
|-------------|------------------------------------------------------------|
| `n_kind`    | node kind (tables below)                                   |
| `n_op`      | operator / sub-op / variant flag / is-const                |
| `n_int`     | literal value / type code / length partner of `n_arg2`     |
| `n_str_off` `n_str_len` | primary name or string, in `npool`            |
| `n_left` `n_right` | operand links (occasionally a plain int, noted below) |
| `n_arg2`    | secondary operand link, or pooled secondary string offset  |
| `n_first` `n_next` | head of a child chain / sibling link                |
| `n_aux1` `n_aux2` | resolved-at-build scratch (bounds, flags, counts)    |
| `npool`     | character pool for names and string literals               |

**Lifetime:** the pool is built per compilation step and reset after
its walk (`reset_ast`): one variable declaration, or one subprogram
body's statement tree, is built, walked, then discarded. Nothing reads
a node after its reset.

## Expression kinds (`A_*`)

| Kind | Meaning | Fields |
|------|---------|--------|
| `A_INT_LIT` 1 | integer literal | `n_int` value |
| `A_CHAR_LIT` 2 | character literal | `n_int` char code |
| `A_STR_LIT` 3 | string literal | `n_str` (emitter re-escapes) |
| `A_BOOL_LIT` 4 | True/False | `n_int` 0/1 |
| `A_IDENT` 5 | name use | `n_str`; `n_op`=1 → paramless-function call |
| `A_UNARY` 6 | `-` / `not` | `n_op` OP_NEG/OP_NOT, `n_left` |
| `A_BINARY` 7 | infix op | `n_op` OP_*, `n_left`, `n_right`; OP_CAT is a call, not infix |
| `A_INDEX` 8 | `A (I)` | `n_str` base; `n_right` index; `n_op` lo; `n_aux2` hi (0 = unchecked) |
| `A_INDEX2` 9 | `A (I)(J)` | + `n_arg2` inner index; `n_aux1` inner lo; `n_int` inner hi |
| `A_CALL` 10 | call with args | `n_str` resolved (mangled) name; `n_first` arg chain |
| `A_DOTTED` 11 | `Pkg.Sub (args)` | `n_str` prefix, `n_arg2`+`n_int` sub-name; builtins special-cased |
| `A_ATTR_TYPE` 12 | `T'Attr (X)` | `n_op` ATTR_*; `n_left` arg; IMAGE: `n_str` enum type name (empty = Integer); SUCC/PRED: `n_aux1` checked, bounds `n_aux2`/`n_int` |
| `A_ATTR_VAR` 13 | `S'Length` etc. on strings | `n_op` ATTR_*; static arrays resolve to `A_INT_LIT` at build instead |
| `A_NEW` 14 | allocator | bounds `n_left`/`n_right` (array form) or 0 (calloc form); `n_op` elem TY, TY_RECORD pools name in `n_str` |
| `A_FIELD` 15 | `R.F` / `P.F` | `n_str` base, `n_arg2`+`n_int` field; `n_op`=1 → `->` |
| `A_ALL` 16 | `P.all` | `n_str` base |
| `A_RANGE` 17 | case choice `lo .. hi` | `n_left`, `n_right`; only under `S_WHEN` |
| `A_AGG` 18 | aggregate entry | `n_op`=1 others; `n_int` index; `n_aux1` value; only under `D_VAR_ANON_ARRAY` |

## Statement kinds (`S_*`)

| Kind | Meaning | Fields |
|------|---------|--------|
| `S_NULL` 20 / `S_RETURN` 21 | — | RETURN: `n_left` value (`n_op`=1 → bare `return 0`) |
| `S_RAISE` 22 | raise | `n_op`=1 re-raise; `n_aux1` exc id; `n_str` name; `n_arg2` message expr |
| `S_EXIT` 23 | exit [when] | `n_left` condition or 0 |
| `S_ASSIGN` 24 | `X := E` | `n_str` target; `n_right` rhs; `n_op`=1 → range-checked, bounds `n_aux1`/`n_aux2` |
| `S_CALL` 25 | proc call | like `A_CALL`; omitted trailing args already filled from defaults |
| `S_PARAMLESS` 26 | `P;` | `n_str` |
| `S_ARRAY_ASSIGN` 27 | `A (I) := E` | `n_str`, `n_right` idx, `n_arg2` inner idx, `n_first` rhs; lo/hi like A_INDEX |
| `S_FIELD_ASSIGN` 28 | `R.F := E` | like `A_FIELD` + `n_right` rhs |
| `S_IF` 40 / `S_ELSIF` 41 | if chain | `n_left` cond, `n_first` then-chain, `n_right` elsif chain, `n_arg2` else-chain |
| `S_WHILE` 42 / `S_LOOP` 43 | loops | `n_left` cond (WHILE), `n_first` body |
| `S_FOR` 44 | for loop | `n_str` var, `n_left`/`n_right` bounds (enum/array ranges pre-resolved), `n_op`=1 reverse |
| `S_DECLARE` 45 | declare block | `n_first` decl chain, `n_arg2` body, `n_right` handler arms |
| `S_BLOCK` 46 | begin block | `n_first` body, `n_arg2` handler arms |
| `S_PKG` 47 | Text_IO-style builtin | `n_op` PKG_*; args in `n_left`/`n_right`/`n_first`; PKG_GENERIC carries names |
| `S_CASE` 48 / `S_WHEN` 49 | case | CASE: `n_left` selector, `n_first` arms; WHEN: `n_op`=1 others, `n_first` choice chain, `n_arg2` body |
| `S_EXC_ID` 50 | handler choice | `n_aux1` exception id |
| `S_ALL_ASSIGN` 51 | `P.all := E` | `n_str` base, `n_right` rhs |
| `S_FREE` 52 | `Free (P)` | `n_str` access variable |

Handler arms (from `exception` sections) are `S_WHEN` chains published
via `g_pending_handlers` and attached to the owning frame node.

## Declaration kinds (`D_*`)

| Kind | Meaning |
|------|---------|
| `D_VAR_SIMPLE` 30 | scalar var; `n_int` TY; `n_left` init; range check via `n_aux1`/`n_aux2`/`n_right` |
| `D_VAR_NAMED_ARRAY` 31 / `D_VAR_ANON_ARRAY` 32 | arrays; counts/elem type resolved; ANON: `n_left` aggregate chain, `n_right` lo |
| `D_VAR_STRING` 33 / `D_VAR_FILE` 34 / `D_VAR_DOTTED` 35 | strings, File_Type, dotted-type vars |
| `D_VAR_ACCESS` 36 | access var; `n_aux1` elem TY (TY_RECORD pools struct name in `n_arg2`) |
| `D_VAR_RECORD` 37 | record var; `n_arg2`+`n_int` type name |
| `D_TYPE_RECORD` 60 | record type; `n_str` name; `n_first` `D_FIELD` chain |
| `D_FIELD` 61 | field; `n_op` 0 scalar / 1 struct-ptr (`n_arg2`+`n_aux2` name) / 2 scalar-ptr; `n_int` TY |
| `D_TYPE_ENUM` 62 | enum type; `n_str` name; `n_first` `D_ENUM_LIT` chain; `n_op`=1 emit image fn |
| `D_ENUM_LIT` 63 | one literal; `n_str` |
| `D_SUBPROG` 64 | whole procedure/function: `n_str` resolved (mangled) name; `n_int` return TY (0 = procedure); `n_op`=1 forward decl; `n_first` `D_PARAM` chain; `n_arg2` nested decl chain; `n_left` body statement chain; `n_right` handler arms |
| `D_PARAM` 65 | parameter; `n_op` 0 scalar / 1 elem-pointer (array decay) / 2 by-value struct (`n_arg2`+`n_aux2` name); `n_int` TY |

## Backend contract and remaining seam work

A backend implements three walkers — declarations, statements
(`emit_statement_chain`), expressions — plus the handled-frame wrapper
(`emit_handled`). Everything they need is on the nodes.

Subprograms are whole subtrees: a `D_SUBPROG` carries its parameters,
nested declarations (recursively including nested subprograms — emitted
as GNU C nested functions), body, and handlers; the walker renders the
complete definition. Nesting depth at parse time is tracked by
`decl_depth` (the emitter's `indent_level` is walk-state only).

**Not yet routed through the IR** (still emitted as C text during
parsing): package unit scaffolding (`#include`s, spec prototypes), the
program preamble (`int_to_str`, `int main`), and the in-proc `package`
namespace declaration. These are the remaining Phase 3 steps; until
they land, a second backend cannot be plugged in, but the surface
shrinks with each conversion (type definitions first, then whole
subprograms — each validated byte-identically).
