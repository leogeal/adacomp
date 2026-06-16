/*
 * adacomp bootstrap compiler - C implementation
 * Hand-translated equivalent of src/adacomp.adb
 * Compiles Ada subset to C code.
 * Usage: adacomp <input.adb> <output.c>
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#define MAX_SRC    200000   /* unused: src now grows dynamically */
#define MAX_TOK    4096
#define MAX_NAME   128       /* cap on a single identifier's length */
#define MAX_NEST   64

/* Source buffer (dynamically grown to hold the whole input file). */
static char *src = NULL;
static int src_cap = 0;
static int src_len = 0;
static int src_pos = 0;
static int line_num = 1;
static const char *src_name = "<input>";  /* input file name, for diagnostics */
static int tok_line = 1;   /* line where the current token starts */
static int tok_pos = 0;    /* src index where the current token starts */

/* Token types */
enum {
    TK_EOF=0, TK_IDENT=1, TK_INT_LIT=2, TK_STR_LIT=3, TK_CHAR_LIT=4,
    TK_LPAREN=5, TK_RPAREN=6, TK_SEMI=7, TK_COLON=8, TK_ASSIGN=9,
    TK_COMMA=10, TK_DOT=11, TK_DOTDOT=12,
    TK_PLUS=13, TK_MINUS=14, TK_STAR=15, TK_SLASH=16,
    TK_EQ=17, TK_NEQ=18, TK_LT=19, TK_GT=20, TK_LE=21, TK_GE=22,
    TK_AMP=23,
    TK_WITH=30, TK_PROCEDURE=32, TK_FUNCTION=33,
    TK_IS=34, TK_BEGIN=35, TK_END=36, TK_IF=37, TK_THEN=38,
    TK_ELSIF=39, TK_ELSE=40, TK_WHILE=41, TK_LOOP=42, TK_FOR=43,
    TK_IN=44, TK_RETURN=45, TK_TYPE=46, TK_ARRAY=47, TK_OF=48,
    TK_NOT=54, TK_AND=55, TK_OR=56, TK_MOD=57, TK_NULL=58,
    TK_CONSTANT=59, TK_EXIT=60, TK_WHEN=61, TK_USE=62,
    TK_INTEGER=63, TK_CHARACTER=64, TK_BOOLEAN=65,
    TK_TRUE=66, TK_FALSE=67, TK_DECLARE=68, TK_RAISE=69,
    TK_STRING=70, TK_REVERSE=71, TK_TICK=72,
    TK_ACCESS=73, TK_NEW=74, TK_RANGE=75, TK_BOX=76, TK_RECORD=77,
    TK_PACKAGE=78, TK_CASE=79, TK_ARROW=80, TK_BAR=81
};

/* Current token */
static int tok = 0;
static char tok_val[MAX_TOK];
static int tok_len = 0;
static int tok_int = 0;

/* Symbol kinds */
enum { SK_VAR=1, SK_CONST=2, SK_PARAM=3, SK_PROC=4, SK_FUNC=5, SK_TYPE=6,
       SK_PACKAGE=7 };

/* Type kinds */
enum { TY_INTEGER=1, TY_CHARACTER=2, TY_BOOLEAN=3, TY_ARRAY=4, TY_STRING=5,
       TY_ACCESS=6, TY_RECORD=7, TY_ENUM=8 };

/* Symbol table (dynamically grown; MAX_NAME caps a single name's length,
   but the number of symbols grows without bound). */
static char (*sym_name)[MAX_NAME] = NULL;
static int *sym_nlen = NULL;
static int *sym_kind = NULL;
static int *sym_type = NULL;
static int *sym_arr_lo = NULL;
static int *sym_arr_hi = NULL;
static int *sym_arr_el = NULL;
static int *sym_arr_inner_lo = NULL;
static int *sym_arr_inner_hi = NULL;
static int *sym_scope = NULL;
static int sym_cap = 0;
static int sym_count = 0;
static int cur_scope = 0;
/* While compiling a package's declarations, the package's symbol index
   (0 = not in a package). Subprograms declared here are name-mangled
   <pkg>_<op> and tagged via sym_arr_lo so call sites mangle to match. */
static int cur_pkg = 0;

/* Grow all symbol-table arrays so index `need` (0-based) is valid. */
static void grow_syms(int need) {
    if (need < sym_cap) return;
    int new_cap = sym_cap ? sym_cap * 2 : 2048;
    if (new_cap <= need) new_cap = need + 1;
    sym_name        = realloc(sym_name, (size_t)new_cap * MAX_NAME);
    sym_nlen        = realloc(sym_nlen, (size_t)new_cap * sizeof(int));
    sym_kind        = realloc(sym_kind, (size_t)new_cap * sizeof(int));
    sym_type        = realloc(sym_type, (size_t)new_cap * sizeof(int));
    sym_arr_lo      = realloc(sym_arr_lo, (size_t)new_cap * sizeof(int));
    sym_arr_hi      = realloc(sym_arr_hi, (size_t)new_cap * sizeof(int));
    sym_arr_el      = realloc(sym_arr_el, (size_t)new_cap * sizeof(int));
    sym_arr_inner_lo = realloc(sym_arr_inner_lo, (size_t)new_cap * sizeof(int));
    sym_arr_inner_hi = realloc(sym_arr_inner_hi, (size_t)new_cap * sizeof(int));
    sym_scope       = realloc(sym_scope, (size_t)new_cap * sizeof(int));
    sym_cap = new_cap;
}

/* Scope stack */
static int scope_saved[MAX_NEST];
static int scope_depth = 0;

/* Output */
static FILE *out_file = NULL;
static int indent_level = 0;

/* Main procedure name */
static char main_name[MAX_NAME];
static int main_name_len = 0;

/* Simple `with P;` clauses (user packages) collected for #include "p.h".
   Dotted withs (Ada.Text_IO, ...) are builtins and are not collected. */
#define MAX_WITHS 32
static char with_buf[MAX_WITHS][MAX_NAME];
static int with_nlen[MAX_WITHS];
static int with_count = 0;

/* True while emitting statements for the outermost program procedure,
   so a bare Ada `return;` translates to `return 0;` in C's int main. */
static int in_main_proc = 0;

/* ---- Helpers ---- */

static int tok_eq(const char *s) {
    int slen = strlen(s);
    if (tok_len != slen) return 0;
    for (int i = 0; i < tok_len; i++) {
        if (tok_val[i] != s[i]) return 0;
    }
    return 1;
}

static int tok_eq_ci(const char *s) {
    int slen = strlen(s);
    if (tok_len != slen) return 0;
    for (int i = 0; i < tok_len; i++) {
        if (tolower((unsigned char)tok_val[i]) != tolower((unsigned char)s[i])) return 0;
    }
    return 1;
}

/* Report an error located at the current token, in the gcc-style
   `file:line:col: error: msg` form, followed by the offending source
   line and a caret under the column. */
static void error(const char *msg) {
    int ls = tok_pos;
    while (ls > 0 && src[ls - 1] != '\n') ls--;          /* line start */
    int le = tok_pos;
    while (le < src_len && src[le] != '\n') le++;        /* line end */
    int col = tok_pos - ls + 1;
    fprintf(stderr, "%s:%d:%d: error: %s\n", src_name, tok_line, col, msg);
    fprintf(stderr, "  %.*s\n", le - ls, src + ls);
    fprintf(stderr, "  ");
    for (int i = ls; i < tok_pos; i++) fputc(' ', stderr);
    fprintf(stderr, "^\n");
    exit(1);
}

/* ---- Source reading ---- */

static void read_file(const char *name) {
    FILE *f = fopen(name, "r");
    if (!f) { fprintf(stderr, "Cannot open %s\n", name); exit(1); }
    src_cap = 65536;
    src = malloc(src_cap);
    src_len = 0;
    int c;
    while ((c = fgetc(f)) != EOF) {
        if (src_len + 1 >= src_cap) {
            src_cap *= 2;
            src = realloc(src, src_cap);
        }
        src[src_len++] = (char)c;
    }
    src[src_len] = 0;
    fclose(f);
}

static char peek(void) {
    if (src_pos >= src_len) return 0;
    return src[src_pos];
}

static void advance(void) {
    if (src_pos < src_len) {
        if (src[src_pos] == '\n') line_num++;
        src_pos++;
    }
}

static void skip_space(void) {
    for (;;) {
        while (src_pos < src_len && (peek()==' ' || peek()=='\t' || peek()=='\n' || peek()=='\r'))
            advance();
        if (src_pos+1 < src_len && peek()=='-' && src[src_pos+1]=='-') {
            while (src_pos < src_len && peek()!='\n') advance();
        } else {
            break;
        }
    }
}

/* ---- Lexer ---- */

static int check_keyword(void) {
    /* Case-insensitive keyword matching */
    if (tok_eq_ci("with")) return TK_WITH;
    if (tok_eq_ci("use")) return TK_USE;
    if (tok_eq_ci("procedure")) return TK_PROCEDURE;
    if (tok_eq_ci("function")) return TK_FUNCTION;
    if (tok_eq_ci("is")) return TK_IS;
    if (tok_eq_ci("begin")) return TK_BEGIN;
    if (tok_eq_ci("end")) return TK_END;
    if (tok_eq_ci("if")) return TK_IF;
    if (tok_eq_ci("then")) return TK_THEN;
    if (tok_eq_ci("elsif")) return TK_ELSIF;
    if (tok_eq_ci("else")) return TK_ELSE;
    if (tok_eq_ci("while")) return TK_WHILE;
    if (tok_eq_ci("loop")) return TK_LOOP;
    if (tok_eq_ci("for")) return TK_FOR;
    if (tok_eq_ci("in")) return TK_IN;
    if (tok_eq_ci("reverse")) return TK_REVERSE;
    if (tok_eq_ci("return")) return TK_RETURN;
    if (tok_eq_ci("type")) return TK_TYPE;
    if (tok_eq_ci("array")) return TK_ARRAY;
    if (tok_eq_ci("of")) return TK_OF;
    if (tok_eq_ci("access")) return TK_ACCESS;
    if (tok_eq_ci("new")) return TK_NEW;
    if (tok_eq_ci("range")) return TK_RANGE;
    if (tok_eq_ci("record")) return TK_RECORD;
    if (tok_eq_ci("package")) return TK_PACKAGE;
    if (tok_eq_ci("case")) return TK_CASE;
    if (tok_eq_ci("not")) return TK_NOT;
    if (tok_eq_ci("and")) return TK_AND;
    if (tok_eq_ci("or")) return TK_OR;
    if (tok_eq_ci("mod")) return TK_MOD;
    if (tok_eq_ci("null")) return TK_NULL;
    if (tok_eq_ci("constant")) return TK_CONSTANT;
    if (tok_eq_ci("exit")) return TK_EXIT;
    if (tok_eq_ci("when")) return TK_WHEN;
    if (tok_eq_ci("Integer")) return TK_INTEGER;
    if (tok_eq_ci("integer")) return TK_INTEGER;
    if (tok_eq_ci("Character")) return TK_CHARACTER;
    if (tok_eq_ci("character")) return TK_CHARACTER;
    if (tok_eq_ci("Boolean")) return TK_BOOLEAN;
    if (tok_eq_ci("boolean")) return TK_BOOLEAN;
    if (tok_eq_ci("True")) return TK_TRUE;
    if (tok_eq_ci("true")) return TK_TRUE;
    if (tok_eq_ci("False")) return TK_FALSE;
    if (tok_eq_ci("false")) return TK_FALSE;
    if (tok_eq_ci("declare")) return TK_DECLARE;
    if (tok_eq_ci("raise")) return TK_RAISE;
    if (tok_eq_ci("Natural")) return TK_INTEGER;
    if (tok_eq_ci("Positive")) return TK_INTEGER;
    if (tok_eq_ci("String")) return TK_STRING;
    if (tok_eq_ci("Program_Error")) return TK_IDENT;
    return TK_IDENT;
}

/* Check if current position has a tick that starts an attribute (not char literal) */
static int is_attribute_tick(void) {
    /* After an identifier or type keyword, ' followed by an alpha char
       and NOT followed by closing ' after one char = attribute */
    if (src_pos + 2 < src_len && peek() == '\'') {
        char c1 = src[src_pos+1];
        char c2 = src[src_pos+2];
        if (isalpha((unsigned char)c1) && c2 != '\'') {
            return 1;
        }
    }
    return 0;
}

static void next_token(void) {
    skip_space();
    tok_line = line_num;   /* record where this token starts, for diagnostics */
    tok_pos = src_pos;
    tok_len = 0;
    tok_int = 0;

    if (src_pos >= src_len) { tok = TK_EOF; return; }

    /* Identifiers and keywords */
    if (isalpha((unsigned char)peek()) || peek() == '_') {
        while (src_pos < src_len && (isalnum((unsigned char)peek()) || peek()=='_')) {
            tok_val[tok_len++] = peek();
            advance();
        }
        tok_val[tok_len] = 0;
        tok = check_keyword();
        /* The apostrophe after an identifier (e.g. `S'Length`, `Integer'Image`)
           is intentionally NOT consumed here — the parser receives a TK_TICK
           next and dispatches based on the prefix, which we'd otherwise lose. */
        return;
    }

    /* Integer literals */
    if (isdigit((unsigned char)peek())) {
        while (src_pos < src_len && isdigit((unsigned char)peek())) {
            tok_int = tok_int * 10 + (peek() - '0');
            tok_val[tok_len++] = peek();
            advance();
        }
        tok_val[tok_len] = 0;
        tok = TK_INT_LIT;
        return;
    }

    /* String literals. Ada doubles `"` to embed a literal quote inside a
       string ("" -> "), so each `"` we encounter must be checked against
       its follower before being treated as the closer. */
    if (peek() == '"') {
        advance();
        while (src_pos < src_len) {
            if (peek() == '"') {
                if (src_pos + 1 < src_len && src[src_pos + 1] == '"') {
                    tok_val[tok_len++] = '"';
                    advance();
                    advance();
                } else {
                    advance();
                    break;
                }
            } else {
                tok_val[tok_len++] = peek();
                advance();
            }
        }
        tok_val[tok_len] = 0;
        tok = TK_STR_LIT;
        return;
    }

    /* Character literals */
    if (peek() == '\'' && src_pos+2 < src_len && src[src_pos+2] == '\'') {
        advance(); /* skip opening ' */
        tok_val[0] = peek();
        tok_len = 1;
        tok_val[1] = 0;
        advance(); /* skip char */
        advance(); /* skip closing ' */
        tok = TK_CHAR_LIT;
        return;
    }

    /* Two-character tokens */
    {
        char c = peek();
        advance();
        switch (c) {
        case ':':
            if (src_pos < src_len && peek()=='=') { advance(); tok=TK_ASSIGN; }
            else tok=TK_COLON;
            break;
        case '.':
            if (src_pos < src_len && peek()=='.') { advance(); tok=TK_DOTDOT; }
            else tok=TK_DOT;
            break;
        case '/':
            if (src_pos < src_len && peek()=='=') { advance(); tok=TK_NEQ; }
            else tok=TK_SLASH;
            break;
        case '<':
            if (src_pos < src_len && peek()=='=') { advance(); tok=TK_LE; }
            else if (src_pos < src_len && peek()=='>') { advance(); tok=TK_BOX; }
            else tok=TK_LT;
            break;
        case '>':
            if (src_pos < src_len && peek()=='=') { advance(); tok=TK_GE; }
            else tok=TK_GT;
            break;
        case '(': tok=TK_LPAREN; break;
        case ')': tok=TK_RPAREN; break;
        case ';': tok=TK_SEMI; break;
        case ',': tok=TK_COMMA; break;
        case '+': tok=TK_PLUS; break;
        case '-': tok=TK_MINUS; break;
        case '*': tok=TK_STAR; break;
        case '=':
            if (src_pos < src_len && peek()=='>') { advance(); tok=TK_ARROW; }
            else tok=TK_EQ;
            break;
        case '&': tok=TK_AMP; break;
        case '\'': tok=TK_TICK; break;
        case '|': tok=TK_BAR; break;
        default:
            error("unexpected character");
        }
    }
}

static void expect(int expected) {
    if (tok != expected) {
        error("unexpected token");
    }
    next_token();
}

/* Forward decls needed by lookahead helpers below. */
static int find_sym(const char *n, int nlen);

/* Save and restore full lexer state for lookahead. */
typedef struct { int src_pos, line, tok, tok_len, tok_int; char tok_val[MAX_TOK]; } LexState;
static void save_lex(LexState *s) {
    s->src_pos = src_pos; s->line = line_num;
    s->tok = tok; s->tok_len = tok_len; s->tok_int = tok_int;
    memcpy(s->tok_val, tok_val, tok_len);
    s->tok_val[tok_len] = 0;
}
static void restore_lex(const LexState *s) {
    src_pos = s->src_pos; line_num = s->line;
    tok = s->tok; tok_len = s->tok_len; tok_int = s->tok_int;
    memcpy(tok_val, s->tok_val, s->tok_len);
    tok_val[s->tok_len] = 0;
}

/* Look ahead from the current position (just past a consumed '(')
   to determine whether a top-level ',' appears before the matching ')'.
   Saves and restores all lexer state. */
static int has_arg_separator_ahead(void) {
    int save_src_pos = src_pos;
    int save_line = line_num;
    int save_tok = tok;
    int save_tok_len = tok_len;
    int save_tok_int = tok_int;
    char save_tok_val[MAX_TOK];
    memcpy(save_tok_val, tok_val, tok_len);
    save_tok_val[save_tok_len] = 0;

    int depth = 0;
    int found = 0;
    while (tok != TK_EOF) {
        if (tok == TK_LPAREN) depth++;
        else if (tok == TK_RPAREN) {
            if (depth == 0) break;
            depth--;
        } else if (tok == TK_COMMA && depth == 0) {
            found = 1;
            break;
        }
        next_token();
    }

    src_pos = save_src_pos;
    line_num = save_line;
    tok = save_tok;
    tok_len = save_tok_len;
    tok_int = save_tok_int;
    memcpy(tok_val, save_tok_val, save_tok_len);
    tok_val[save_tok_len] = 0;
    return found;
}

/* Given we're positioned just past `(` of a 2-arg call (and we already
   confirmed a top-level comma is present), look ahead to determine
   whether the second argument is character-typed. Saves/restores state. */
static int second_arg_is_char(void) {
    LexState s;
    save_lex(&s);
    int depth = 0;
    int reached_comma = 0;
    while (tok != TK_EOF) {
        if (tok == TK_LPAREN) { depth++; next_token(); continue; }
        if (tok == TK_RPAREN) {
            if (depth == 0) break;
            depth--; next_token(); continue;
        }
        if (tok == TK_COMMA && depth == 0) {
            next_token();
            reached_comma = 1;
            break;
        }
        next_token();
    }
    int is_char = 0;
    if (reached_comma) {
        if (tok == TK_CHAR_LIT) {
            is_char = 1;
        } else if (tok == TK_IDENT) {
            int idx = find_sym(tok_val, tok_len);
            if (idx >= 0) {
                if (sym_type[idx] == TY_CHARACTER) {
                    is_char = 1;
                } else if (sym_type[idx] == TY_ARRAY &&
                           sym_arr_el[idx] == TY_CHARACTER) {
                    /* Array of Character indexed: Buf(I) yields a char. */
                    next_token();
                    if (tok == TK_LPAREN) is_char = 1;
                }
            }
        }
    }
    restore_lex(&s);
    return is_char;
}

/* Whether the argument at the current position (just past a consumed `(`)
   is character-typed — used to pick ada_put_char vs ada_put_str for the
   one-argument Put form. */
static int first_arg_is_char(void) {
    LexState s;
    save_lex(&s);
    int is_char = 0;
    if (tok == TK_CHAR_LIT) {
        is_char = 1;
    } else if (tok == TK_IDENT) {
        int idx = find_sym(tok_val, tok_len);
        if (idx >= 0) {
            if (sym_type[idx] == TY_CHARACTER) {
                is_char = 1;
            } else if (sym_type[idx] == TY_ARRAY &&
                       sym_arr_el[idx] == TY_CHARACTER) {
                next_token();
                if (tok == TK_LPAREN) is_char = 1;
            }
        }
    }
    restore_lex(&s);
    return is_char;
}

/* ---- Emitter ---- */

static void emit_char(char c) { fputc(c, out_file); }
static void emit(const char *s) { fputs(s, out_file); }
static void emit_line(const char *s) { fprintf(out_file, "%s\n", s); }
static void emit_indent(void) { for (int i=0; i<indent_level; i++) fputs("    ", out_file); }
static void emit_int(int n) { fprintf(out_file, "%d", n); }
static void emit_tok_val(void) { for (int i=0; i<tok_len; i++) fputc(tok_val[i], out_file); }
static void emit_name_lower(void) { for (int i=0; i<tok_len; i++) fputc(tolower((unsigned char)tok_val[i]), out_file); }

/* ---- Symbol table ---- */

static int sym_name_eq(int idx, const char *n, int nlen) {
    if (sym_nlen[idx] != nlen) return 0;
    for (int i = 0; i < nlen; i++) {
        if (tolower((unsigned char)sym_name[idx][i]) != tolower((unsigned char)n[i])) return 0;
    }
    return 1;
}

static int find_sym(const char *n, int nlen) {
    for (int i = sym_count - 1; i >= 0; i--) {
        if (sym_name_eq(i, n, nlen)) return i;
    }
    return -1;
}

static void add_sym(int kind, int typ) {
    grow_syms(sym_count);
    memcpy(sym_name[sym_count], tok_val, tok_len);
    sym_nlen[sym_count] = tok_len;
    sym_kind[sym_count] = kind;
    sym_type[sym_count] = typ;
    /* Ada Strings (and String params) are 1-indexed by default. */
    sym_arr_lo[sym_count] = (typ == TY_STRING) ? 1 : 0;
    sym_arr_hi[sym_count] = 0;
    sym_arr_el[sym_count] = 0;
    sym_arr_inner_lo[sym_count] = 0;
    sym_arr_inner_hi[sym_count] = 0;
    sym_scope[sym_count] = cur_scope;
    sym_count++;
}

static void push_scope(void) {
    scope_saved[scope_depth++] = sym_count;
    cur_scope++;
}

static void pop_scope(void) {
    sym_count = scope_saved[--scope_depth];
    cur_scope--;
}

/* ---- AST (expressions only, for now) ----

   The parser builds an explicit tree for each top-level expression, then
   the emitter walks it. Direct emission still drives statements and
   declarations — Phase 1 introduces the AST incrementally. Index 0 is
   reserved as "no node"; allocations start at 1. */

/* (former AST caps; the node store and string pool now grow dynamically) */

enum {
    A_INT_LIT=1, A_CHAR_LIT=2, A_STR_LIT=3, A_BOOL_LIT=4,
    A_IDENT=5,
    A_UNARY=6, A_BINARY=7,
    A_INDEX=8, A_INDEX2=9,
    A_CALL=10, A_DOTTED=11,
    A_ATTR_TYPE=12, A_ATTR_VAR=13, A_NEW=14, A_FIELD=15,
    /* Statement leaf nodes. Compound (if/while/for/loop/declare/begin) and
       dotted-package statements still emit directly; they'll become full
       AST nodes once declarations are AST-driven (step 4). */
    S_NULL=20, S_RETURN=21, S_RAISE=22, S_EXIT=23,
    S_ASSIGN=24, S_CALL=25, S_PARAMLESS=26, S_ARRAY_ASSIGN=27,
    S_FIELD_ASSIGN=28,
    /* Compound statements and dotted package calls (Pass B.2): full
       subtree nodes, so a program unit's body is one tree walked after
       the unit is fully parsed. */
    S_IF=40, S_ELSIF=41, S_WHILE=42, S_LOOP=43, S_FOR=44,
    S_DECLARE=45, S_BLOCK=46, S_PKG=47, S_CASE=48, S_WHEN=49,
    /* Variable-declaration leaf nodes. Type definitions and procedure /
       function declarations still emit directly during parse and return
       0 from parse_declaration_ast. */
    D_VAR_SIMPLE=30,       /* X : Integer [:= expr]; (Integer / Character / Boolean) */
    D_VAR_NAMED_ARRAY=31,  /* X : Some_Named_Array_Type; */
    D_VAR_ANON_ARRAY=32,   /* X : array (lo..hi) of T; */
    D_VAR_STRING=33,       /* X : String [:= expr]; */
    D_VAR_FILE=34,         /* X : Ada.Text_IO.File_Type; */
    D_VAR_DOTTED=35,       /* X : Some.Other.Dotted_Type [:= expr]; (treated as int) */
    D_VAR_ACCESS=36,       /* X : Some_Access_Type [:= expr]; -> Elem *x = NULL; */
    D_VAR_RECORD=37        /* X : Some_Record_Type; -> struct t x = {0}; */
};

enum {
    OP_ADD=1, OP_SUB=2, OP_MUL=3, OP_DIV=4, OP_MOD=5,
    OP_EQ=6, OP_NEQ=7, OP_LT=8, OP_GT=9, OP_LE=10, OP_GE=11,
    OP_AND=12, OP_OR=13,
    OP_NEG=14, OP_NOT=15
};

enum {
    ATTR_IMAGE=1, ATTR_POS=2, ATTR_VAL=3,
    ATTR_LENGTH=4, ATTR_FIRST=5, ATTR_LAST=6
};

/* Sub-ops for S_PKG (dotted Ada.Text_IO.* statement calls). */
enum {
    PKG_PUT_LINE=1, PKG_PUT=2, PKG_NEW_LINE=3, PKG_OPEN=4,
    PKG_CREATE=5, PKG_CLOSE=6, PKG_GET_LINE=7, PKG_GET=8, PKG_GENERIC=9
};

/* AST node store: 13 parallel arrays grown in lock-step, plus a string
   pool. Both grow on demand; reset_ast() only rewinds the lengths and
   keeps the capacity, so a unit's peak allocation is reached once and
   reused for every later unit. */
static int *n_kind = NULL;
static int *n_op = NULL;       /* literal value / op code / sub-op / subtrahend */
static int *n_int = NULL;      /* literal value / sym index / sub-name length for DOTTED */
static int *n_str_off = NULL;  /* name/string pool offset */
static int *n_str_len = NULL;  /* name/string length */
static int *n_left = NULL;     /* primary operand: UNARY operand, BINARY lhs, INDEX base, ATTR arg */
static int *n_right = NULL;    /* BINARY rhs, INDEX/INDEX2 index expression */
static int *n_arg2 = NULL;     /* INDEX2 second index, DOTTED sub-name offset */
static int *n_first = NULL;    /* CALL/DOTTED arg list head */
static int *n_next = NULL;     /* sibling pointer in arg lists */
static int *n_aux1 = NULL;     /* resolved-at-build scratch: inner subtrahend / el type / had-parens */
static int *n_aux2 = NULL;     /* resolved-at-build scratch: outer dim count */
static int *n_line = NULL;     /* source line at parse time */
static int n_cap = 0;
static int n_count = 1;        /* index 0 reserved; first real allocation at 1 */

static char *npool = NULL;
static int npool_cap = 0;
static int npool_len = 0;

/* Grow all node arrays so index `need` is valid. */
static void grow_nodes(int need) {
    if (need < n_cap) return;
    int new_cap = n_cap ? n_cap * 2 : 16384;
    if (new_cap <= need) new_cap = need + 1;
    n_kind    = realloc(n_kind, (size_t)new_cap * sizeof(int));
    n_op      = realloc(n_op, (size_t)new_cap * sizeof(int));
    n_int     = realloc(n_int, (size_t)new_cap * sizeof(int));
    n_str_off = realloc(n_str_off, (size_t)new_cap * sizeof(int));
    n_str_len = realloc(n_str_len, (size_t)new_cap * sizeof(int));
    n_left    = realloc(n_left, (size_t)new_cap * sizeof(int));
    n_right   = realloc(n_right, (size_t)new_cap * sizeof(int));
    n_arg2    = realloc(n_arg2, (size_t)new_cap * sizeof(int));
    n_first   = realloc(n_first, (size_t)new_cap * sizeof(int));
    n_next    = realloc(n_next, (size_t)new_cap * sizeof(int));
    n_aux1    = realloc(n_aux1, (size_t)new_cap * sizeof(int));
    n_aux2    = realloc(n_aux2, (size_t)new_cap * sizeof(int));
    n_line    = realloc(n_line, (size_t)new_cap * sizeof(int));
    n_cap = new_cap;
}

static void reset_ast(void) {
    n_count = 1;
    npool_len = 0;
}

static int new_node(int kind) {
    grow_nodes(n_count);
    int n = n_count++;
    n_kind[n] = kind;
    n_op[n] = 0;
    n_int[n] = 0;
    n_str_off[n] = 0;
    n_str_len[n] = 0;
    n_left[n] = 0;
    n_right[n] = 0;
    n_arg2[n] = 0;
    n_first[n] = 0;
    n_next[n] = 0;
    n_aux1[n] = 0;
    n_aux2[n] = 0;
    n_line[n] = line_num;
    return n;
}

static int pool_str(const char *s, int len) {
    if (npool_len + len > npool_cap) {
        int new_cap = npool_cap ? npool_cap : 65536;
        while (new_cap < npool_len + len) new_cap *= 2;
        npool = realloc(npool, (size_t)new_cap);
        npool_cap = new_cap;
    }
    int off = npool_len;
    for (int i = 0; i < len; i++) npool[npool_len++] = s[i];
    return off;
}

/* Set node n's call name: <pkg>_<name> when the callee is a package
   subprogram (tagged in sym_arr_lo), else <name>. Resolves the mangling
   at build time so the walker stays symbol-table-independent. */
static void set_call_name(int n, const char *name, int len, int sidx) {
    if (sidx >= 0 && (sym_kind[sidx] == SK_PROC || sym_kind[sidx] == SK_FUNC)
        && sym_arr_lo[sidx] != 0) {
        int pk = sym_arr_lo[sidx] - 1;   /* stored as index + 1 */
        char buf[MAX_TOK + MAX_NAME + 2];
        int blen = 0;
        for (int i = 0; i < sym_nlen[pk]; i++) buf[blen++] = sym_name[pk][i];
        buf[blen++] = '_';
        for (int i = 0; i < len; i++) buf[blen++] = name[i];
        n_str_off[n] = pool_str(buf, blen);
        n_str_len[n] = blen;
    } else {
        n_str_off[n] = pool_str(name, len);
        n_str_len[n] = len;
    }
}

/* ---- Forward declarations ---- */
static void parse_expression(void);
static int  parse_expression_ast(void);
static int  parse_comparison_ast(void);
static int  parse_term_ast(void);
static int  parse_factor_ast(void);
static int  parse_primary_ast(void);
static void emit_expression_ast(int n);
static int  parse_statement_ast(void);
static void emit_statement_ast(int n);
static int  parse_statement_chain(void);
static void emit_statement_chain(int head);
static void parse_statements(void);
static void parse_declarations(void);
static int  parse_declaration_ast(void);
static void emit_declaration_ast(int n);
static int  parse_var_decl_chain(void);
static void emit_declaration_chain(int head);

/* ---- Type reference ---- */
static int parse_type_ref(void) {
    if (tok == TK_INTEGER) { next_token(); return TY_INTEGER; }
    if (tok == TK_CHARACTER) { next_token(); return TY_CHARACTER; }
    if (tok == TK_BOOLEAN) { next_token(); return TY_BOOLEAN; }
    if (tok == TK_STRING) { next_token(); return TY_STRING; }
    if (tok == TK_IDENT) {
        int idx = find_sym(tok_val, tok_len);
        int is_file_type = 0;
        next_token();
        /* Handle dotted type names: Ada.Text_IO.File_Type */
        while (tok == TK_DOT) {
            next_token();
            if (tok == TK_IDENT || tok == TK_INTEGER || tok == TK_CHARACTER) {
                if (tok_eq_ci("File_Type")) is_file_type = 1;
                next_token();
            }
        }
        if (is_file_type) return TY_INTEGER; /* FILE* mapped to int placeholder */
        if (idx >= 0 && sym_kind[idx] == SK_TYPE) return sym_type[idx];
        return TY_INTEGER;
    }
    /* Skip unexpected tokens in type position */
    while (tok == TK_DOT) {
        next_token();
        if (tok == TK_IDENT || tok == TK_INTEGER || tok == TK_CHARACTER)
            next_token();
    }
    return TY_INTEGER;
}

static void emit_c_type(int typ) {
    switch (typ) {
    case TY_INTEGER:   emit("int"); break;
    case TY_CHARACTER: emit("char"); break;
    case TY_BOOLEAN:   emit("int"); break;
    case TY_STRING:    emit("const char *"); break;
    case TY_ENUM:      emit("int"); break;   /* enums are plain ints */
    default:           emit("int"); break;
    }
}

/* ---- Expression parser ---- */

static void emit_str_lower(const char *s, int len) {
    for (int i = 0; i < len; i++) fputc(tolower((unsigned char)s[i]), out_file);
}

static void emit_str_upper(const char *s, int len) {
    for (int i = 0; i < len; i++) fputc(toupper((unsigned char)s[i]), out_file);
}

/* Emit `#include "<pkg>.h"` for each simple `with` clause collected. */
static void emit_with_includes(void) {
    for (int i = 0; i < with_count; i++) {
        emit("#include \"");
        emit_str_lower(with_buf[i], with_nlen[i]);
        emit_line(".h\"");
    }
}

/* A subprogram's emitted C name: <pkg>_<name> when declared inside a
   package, else just <name>. cur_pkg is the package symbol index + 1
   (0 = not in a package), so package symbol index 0 isn't ambiguous. */
static void emit_sub_name(const char *s, int len) {
    if (cur_pkg) {
        emit_str_lower(sym_name[cur_pkg - 1], sym_nlen[cur_pkg - 1]);
        emit("_");
    }
    emit_str_lower(s, len);
}

static int parse_primary_ast(void) {
    int n;
    if (tok == TK_INT_LIT) {
        n = new_node(A_INT_LIT);
        n_int[n] = tok_int;
        next_token();
        return n;
    }
    if (tok == TK_CHAR_LIT) {
        n = new_node(A_CHAR_LIT);
        n_int[n] = (int)(unsigned char)tok_val[0];
        next_token();
        return n;
    }
    if (tok == TK_STR_LIT) {
        n = new_node(A_STR_LIT);
        n_str_off[n] = pool_str(tok_val, tok_len);
        n_str_len[n] = tok_len;
        next_token();
        return n;
    }
    if (tok == TK_TRUE) {
        n = new_node(A_BOOL_LIT);
        n_int[n] = 1;
        next_token();
        return n;
    }
    if (tok == TK_FALSE) {
        n = new_node(A_BOOL_LIT);
        n_int[n] = 0;
        next_token();
        return n;
    }
    if (tok == TK_NOT) {
        next_token();
        n = new_node(A_UNARY);
        n_op[n] = OP_NOT;
        n_left[n] = parse_primary_ast();
        return n;
    }
    if (tok == TK_MINUS) {
        next_token();
        n = new_node(A_UNARY);
        n_op[n] = OP_NEG;
        n_left[n] = parse_primary_ast();
        return n;
    }
    if (tok == TK_NEW) {
        /* Allocator: `new <ArrayType> (lo .. hi)` -> malloc of that many
           elements. Element type (for sizeof) in n_op; bound expressions
           in n_left (lo) and n_right (hi). */
        next_token();
        int el = TY_INTEGER;
        if (tok == TK_IDENT) {
            int ti = find_sym(tok_val, tok_len);
            if (ti >= 0 && sym_kind[ti] == SK_TYPE) el = sym_arr_el[ti];
            next_token();
        } else {
            el = parse_type_ref();
        }
        n = new_node(A_NEW);
        n_op[n] = el;
        expect(TK_LPAREN);
        n_left[n] = parse_expression_ast();
        expect(TK_DOTDOT);
        n_right[n] = parse_expression_ast();
        expect(TK_RPAREN);
        return n;
    }
    if (tok == TK_LPAREN) {
        /* Parens contribute no node; the inner expression carries through. */
        next_token();
        n = parse_expression_ast();
        expect(TK_RPAREN);
        return n;
    }
    if (tok == TK_INTEGER || tok == TK_CHARACTER || tok == TK_BOOLEAN) {
        /* Type-name attribute: Integer'Image (X), Character'Pos (X), Character'Val (X). */
        next_token();
        if (tok != TK_TICK) error("expected ' after type name");
        next_token();
        char attr[MAX_NAME];
        int attr_len = tok_len;
        memcpy(attr, tok_val, tok_len);
        next_token();
        n = new_node(A_ATTR_TYPE);
        if (attr_len == 5 && strncasecmp(attr, "Image", 5) == 0)      n_op[n] = ATTR_IMAGE;
        else if (attr_len == 3 && strncasecmp(attr, "Pos", 3) == 0)   n_op[n] = ATTR_POS;
        else if (attr_len == 3 && strncasecmp(attr, "Val", 3) == 0)   n_op[n] = ATTR_VAL;
        else error("unsupported type-name attribute");
        expect(TK_LPAREN);
        n_left[n] = parse_expression_ast();
        expect(TK_RPAREN);
        return n;
    }
    if (tok == TK_IDENT) {
        char saved[MAX_TOK];
        int saved_len = tok_len;
        memcpy(saved, tok_val, tok_len);
        int sidx = find_sym(tok_val, tok_len);
        next_token();

        /* Variable-prefix attribute: S'Length, S'First, S'Last */
        if (tok == TK_TICK) {
            next_token();
            char attr[MAX_NAME];
            int attr_len = tok_len;
            memcpy(attr, tok_val, tok_len);
            next_token();
            n = new_node(A_ATTR_VAR);
            n_str_off[n] = pool_str(saved, saved_len);
            n_str_len[n] = saved_len;
            if (attr_len == 6 && strncasecmp(attr, "Length", 6) == 0)     n_op[n] = ATTR_LENGTH;
            else if (attr_len == 5 && strncasecmp(attr, "First", 5) == 0) n_op[n] = ATTR_FIRST;
            else if (attr_len == 4 && strncasecmp(attr, "Last", 4) == 0)  n_op[n] = ATTR_LAST;
            else error("unsupported variable attribute");
            return n;
        }

        if (tok == TK_LPAREN) {
            if (sidx >= 0 && (sym_kind[sidx]==SK_PROC || sym_kind[sidx]==SK_FUNC)) {
                /* Function/procedure call: name(arg, arg, ...) */
                next_token();
                n = new_node(A_CALL);
                set_call_name(n, saved, saved_len, sidx);
                n_int[n] = sidx;
                if (tok != TK_RPAREN) {
                    int first = parse_expression_ast();
                    n_first[n] = first;
                    int prev = first;
                    while (tok == TK_COMMA) {
                        next_token();
                        int arg = parse_expression_ast();
                        n_next[prev] = arg;
                        prev = arg;
                    }
                }
                expect(TK_RPAREN);
                return n;
            }
            /* Array indexing. The base name is held in str_off/str_len.
               The outer index subtrahend (Ada lower bound, or 1 when the
               name is unresolved) is resolved here at build time into n_op,
               and the inner subtrahend into n_aux1, so the walker never
               reads the symbol table — letting the walk be deferred. */
            next_token();
            n = new_node(A_INDEX);
            n_str_off[n] = pool_str(saved, saved_len);
            n_str_len[n] = saved_len;
            n_op[n] = (sidx >= 0) ? sym_arr_lo[sidx] : 1;
            n_right[n] = parse_expression_ast();
            expect(TK_RPAREN);
            if (tok == TK_LPAREN && sidx >= 0 && sym_arr_inner_hi[sidx] != 0) {
                next_token();
                n_kind[n] = A_INDEX2;
                n_aux1[n] = sym_arr_inner_lo[sidx];
                n_arg2[n] = parse_expression_ast();
                expect(TK_RPAREN);
            }
            return n;
        }

        if (tok == TK_DOT && sidx >= 0
            && (sym_kind[sidx]==SK_VAR || sym_kind[sidx]==SK_PARAM || sym_kind[sidx]==SK_CONST)
            && sym_type[sidx]==TY_RECORD) {
            /* Record field access: var.field -> var.field */
            next_token();   /* consume '.' */
            n = new_node(A_FIELD);
            n_str_off[n] = pool_str(saved, saved_len);
            n_str_len[n] = saved_len;
            n_arg2[n] = pool_str(tok_val, tok_len);
            n_int[n] = tok_len;
            next_token();   /* consume field name */
            return n;
        }

        if (tok == TK_DOT) {
            /* Dotted name: Pkg.func or Pkg.Sub.func, possibly with parens. */
            next_token();
            char sub[MAX_TOK];
            int sub_len = tok_len;
            memcpy(sub, tok_val, tok_len);
            next_token();
            while (tok == TK_DOT) {
                next_token();
                sub_len = tok_len;
                memcpy(sub, tok_val, tok_len);
                next_token();
            }
            n = new_node(A_DOTTED);
            n_str_off[n] = pool_str(saved, saved_len);
            n_str_len[n] = saved_len;
            n_arg2[n]    = pool_str(sub, sub_len);
            n_int[n]     = sub_len;            /* sub-name length */
            if (tok == TK_LPAREN) {
                next_token();
                if (tok != TK_RPAREN) {
                    int first = parse_expression_ast();
                    n_first[n] = first;
                    int prev = first;
                    while (tok == TK_COMMA) {
                        next_token();
                        int arg = parse_expression_ast();
                        n_next[prev] = arg;
                        prev = arg;
                    }
                }
                expect(TK_RPAREN);
            }
            return n;
        }

        /* Simple variable, or parameterless function call. Whether the
           trailing "()" is needed is resolved here into n_op so the
           walker is symbol-table-independent. */
        n = new_node(A_IDENT);
        n_str_off[n] = pool_str(saved, saved_len);
        n_str_len[n] = saved_len;
        n_op[n] = (sidx >= 0 && sym_kind[sidx] == SK_FUNC) ? 1 : 0;
        return n;
    }
    error("expected expression");
    return 0;
}

static int parse_factor_ast(void) {
    int lhs = parse_primary_ast();
    while (tok == TK_STAR || tok == TK_SLASH || tok == TK_MOD) {
        int op;
        if (tok == TK_STAR)       op = OP_MUL;
        else if (tok == TK_SLASH) op = OP_DIV;
        else                      op = OP_MOD;
        next_token();
        int rhs = parse_primary_ast();
        int n = new_node(A_BINARY);
        n_op[n] = op;
        n_left[n] = lhs;
        n_right[n] = rhs;
        lhs = n;
    }
    return lhs;
}

static int parse_term_ast(void) {
    int lhs = parse_factor_ast();
    while (tok == TK_PLUS || tok == TK_MINUS || tok == TK_AMP) {
        int op;
        if (tok == TK_PLUS)       op = OP_ADD;
        else if (tok == TK_MINUS) op = OP_SUB;
        else                      op = OP_ADD; /* `&` → simplified concat */
        next_token();
        int rhs = parse_factor_ast();
        int n = new_node(A_BINARY);
        n_op[n] = op;
        n_left[n] = lhs;
        n_right[n] = rhs;
        lhs = n;
    }
    return lhs;
}

static int parse_comparison_ast(void) {
    int lhs = parse_term_ast();
    int op = 0;
    if      (tok == TK_EQ)  op = OP_EQ;
    else if (tok == TK_NEQ) op = OP_NEQ;
    else if (tok == TK_LT)  op = OP_LT;
    else if (tok == TK_GT)  op = OP_GT;
    else if (tok == TK_LE)  op = OP_LE;
    else if (tok == TK_GE)  op = OP_GE;
    if (op != 0) {
        next_token();
        int rhs = parse_term_ast();
        int n = new_node(A_BINARY);
        n_op[n] = op;
        n_left[n] = lhs;
        n_right[n] = rhs;
        return n;
    }
    return lhs;
}

static int parse_expression_ast(void) {
    int lhs = parse_comparison_ast();
    while (tok == TK_AND || tok == TK_OR) {
        int op;
        if (tok == TK_AND) {
            op = OP_AND;
            next_token();
            if (tok == TK_THEN) next_token(); /* `and then` */
        } else {
            op = OP_OR;
            next_token();
            if (tok == TK_ELSE) next_token(); /* `or else` */
        }
        int rhs = parse_comparison_ast();
        int n = new_node(A_BINARY);
        n_op[n] = op;
        n_left[n] = lhs;
        n_right[n] = rhs;
        lhs = n;
    }
    return lhs;
}

/* Emit a name from the AST string pool in lowercase. */
static void emit_pool_lower(int off, int len) {
    for (int i = 0; i < len; i++)
        fputc(tolower((unsigned char)npool[off + i]), out_file);
}

static void emit_expression_ast(int n) {
    if (n == 0) return;
    int kind = n_kind[n];
    if (kind == A_INT_LIT) {
        emit_int(n_int[n]);
    } else if (kind == A_CHAR_LIT) {
        char c = (char)n_int[n];
        emit("'");
        if (c == '\'') emit("\\'");
        else if (c == '\\') emit("\\\\");
        else emit_char(c);
        emit("'");
    } else if (kind == A_STR_LIT) {
        emit("\"");
        for (int i = 0; i < n_str_len[n]; i++) {
            char c = npool[n_str_off[n] + i];
            if (c == '"') emit("\\\"");
            else if (c == '\\') emit("\\\\");
            else if (c == '\n') emit("\\n");
            else emit_char(c);
        }
        emit("\"");
    } else if (kind == A_BOOL_LIT) {
        emit(n_int[n] ? "1" : "0");
    } else if (kind == A_IDENT) {
        emit_pool_lower(n_str_off[n], n_str_len[n]);
        if (n_op[n]) emit("()");   /* resolved paramless-function call */
    } else if (kind == A_UNARY) {
        emit(n_op[n] == OP_NEG ? "-" : "!");
        emit_expression_ast(n_left[n]);
    } else if (kind == A_BINARY) {
        /* Wrap binary subtrees in parens so source-explicit groupings
           survive the AST round-trip and C-precedence ambiguities are
           impossible. The output is verbose but unambiguously correct. */
        emit("(");
        emit_expression_ast(n_left[n]);
        switch (n_op[n]) {
        case OP_ADD: emit(" + "); break;
        case OP_SUB: emit(" - "); break;
        case OP_MUL: emit(" * "); break;
        case OP_DIV: emit(" / "); break;
        case OP_MOD: emit(" % "); break;
        case OP_EQ:  emit(" == "); break;
        case OP_NEQ: emit(" != "); break;
        case OP_LT:  emit(" < ");  break;
        case OP_GT:  emit(" > ");  break;
        case OP_LE:  emit(" <= "); break;
        case OP_GE:  emit(" >= "); break;
        case OP_AND: emit(" && "); break;
        case OP_OR:  emit(" || "); break;
        }
        emit_expression_ast(n_right[n]);
        emit(")");
    } else if (kind == A_INDEX) {
        emit_pool_lower(n_str_off[n], n_str_len[n]);
        emit("[");
        emit_expression_ast(n_right[n]);
        emit(" - "); emit_int(n_op[n]);   /* resolved outer subtrahend */
        emit("]");
    } else if (kind == A_INDEX2) {
        emit_pool_lower(n_str_off[n], n_str_len[n]);
        emit("[");
        emit_expression_ast(n_right[n]);
        emit(" - "); emit_int(n_op[n]);    /* resolved outer subtrahend */
        emit("][");
        emit_expression_ast(n_arg2[n]);
        emit(" - "); emit_int(n_aux1[n]);  /* resolved inner subtrahend */
        emit("]");
    } else if (kind == A_CALL) {
        emit_pool_lower(n_str_off[n], n_str_len[n]);
        emit("(");
        int a = n_first[n];
        int first = 1;
        while (a != 0) {
            if (!first) emit(", ");
            first = 0;
            emit_expression_ast(a);
            a = n_next[a];
        }
        emit(")");
    } else if (kind == A_ATTR_TYPE) {
        if (n_op[n] == ATTR_IMAGE) {
            emit("int_to_str(");
            emit_expression_ast(n_left[n]);
            emit(")");
        } else if (n_op[n] == ATTR_POS) {
            emit("((int)(");
            emit_expression_ast(n_left[n]);
            emit("))");
        } else if (n_op[n] == ATTR_VAL) {
            emit("((char)(");
            emit_expression_ast(n_left[n]);
            emit("))");
        }
    } else if (kind == A_ATTR_VAR) {
        if (n_op[n] == ATTR_LENGTH || n_op[n] == ATTR_LAST) {
            emit("(int)strlen(");
            emit_pool_lower(n_str_off[n], n_str_len[n]);
            emit(")");
        } else if (n_op[n] == ATTR_FIRST) {
            emit("1");
        }
    } else if (kind == A_NEW) {
        /* new T (lo..hi) -> malloc(((hi) - (lo) + 1) * sizeof(T)) */
        emit("malloc((");
        emit_expression_ast(n_right[n]);
        emit(" - ");
        emit_expression_ast(n_left[n]);
        emit(" + 1) * sizeof(");
        emit_c_type(n_op[n]);
        emit("))");
    } else if (kind == A_FIELD) {
        /* record field access: base.field */
        emit_pool_lower(n_str_off[n], n_str_len[n]);
        emit(".");
        emit_pool_lower(n_arg2[n], n_int[n]);
    } else if (kind == A_DOTTED) {
        int sub_off = n_arg2[n];
        int sub_len = n_int[n];
        if (sub_len == 14 && strncasecmp(npool + sub_off, "Argument_Count", 14) == 0) {
            emit("(argc - 1)");
        } else if (sub_len == 8 && strncasecmp(npool + sub_off, "Argument", 8) == 0) {
            emit("argv[");
            emit_expression_ast(n_first[n]);
            emit("]");
        } else if (sub_len == 11 && strncasecmp(npool + sub_off, "End_Of_File", 11) == 0) {
            emit("feof(");
            emit_expression_ast(n_first[n]);
            emit(")");
        } else if (sub_len == 8 && strncasecmp(npool + sub_off, "Get_Line", 8) == 0) {
            emit("ada_get_line(");
            emit_expression_ast(n_first[n]);
            emit(")");
        } else {
            emit_pool_lower(n_str_off[n], n_str_len[n]);
            emit("_");
            emit_pool_lower(sub_off, sub_len);
            if (n_first[n] != 0) {
                emit("(");
                int a = n_first[n];
                int first = 1;
                while (a != 0) {
                    if (!first) emit(", ");
                    first = 0;
                    emit_expression_ast(a);
                    a = n_next[a];
                }
                emit(")");
            }
        }
    }
}

/* Public expression-parse wrapper: build AST, emit, discard the nodes.
   All external callers in parse_statement / parse_declarations still
   use this entry point — only the internal recursive structure has
   changed. */
static void parse_expression(void) {
    int n = parse_expression_ast();
    emit_expression_ast(n);
    reset_ast();
}

/* ---- Statement parser ---- */

/* Helper to compare a saved name case-insensitively */
static int name_eq_ci(const char *name, int nlen, const char *s) {
    int slen = strlen(s);
    if (nlen != slen) return 0;
    for (int i = 0; i < nlen; i++) {
        if (tolower((unsigned char)name[i]) != tolower((unsigned char)s[i])) return 0;
    }
    return 1;
}

/* ---- Statement AST walker (leaf statements only) ----
   Compound statements (IF/WHILE/LOOP/FOR/DECLARE/BEGIN) and dotted
   package calls direct-emit during parse and return a 0 node; the
   wrapper just skips emit for those. */
static void emit_statement_ast(int n) {
    if (n == 0) return;
    int kind = n_kind[n];
    if (kind == S_NULL) {
        emit_indent(); emit_line("/* null */;");
    } else if (kind == S_RETURN) {
        emit_indent(); emit("return");
        if (n_left[n] != 0) {
            emit(" ");
            emit_expression_ast(n_left[n]);
        } else if (n_op[n] == 1) {
            emit(" 0");
        }
        emit_line(";");
    } else if (kind == S_RAISE) {
        emit_indent();
        emit("{ fprintf(stderr, \"Exception raised at line %d\\n\", ");
        emit_int(n_int[n]);
        emit_line("); exit(1); }");
    } else if (kind == S_EXIT) {
        if (n_left[n] != 0) {
            emit_indent(); emit("if (");
            emit_expression_ast(n_left[n]);
            emit_line(") break;");
        } else {
            emit_indent(); emit_line("break;");
        }
    } else if (kind == S_ASSIGN) {
        emit_indent();
        emit_pool_lower(n_str_off[n], n_str_len[n]);
        emit(" = ");
        emit_expression_ast(n_right[n]);
        emit_line(";");
    } else if (kind == S_CALL) {
        emit_indent();
        emit_pool_lower(n_str_off[n], n_str_len[n]);
        emit("(");
        int a = n_first[n];
        int first = 1;
        while (a != 0) {
            if (!first) emit(", ");
            first = 0;
            emit_expression_ast(a);
            a = n_next[a];
        }
        emit_line(");");
    } else if (kind == S_PARAMLESS) {
        emit_indent();
        emit_pool_lower(n_str_off[n], n_str_len[n]);
        emit_line("();");
    } else if (kind == S_ARRAY_ASSIGN) {
        emit_indent();
        emit_pool_lower(n_str_off[n], n_str_len[n]);
        emit("[");
        emit_expression_ast(n_right[n]);
        emit(" - "); emit_int(n_op[n]);    /* resolved outer subtrahend */
        emit("]");
        if (n_arg2[n] != 0) {
            emit("[");
            emit_expression_ast(n_arg2[n]);
            emit(" - "); emit_int(n_aux1[n]);  /* resolved inner subtrahend */
            emit("]");
        }
        emit(" = ");
        emit_expression_ast(n_first[n]);
        emit_line(";");
    } else if (kind == S_FIELD_ASSIGN) {
        /* record field assignment: base.field = rhs; */
        emit_indent();
        emit_pool_lower(n_str_off[n], n_str_len[n]);
        emit(".");
        emit_pool_lower(n_arg2[n], n_int[n]);
        emit(" = ");
        emit_expression_ast(n_right[n]);
        emit_line(";");
    } else if (kind == S_IF) {
        emit_indent(); emit("if (");
        emit_expression_ast(n_left[n]);
        emit_line(") {");
        indent_level++; emit_statement_chain(n_first[n]); indent_level--;
        for (int e = n_right[n]; e != 0; e = n_next[e]) {
            emit_indent(); emit("} else if (");
            emit_expression_ast(n_left[e]);
            emit_line(") {");
            indent_level++; emit_statement_chain(n_first[e]); indent_level--;
        }
        if (n_arg2[n] != 0) {
            emit_indent(); emit_line("} else {");
            indent_level++; emit_statement_chain(n_arg2[n]); indent_level--;
        }
        emit_indent(); emit_line("}");
    } else if (kind == S_CASE) {
        emit_indent(); emit("switch (");
        emit_expression_ast(n_left[n]);
        emit_line(") {");
        indent_level++;
        for (int arm = n_first[n]; arm != 0; arm = n_next[arm]) {
            if (n_op[arm]) {
                emit_indent(); emit_line("default: {");
            } else {
                for (int c = n_first[arm]; c != 0; c = n_next[c]) {
                    emit_indent(); emit("case ");
                    emit_expression_ast(c);
                    if (n_next[c] == 0) emit_line(": {");
                    else emit_line(":");
                }
            }
            indent_level++;
            emit_statement_chain(n_arg2[arm]);
            emit_indent(); emit_line("break;");
            indent_level--;
            emit_indent(); emit_line("}");
        }
        indent_level--;
        emit_indent(); emit_line("}");
    } else if (kind == S_WHILE) {
        emit_indent(); emit("while (");
        emit_expression_ast(n_left[n]);
        emit_line(") {");
        indent_level++; emit_statement_chain(n_first[n]); indent_level--;
        emit_indent(); emit_line("}");
    } else if (kind == S_LOOP) {
        emit_indent(); emit_line("while (1) {");
        indent_level++; emit_statement_chain(n_first[n]); indent_level--;
        emit_indent(); emit_line("}");
    } else if (kind == S_FOR) {
        emit_indent();
        if (n_op[n]) {
            /* reverse: wrap in a block so __lo/__hi can scope-shadow */
            emit("{ int __lo = ");
            emit_expression_ast(n_left[n]);
            emit("; int __hi = ");
            emit_expression_ast(n_right[n]);
            emit("; for (int ");
            emit_pool_lower(n_str_off[n], n_str_len[n]);
            emit(" = __hi; ");
            emit_pool_lower(n_str_off[n], n_str_len[n]);
            emit(" >= __lo; ");
            emit_pool_lower(n_str_off[n], n_str_len[n]);
            emit_line("--) {");
        } else {
            emit("for (int ");
            emit_pool_lower(n_str_off[n], n_str_len[n]);
            emit(" = ");
            emit_expression_ast(n_left[n]);
            emit("; ");
            emit_pool_lower(n_str_off[n], n_str_len[n]);
            emit(" <= ");
            emit_expression_ast(n_right[n]);
            emit("; ");
            emit_pool_lower(n_str_off[n], n_str_len[n]);
            emit_line("++) {");
        }
        indent_level++; emit_statement_chain(n_first[n]); indent_level--;
        emit_indent();
        if (n_op[n]) emit_line("} }");
        else emit_line("}");
    } else if (kind == S_DECLARE) {
        emit_indent(); emit_line("{");
        indent_level++;
        emit_declaration_chain(n_first[n]);
        emit_statement_chain(n_arg2[n]);
        indent_level--;
        emit_indent(); emit_line("}");
    } else if (kind == S_BLOCK) {
        emit_indent(); emit_line("{");
        indent_level++;
        emit_statement_chain(n_first[n]);
        indent_level--;
        emit_indent(); emit_line("}");
    } else if (kind == S_PKG) {
        int sub = n_op[n];
        emit_indent();
        if (sub == PKG_PUT_LINE) {
            if (n_right[n] != 0) {
                emit("ada_fput_line(");
                emit_expression_ast(n_left[n]);
                emit(", ");
                emit_expression_ast(n_right[n]);
            } else {
                emit("ada_put_line(");
                emit_expression_ast(n_left[n]);
            }
            emit_line(");");
        } else if (sub == PKG_PUT) {
            if (n_right[n] != 0) {
                emit(n_aux1[n] ? "ada_fput_char(" : "ada_fput_str(");
                emit_expression_ast(n_left[n]);
                emit(", ");
                emit_expression_ast(n_right[n]);
            } else {
                emit(n_aux1[n] ? "ada_put_char(" : "ada_put_str(");
                emit_expression_ast(n_left[n]);
            }
            emit_line(");");
        } else if (sub == PKG_NEW_LINE) {
            if (n_left[n] != 0) {
                emit("ada_fput_newline(");
                emit_expression_ast(n_left[n]);
                emit_line(");");
            } else {
                emit_line("ada_new_line();");
            }
        } else if (sub == PKG_OPEN) {
            emit_expression_ast(n_left[n]);
            emit(" = fopen(");
            emit_expression_ast(n_right[n]);
            emit(n_int[n] ? ", \"w\"" : ", \"r\"");
            emit_line(");");
        } else if (sub == PKG_CREATE) {
            emit_expression_ast(n_left[n]);
            emit(" = fopen(");
            emit_expression_ast(n_right[n]);
            emit(", \"w\"");
            emit_line(");");
        } else if (sub == PKG_CLOSE) {
            emit("fclose(");
            emit_expression_ast(n_left[n]);
            emit_line(");");
        } else if (sub == PKG_GET_LINE) {
            emit("ada_get_line(");
            emit_expression_ast(n_left[n]);
            emit_line(");");
        } else if (sub == PKG_GET) {
            emit("{int __gc = fgetc(");
            emit_expression_ast(n_left[n]);
            emit("); if (__gc != EOF) ");
            emit_expression_ast(n_right[n]);
            emit_line(" = (char)__gc;}");
        } else if (sub == PKG_GENERIC) {
            emit_pool_lower(n_str_off[n], n_str_len[n]);
            emit("_");
            emit_pool_lower(n_arg2[n], n_int[n]);
            if (n_aux1[n]) {
                emit("(");
                int a = n_first[n];
                int first = 1;
                while (a != 0) {
                    if (!first) emit(", ");
                    first = 0;
                    emit_expression_ast(a);
                    a = n_next[a];
                }
                emit_line(");");
            } else {
                emit_line("();");
            }
        }
    }
}

/* Build one statement node (leaf or compound). */
static int parse_statement_ast(void) {
    int n;
    if (tok == TK_NULL) {
        n = new_node(S_NULL);
        next_token(); expect(TK_SEMI);
        return n;
    }
    if (tok == TK_RETURN) {
        n = new_node(S_RETURN);
        next_token();
        if (tok != TK_SEMI) {
            n_left[n] = parse_expression_ast();
        } else if (in_main_proc) {
            n_op[n] = 1;  /* signal "return 0" to the walker */
        }
        expect(TK_SEMI);
        return n;
    }
    if (tok == TK_RAISE) {
        n = new_node(S_RAISE);
        n_int[n] = line_num;
        next_token();
        while (tok != TK_SEMI && tok != TK_EOF) next_token();
        expect(TK_SEMI);
        return n;
    }
    if (tok == TK_EXIT) {
        n = new_node(S_EXIT);
        next_token();
        if (tok == TK_WHEN) {
            next_token();
            n_left[n] = parse_expression_ast();
        }
        expect(TK_SEMI);
        return n;
    }

    /* Compound statements: build a subtree; children are sub-chains. */
    if (tok == TK_IF) {
        n = new_node(S_IF);
        next_token();
        n_left[n] = parse_expression_ast();
        expect(TK_THEN);
        n_first[n] = parse_statement_chain();
        int prev_elsif = 0;
        while (tok == TK_ELSIF) {
            next_token();
            int e = new_node(S_ELSIF);
            n_left[e] = parse_expression_ast();
            expect(TK_THEN);
            n_first[e] = parse_statement_chain();
            if (prev_elsif == 0) n_right[n] = e;
            else n_next[prev_elsif] = e;
            prev_elsif = e;
        }
        if (tok == TK_ELSE) {
            next_token();
            n_arg2[n] = parse_statement_chain();
        }
        expect(TK_END); expect(TK_IF); expect(TK_SEMI);
        return n;
    }
    if (tok == TK_CASE) {
        /* case Sel is when C|C => stmts ... when others => stmts end case; */
        n = new_node(S_CASE);
        next_token();
        n_left[n] = parse_expression_ast();   /* selector */
        expect(TK_IS);
        int prev_arm = 0;
        while (tok == TK_WHEN) {
            next_token();
            int arm = new_node(S_WHEN);
            if (tok == TK_IDENT && tok_eq_ci("others")) {
                n_op[arm] = 1;                 /* default: */
                next_token();
            } else {
                int first_c = parse_expression_ast();
                n_first[arm] = first_c;
                int prev_c = first_c;
                while (tok == TK_BAR) {
                    next_token();
                    int c = parse_expression_ast();
                    n_next[prev_c] = c;
                    prev_c = c;
                }
            }
            expect(TK_ARROW);
            n_arg2[arm] = parse_statement_chain();   /* stops at when/end */
            if (prev_arm == 0) n_first[n] = arm;
            else n_next[prev_arm] = arm;
            prev_arm = arm;
        }
        expect(TK_END); expect(TK_CASE); expect(TK_SEMI);
        return n;
    }
    if (tok == TK_WHILE) {
        n = new_node(S_WHILE);
        next_token();
        n_left[n] = parse_expression_ast();
        expect(TK_LOOP);
        n_first[n] = parse_statement_chain();
        expect(TK_END); expect(TK_LOOP); expect(TK_SEMI);
        return n;
    }
    if (tok == TK_LOOP) {
        n = new_node(S_LOOP);
        next_token();
        n_first[n] = parse_statement_chain();
        expect(TK_END); expect(TK_LOOP); expect(TK_SEMI);
        return n;
    }
    if (tok == TK_FOR) {
        n = new_node(S_FOR);
        next_token();
        n_str_off[n] = pool_str(tok_val, tok_len);
        n_str_len[n] = tok_len;
        next_token();
        expect(TK_IN);
        if (tok == TK_REVERSE) { n_op[n] = 1; next_token(); }
        n_left[n] = parse_expression_ast();
        expect(TK_DOTDOT);
        n_right[n] = parse_expression_ast();
        expect(TK_LOOP);
        n_first[n] = parse_statement_chain();
        expect(TK_END); expect(TK_LOOP); expect(TK_SEMI);
        return n;
    }
    if (tok == TK_DECLARE) {
        n = new_node(S_DECLARE);
        next_token();
        n_first[n] = parse_var_decl_chain();
        expect(TK_BEGIN);
        n_arg2[n] = parse_statement_chain();
        expect(TK_END); expect(TK_SEMI);
        return n;
    }
    if (tok == TK_BEGIN) {
        n = new_node(S_BLOCK);
        next_token();
        n_first[n] = parse_statement_chain();
        expect(TK_END); expect(TK_SEMI);
        return n;
    }

    /* Identifier-prefixed statement: assignment, call, array assign,
       parameterless call, or dotted package call. The first four become
       AST nodes; dotted still emits directly. */
    if (tok == TK_IDENT) {
        char saved[MAX_TOK];
        int saved_len = tok_len;
        memcpy(saved, tok_val, tok_len);
        int sidx = find_sym(tok_val, tok_len);
        next_token();

        if (tok == TK_ASSIGN) {
            n = new_node(S_ASSIGN);
            n_str_off[n] = pool_str(saved, saved_len);
            n_str_len[n] = saved_len;
            next_token();
            n_right[n] = parse_expression_ast();
            expect(TK_SEMI);
            return n;
        }

        if (tok == TK_LPAREN) {
            next_token();
            if (sidx >= 0 && (sym_kind[sidx]==SK_PROC || sym_kind[sidx]==SK_FUNC)) {
                n = new_node(S_CALL);
                set_call_name(n, saved, saved_len, sidx);
                n_int[n] = sidx;
                if (tok != TK_RPAREN) {
                    int first = parse_expression_ast();
                    n_first[n] = first;
                    int prev = first;
                    while (tok == TK_COMMA) {
                        next_token();
                        int arg = parse_expression_ast();
                        n_next[prev] = arg;
                        prev = arg;
                    }
                }
                expect(TK_RPAREN); expect(TK_SEMI);
                return n;
            }
            if (sidx >= 0 && (sym_kind[sidx]==SK_VAR || sym_kind[sidx]==SK_PARAM)
                && sym_type[sidx]==TY_ARRAY) {
                n = new_node(S_ARRAY_ASSIGN);
                n_str_off[n] = pool_str(saved, saved_len);
                n_str_len[n] = saved_len;
                n_op[n] = sym_arr_lo[sidx];          /* resolved outer subtrahend */
                n_aux1[n] = sym_arr_inner_lo[sidx];  /* resolved inner subtrahend */
                n_right[n] = parse_expression_ast();
                expect(TK_RPAREN);
                if (tok == TK_LPAREN && sym_arr_inner_hi[sidx] != 0) {
                    next_token();
                    n_arg2[n] = parse_expression_ast();
                    expect(TK_RPAREN);
                }
                expect(TK_ASSIGN);
                n_first[n] = parse_expression_ast();
                expect(TK_SEMI);
                return n;
            }
            /* Unresolved IDENT(...) — treat as call */
            n = new_node(S_CALL);
            set_call_name(n, saved, saved_len, sidx);
            n_int[n] = sidx;
            if (tok != TK_RPAREN) {
                int first = parse_expression_ast();
                n_first[n] = first;
                int prev = first;
                while (tok == TK_COMMA) {
                    next_token();
                    int arg = parse_expression_ast();
                    n_next[prev] = arg;
                    prev = arg;
                }
            }
            expect(TK_RPAREN); expect(TK_SEMI);
            return n;
        }

        if (tok == TK_SEMI) {
            n = new_node(S_PARAMLESS);
            n_str_off[n] = pool_str(saved, saved_len);
            n_str_len[n] = saved_len;
            next_token();
            return n;
        }

        if (tok == TK_DOT && sidx >= 0
            && (sym_kind[sidx]==SK_VAR || sym_kind[sidx]==SK_PARAM)
            && sym_type[sidx]==TY_RECORD) {
            /* Record field assignment: var.field := expr; */
            next_token();   /* consume '.' */
            n = new_node(S_FIELD_ASSIGN);
            n_str_off[n] = pool_str(saved, saved_len);
            n_str_len[n] = saved_len;
            n_arg2[n] = pool_str(tok_val, tok_len);
            n_int[n] = tok_len;
            next_token();   /* consume field name */
            expect(TK_ASSIGN);
            n_right[n] = parse_expression_ast();
            expect(TK_SEMI);
            return n;
        }

        if (tok == TK_DOT) {
            /* Package-qualified call → S_PKG subtree node. */
            next_token();
            char sub[MAX_TOK];
            int sub_len = tok_len;
            memcpy(sub, tok_val, tok_len);
            next_token();
            while (tok == TK_DOT) {
                next_token();
                sub_len = tok_len;
                memcpy(sub, tok_val, tok_len);
                next_token();
            }

            n = new_node(S_PKG);
            if (name_eq_ci(sub, sub_len, "Put_Line")) {
                n_op[n] = PKG_PUT_LINE;
                expect(TK_LPAREN);
                if (has_arg_separator_ahead()) {
                    n_left[n] = parse_expression_ast();
                    expect(TK_COMMA);
                    n_right[n] = parse_expression_ast();
                } else {
                    n_left[n] = parse_expression_ast();
                }
                expect(TK_RPAREN);
            } else if (name_eq_ci(sub, sub_len, "Put")) {
                n_op[n] = PKG_PUT;
                expect(TK_LPAREN);
                if (has_arg_separator_ahead()) {
                    n_aux1[n] = second_arg_is_char() ? 1 : 0;
                    n_left[n] = parse_expression_ast();
                    expect(TK_COMMA);
                    n_right[n] = parse_expression_ast();
                } else {
                    n_aux1[n] = first_arg_is_char() ? 1 : 0;
                    n_left[n] = parse_expression_ast();
                }
                expect(TK_RPAREN);
            } else if (name_eq_ci(sub, sub_len, "New_Line")) {
                n_op[n] = PKG_NEW_LINE;
                if (tok == TK_LPAREN) {
                    expect(TK_LPAREN);
                    if (tok != TK_RPAREN) n_left[n] = parse_expression_ast();
                    expect(TK_RPAREN);
                }
            } else if (name_eq_ci(sub, sub_len, "Open")) {
                n_op[n] = PKG_OPEN;
                expect(TK_LPAREN);
                n_left[n] = parse_expression_ast();   /* file var */
                expect(TK_COMMA);
                while (tok != TK_COMMA && tok != TK_RPAREN && tok != TK_EOF) {
                    if (tok_eq_ci("Out_File")) n_int[n] = 1;
                    next_token();
                    if (tok == TK_DOT) { next_token(); next_token(); }
                }
                if (tok == TK_COMMA) next_token();
                n_right[n] = parse_expression_ast();   /* name */
                expect(TK_RPAREN);
            } else if (name_eq_ci(sub, sub_len, "Create")) {
                n_op[n] = PKG_CREATE;
                expect(TK_LPAREN);
                n_left[n] = parse_expression_ast();
                expect(TK_COMMA);
                while (tok != TK_COMMA && tok != TK_RPAREN && tok != TK_EOF) {
                    next_token();
                    if (tok == TK_DOT) { next_token(); next_token(); }
                }
                if (tok == TK_COMMA) next_token();
                n_right[n] = parse_expression_ast();
                expect(TK_RPAREN);
            } else if (name_eq_ci(sub, sub_len, "Close")) {
                n_op[n] = PKG_CLOSE;
                expect(TK_LPAREN);
                n_left[n] = parse_expression_ast();
                expect(TK_RPAREN);
            } else if (name_eq_ci(sub, sub_len, "Get_Line")) {
                n_op[n] = PKG_GET_LINE;
                expect(TK_LPAREN);
                n_left[n] = parse_expression_ast();
                expect(TK_RPAREN);
            } else if (name_eq_ci(sub, sub_len, "Get")) {
                n_op[n] = PKG_GET;
                expect(TK_LPAREN);
                n_left[n] = parse_expression_ast();   /* file */
                expect(TK_COMMA);
                n_right[n] = parse_expression_ast();   /* char var */
                expect(TK_RPAREN);
            } else {
                n_op[n] = PKG_GENERIC;
                n_str_off[n] = pool_str(saved, saved_len);
                n_str_len[n] = saved_len;
                n_arg2[n] = pool_str(sub, sub_len);
                n_int[n] = sub_len;
                if (tok == TK_LPAREN) {
                    n_aux1[n] = 1;
                    next_token();
                    if (tok != TK_RPAREN) {
                        int first = parse_expression_ast();
                        n_first[n] = first;
                        int prev = first;
                        while (tok == TK_COMMA) {
                            next_token();
                            int arg = parse_expression_ast();
                            n_next[prev] = arg;
                            prev = arg;
                        }
                    }
                    expect(TK_RPAREN);
                }
            }
            expect(TK_SEMI);
            return n;
        }
        error("expected ':=' or '(' after identifier");
        return 0;
    }
    error("unexpected token in statement");
    return 0;
}

/* Build a chain of statement nodes (linked by n_next) until a list
   terminator. No emission, no reset — the whole chain is walked later. */
static int parse_statement_chain(void) {
    int head = 0, prev = 0;
    while (tok != TK_END && tok != TK_ELSIF && tok != TK_ELSE &&
           tok != TK_EOF && tok != TK_WHEN) {
        /* Skip 'exception' handler blocks: stop the chain at the handler. */
        if (tok == TK_IDENT && tok_eq_ci("exception")) {
            next_token();
            while (tok != TK_END && tok != TK_EOF) next_token();
            break;
        }
        int s = parse_statement_ast();
        if (head == 0) head = s;
        else n_next[prev] = s;
        prev = s;
    }
    return head;
}

/* Walk a statement chain. */
static void emit_statement_chain(int head) {
    for (int n = head; n != 0; n = n_next[n]) emit_statement_ast(n);
}

/* Parse one program-unit body: build its statement tree, walk it, then
   reset the shared node pool. Called for the main body and for proc /
   function bodies (after their local declarations are emitted). */
static void parse_statements(void) {
    int head = parse_statement_chain();
    emit_statement_chain(head);
    reset_ast();
}

/* ---- Declaration parser ---- */

/* ---- Variable-declaration AST walker ----
   Emits the C for one variable-declaration leaf node. Type definitions
   and procedure/function declarations don't go through this walker —
   they direct-emit during parse_declaration_ast and return 0. */
static void emit_declaration_ast(int n) {
    if (n == 0) return;
    int kind = n_kind[n];
    int is_const = n_op[n];

    if (kind == D_VAR_SIMPLE) {
        emit_indent();
        if (is_const) emit("const ");
        emit_c_type(n_int[n]);
        emit(" ");
        emit_pool_lower(n_str_off[n], n_str_len[n]);
        if (n_left[n] != 0) {
            emit(" = ");
            emit_expression_ast(n_left[n]);
        } else if (n_int[n] == TY_STRING) {
            emit(" = \"\"");
        } else {
            emit(" = 0");
        }
        emit_line(";");
    } else if (kind == D_VAR_NAMED_ARRAY) {
        /* el type in n_aux1, element count in n_aux2 (resolved at build). */
        emit_indent();
        emit_c_type(n_aux1[n]);
        emit(" ");
        emit_pool_lower(n_str_off[n], n_str_len[n]);
        emit("[");
        emit_int(n_aux2[n]);
        emit_line("];");
    } else if (kind == D_VAR_ANON_ARRAY) {
        /* el type in n_aux1, outer count in n_aux2, inner count in n_int
           (0 = not nested), all resolved at build. */
        emit_indent();
        if (is_const) emit("const ");
        emit_c_type(n_aux1[n]);
        emit(" ");
        emit_pool_lower(n_str_off[n], n_str_len[n]);
        emit("[");
        emit_int(n_aux2[n]);
        emit("]");
        if (n_int[n] != 0) {
            emit("[");
            emit_int(n_int[n]);
            emit("]");
        }
        emit_line(";");
    } else if (kind == D_VAR_STRING) {
        emit_indent();
        emit("const char *");
        emit_pool_lower(n_str_off[n], n_str_len[n]);
        if (n_left[n] != 0) {
            emit(" = ");
            emit_expression_ast(n_left[n]);
        } else {
            emit(" = \"\"");
        }
        emit_line(";");
    } else if (kind == D_VAR_FILE) {
        emit_indent();
        emit("FILE *");
        emit_pool_lower(n_str_off[n], n_str_len[n]);
        emit_line(" = NULL;");
    } else if (kind == D_VAR_ACCESS) {
        /* Elem *name [= <new ...>]; (default NULL) */
        emit_indent();
        if (is_const) emit("const ");
        emit_c_type(n_aux1[n]);
        emit(" *");
        emit_pool_lower(n_str_off[n], n_str_len[n]);
        if (n_left[n] != 0) {
            emit(" = ");
            emit_expression_ast(n_left[n]);
        } else {
            emit(" = NULL");
        }
        emit_line(";");
    } else if (kind == D_VAR_RECORD) {
        /* struct <typename> name [= <other record>] (default {0}). */
        emit_indent();
        if (is_const) emit("const ");
        emit("struct ");
        emit_pool_lower(n_arg2[n], n_int[n]);   /* record type name */
        emit(" ");
        emit_pool_lower(n_str_off[n], n_str_len[n]);
        if (n_left[n] != 0) {
            emit(" = ");
            emit_expression_ast(n_left[n]);
        } else {
            emit(" = {0}");
        }
        emit_line(";");
    } else if (kind == D_VAR_DOTTED) {
        emit_indent();
        if (is_const) emit("const ");
        emit("int ");
        emit_pool_lower(n_str_off[n], n_str_len[n]);
        if (n_left[n] != 0) {
            emit(" = ");
            emit_expression_ast(n_left[n]);
        } else {
            emit(" = 0");
        }
        emit_line(";");
    }
}

/* Parse one declaration. Variable declarations become AST nodes; type
   definitions and procedure / function declarations direct-emit and
   return 0. The signal value 0 also indicates "no more declarations
   here" (the loop in parse_declarations stops when it sees something
   that isn't a declaration). */
static int parse_declaration_ast(void) {
    if (tok == TK_TYPE) {
        /* Type definition (no C emission; just populates the symbol table). */
        next_token();
        add_sym(SK_TYPE, TY_ARRAY);
        next_token();
        expect(TK_IS);
        if (tok == TK_ARRAY) {
            next_token();
            expect(TK_LPAREN);
            if (tok == TK_INTEGER || tok == TK_CHARACTER || tok == TK_BOOLEAN) {
                /* Unconstrained: `array (Index range <>) of Elem`. The
                   hi=0 marker says "no fixed size"; such a type is only
                   used as the target of an access type. */
                next_token();
                expect(TK_RANGE);
                expect(TK_BOX);
                expect(TK_RPAREN);
                expect(TK_OF);
                int el = parse_type_ref();
                sym_arr_lo[sym_count-1] = 1;
                sym_arr_hi[sym_count-1] = 0;
                sym_arr_el[sym_count-1] = el;
            } else {
                int lo = tok_int; next_token();
                expect(TK_DOTDOT);
                int hi = tok_int; next_token();
                if (tok == TK_COMMA) {
                    /* 2D form (1..N, 1..M) — second dim parsed but not
                       tracked separately. */
                    next_token();
                    next_token();
                    expect(TK_DOTDOT);
                    next_token();
                    expect(TK_RPAREN);
                    expect(TK_OF);
                    int el = parse_type_ref();
                    sym_arr_lo[sym_count-1] = lo;
                    sym_arr_hi[sym_count-1] = hi;
                    sym_arr_el[sym_count-1] = el;
                } else {
                    expect(TK_RPAREN);
                    expect(TK_OF);
                    int el = parse_type_ref();
                    sym_arr_lo[sym_count-1] = lo;
                    sym_arr_hi[sym_count-1] = hi;
                    sym_arr_el[sym_count-1] = el;
                }
            }
        } else if (tok == TK_ACCESS) {
            /* `access <ArrayTypeName>` or `access <ScalarType>`. Modelled
               as a pointer to its element type. */
            next_token();
            int el = TY_INTEGER;
            if (tok == TK_IDENT) {
                int ti = find_sym(tok_val, tok_len);
                if (ti >= 0 && sym_kind[ti] == SK_TYPE) el = sym_arr_el[ti];
                next_token();
            } else {
                el = parse_type_ref();
            }
            sym_type[sym_count-1] = TY_ACCESS;
            sym_arr_lo[sym_count-1] = 1;
            sym_arr_hi[sym_count-1] = 0;
            sym_arr_el[sym_count-1] = el;
        } else if (tok == TK_RECORD) {
            /* `record F1 : T1; ... end record;` -> a C struct, emitted
               here (records, unlike array/access types, produce C). */
            sym_type[sym_count-1] = TY_RECORD;
            emit("struct ");
            emit_str_lower(sym_name[sym_count-1], sym_nlen[sym_count-1]);
            emit(" {");
            next_token();   /* consume 'record' */
            while (tok != TK_END && tok != TK_EOF) {
                char fname[MAX_NAME];
                int fnl = tok_len;
                memcpy(fname, tok_val, tok_len);
                next_token();
                expect(TK_COLON);
                int fty = parse_type_ref();
                emit(" ");
                emit_c_type(fty);
                emit(" ");
                emit_str_lower(fname, fnl);
                emit(";");
                expect(TK_SEMI);
            }
            emit_line(" };");
            expect(TK_END);
            expect(TK_RECORD);
        } else if (tok == TK_LPAREN) {
            /* enumeration: `type T is (A, B, C);` -> a C enum whose
               constants are the lowercased literals (a=0, b=1, ...).
               Each literal is registered as a constant so its use emits
               the matching C name; the type itself is an int. */
            sym_type[sym_count-1] = TY_ENUM;
            emit("enum { ");
            next_token();   /* consume '(' */
            int first = 1;
            while (tok != TK_RPAREN && tok != TK_EOF) {
                if (!first) emit(", ");
                first = 0;
                emit_str_lower(tok_val, tok_len);   /* literal -> C constant */
                add_sym(SK_CONST, TY_ENUM);          /* register the literal */
                next_token();
                if (tok == TK_COMMA) next_token();
            }
            emit_line(" };");
            expect(TK_RPAREN);
        } else {
            while (tok != TK_SEMI && tok != TK_EOF) next_token();
        }
        expect(TK_SEMI);
        return 0;
    }

    if (tok == TK_PACKAGE) {
        /* package [body] P is <decls> end [P]; — a namespace whose
           subprograms become <pkg>_<op> C functions. */
        next_token();
        if (tok == TK_IDENT && tok_eq_ci("body")) next_token();
        add_sym(SK_PACKAGE, 0);          /* name = the package name token */
        int psym = sym_count - 1;
        next_token();
        expect(TK_IS);
        int saved_pkg = cur_pkg;
        cur_pkg = psym + 1;              /* +1 so index 0 isn't the "none" sentinel */
        parse_declarations();            /* subprograms tagged + mangled */
        cur_pkg = saved_pkg;
        if (tok == TK_BEGIN) error("package initialization (begin) not supported");
        expect(TK_END);
        if (tok == TK_IDENT) next_token();   /* optional repeated package name */
        expect(TK_SEMI);
        return 0;
    }

    if (tok == TK_PROCEDURE) {
            next_token();
            char pname[MAX_NAME];
            int plen = tok_len;
            memcpy(pname, tok_val, tok_len);
            add_sym(SK_PROC, 0);
            if (cur_pkg) sym_arr_lo[sym_count-1] = cur_pkg;
            next_token();

            emit("void ");
            emit_sub_name(pname, plen);
            emit("(");

            push_scope();

            if (tok == TK_LPAREN) {
                next_token();
                int first = 1;
                while (tok != TK_RPAREN && tok != TK_EOF) {
                    if (!first) emit(", ");
                    first = 0;
                    char pn[MAX_NAME];
                    int pnl = tok_len;
                    memcpy(pn, tok_val, tok_len);
                    add_sym(SK_PARAM, TY_INTEGER);
                    next_token();
                    expect(TK_COLON);
                    /* Named array type as parameter decays to a pointer; a
                       record type passes by value as `struct <name>`. */
                    int arr_idx = -1;
                    int rec_idx = -1;
                    if (tok == TK_IDENT) {
                        int ti = find_sym(tok_val, tok_len);
                        if (ti >= 0 && sym_kind[ti] == SK_TYPE && sym_type[ti] == TY_ARRAY) {
                            arr_idx = ti;
                        } else if (ti >= 0 && sym_kind[ti] == SK_TYPE && sym_type[ti] == TY_RECORD) {
                            rec_idx = ti;
                        }
                    }
                    if (arr_idx >= 0) {
                        sym_type[sym_count-1] = TY_ARRAY;
                        sym_arr_lo[sym_count-1] = sym_arr_lo[arr_idx];
                        sym_arr_hi[sym_count-1] = sym_arr_hi[arr_idx];
                        sym_arr_el[sym_count-1] = sym_arr_el[arr_idx];
                        emit_c_type(sym_arr_el[arr_idx]);
                        emit(" *");
                        emit_str_lower(pn, pnl);
                        next_token();
                    } else if (rec_idx >= 0) {
                        sym_type[sym_count-1] = TY_RECORD;
                        emit("struct ");
                        emit_str_lower(sym_name[rec_idx], sym_nlen[rec_idx]);
                        emit(" ");
                        emit_str_lower(pn, pnl);
                        next_token();
                    } else {
                        int typ = parse_type_ref();
                        sym_type[sym_count-1] = typ;
                        if (typ == TY_STRING) sym_arr_lo[sym_count-1] = 1;
                        emit_c_type(typ);
                        emit(" ");
                        emit_str_lower(pn, pnl);
                    }
                    if (tok == TK_SEMI) next_token();
                }
                expect(TK_RPAREN);
            }

            /* Forward declaration: `procedure Name (...);` with no body */
            if (tok == TK_SEMI) {
                emit_line(");");
                next_token();
                pop_scope();
                return 0;
            }

            emit_line(") {");
            expect(TK_IS);
            indent_level++;
            parse_declarations();
            expect(TK_BEGIN);
            parse_statements();
            indent_level--;
            emit_line("}");
            emit_line("");
            expect(TK_END);
            if (tok == TK_IDENT) next_token();
            expect(TK_SEMI);
            pop_scope();
            return 0;
        }

        if (tok == TK_FUNCTION) {
            next_token();
            char fname[MAX_NAME];
            int flen = tok_len;
            memcpy(fname, tok_val, tok_len);
            add_sym(SK_FUNC, TY_INTEGER);
            if (cur_pkg) sym_arr_lo[sym_count-1] = cur_pkg;
            next_token();

            push_scope();

            /* Collect params */
            char pnames[20][MAX_NAME];
            int plens[20];
            int ptypes[20];
            int pel_type[20];   /* element type when ptypes[i]==TY_ARRAY, else 0 */
            int prec_idx[20];   /* record type symbol index when TY_RECORD, else -1 */
            int pcount = 0;

            if (tok == TK_LPAREN) {
                next_token();
                while (tok != TK_RPAREN && tok != TK_EOF) {
                    plens[pcount] = tok_len;
                    memcpy(pnames[pcount], tok_val, tok_len);
                    add_sym(SK_PARAM, TY_INTEGER);
                    next_token();
                    expect(TK_COLON);
                    /* Named array type: pointer-decay parameter */
                    int arr_idx = -1;
                    int rec_idx = -1;
                    if (tok == TK_IDENT) {
                        int ti = find_sym(tok_val, tok_len);
                        if (ti >= 0 && sym_kind[ti] == SK_TYPE && sym_type[ti] == TY_ARRAY) {
                            arr_idx = ti;
                        } else if (ti >= 0 && sym_kind[ti] == SK_TYPE && sym_type[ti] == TY_RECORD) {
                            rec_idx = ti;
                        }
                    }
                    prec_idx[pcount] = -1;
                    if (arr_idx >= 0) {
                        ptypes[pcount] = TY_ARRAY;
                        pel_type[pcount] = sym_arr_el[arr_idx];
                        sym_type[sym_count-1] = TY_ARRAY;
                        sym_arr_lo[sym_count-1] = sym_arr_lo[arr_idx];
                        sym_arr_hi[sym_count-1] = sym_arr_hi[arr_idx];
                        sym_arr_el[sym_count-1] = sym_arr_el[arr_idx];
                        next_token();
                    } else if (rec_idx >= 0) {
                        ptypes[pcount] = TY_RECORD;
                        pel_type[pcount] = 0;
                        prec_idx[pcount] = rec_idx;
                        sym_type[sym_count-1] = TY_RECORD;
                        next_token();
                    } else {
                        ptypes[pcount] = parse_type_ref();
                        pel_type[pcount] = 0;
                        sym_type[sym_count-1] = ptypes[pcount];
                        if (ptypes[pcount] == TY_STRING) sym_arr_lo[sym_count-1] = 1;
                    }
                    pcount++;
                    if (tok == TK_SEMI) next_token();
                }
                expect(TK_RPAREN);
            }

            expect(TK_RETURN);
            int ret_type = parse_type_ref();

            emit_c_type(ret_type);
            emit(" ");
            emit_sub_name(fname, flen);
            emit("(");
            for (int i = 0; i < pcount; i++) {
                if (i > 0) emit(", ");
                if (ptypes[i] == TY_ARRAY) {
                    emit_c_type(pel_type[i]);
                    emit(" *");
                } else if (ptypes[i] == TY_RECORD) {
                    emit("struct ");
                    emit_str_lower(sym_name[prec_idx[i]], sym_nlen[prec_idx[i]]);
                    emit(" ");
                } else {
                    emit_c_type(ptypes[i]);
                    emit(" ");
                }
                emit_str_lower(pnames[i], plens[i]);
            }
            if (pcount == 0) emit("void");

            /* Forward declaration: `function F (...) return T;` with no body */
            if (tok == TK_SEMI) {
                emit_line(");");
                next_token();
                pop_scope();
                return 0;
            }

            emit_line(") {");

            expect(TK_IS);
            indent_level++;
            parse_declarations();
            expect(TK_BEGIN);
            parse_statements();
            indent_level--;
            emit_line("}");
            emit_line("");
            expect(TK_END);
            if (tok == TK_IDENT) next_token();
            expect(TK_SEMI);
            pop_scope();
            return 0;
        }

        if (tok == TK_IDENT) {
            /* Variable declaration */
            char vname[MAX_NAME];
            int vlen = tok_len;
            memcpy(vname, tok_val, tok_len);
            next_token();
            expect(TK_COLON);

            int is_const = 0;
            if (tok == TK_CONSTANT) { is_const = 1; next_token(); }

            int n;

            /* Anonymous inline array: Name : array (lo .. hi) of T; */
            if (tok == TK_ARRAY) {
                next_token();
                expect(TK_LPAREN);
                int lo = tok_int; next_token();
                expect(TK_DOTDOT);
                int hi = tok_int; next_token();
                expect(TK_RPAREN);
                expect(TK_OF);
                int el_type = TY_INTEGER;
                int inner_lo = 0, inner_hi = 0, is_nested = 0;
                if (tok == TK_IDENT) {
                    int tidx = find_sym(tok_val, tok_len);
                    if (tidx >= 0 && sym_kind[tidx] == SK_TYPE && sym_type[tidx] == TY_ARRAY) {
                        is_nested = 1;
                        inner_lo = sym_arr_lo[tidx];
                        inner_hi = sym_arr_hi[tidx];
                        el_type = sym_arr_el[tidx];
                        next_token();
                    } else {
                        el_type = parse_type_ref();
                    }
                } else {
                    el_type = parse_type_ref();
                }
                if (is_const) add_sym(SK_CONST, TY_ARRAY);
                else add_sym(SK_VAR, TY_ARRAY);
                sym_arr_lo[sym_count-1] = lo;
                sym_arr_hi[sym_count-1] = hi;
                sym_arr_el[sym_count-1] = el_type;
                if (is_nested) {
                    sym_arr_inner_lo[sym_count-1] = inner_lo;
                    sym_arr_inner_hi[sym_count-1] = inner_hi;
                }
                memcpy(sym_name[sym_count-1], vname, vlen);
                sym_nlen[sym_count-1] = vlen;

                n = new_node(D_VAR_ANON_ARRAY);
                n_str_off[n] = pool_str(vname, vlen);
                n_str_len[n] = vlen;
                n_op[n] = is_const;
                n_aux1[n] = el_type;                          /* resolved element type */
                n_aux2[n] = hi - lo + 1;                      /* resolved outer count */
                n_int[n] = is_nested ? (inner_hi - inner_lo + 1) : 0;  /* inner count, 0 if flat */
                if (tok == TK_ASSIGN) {
                    next_token();
                    /* skip the initializer expression — we always emit {0} */
                    while (tok != TK_SEMI && tok != TK_EOF) next_token();
                }
                expect(TK_SEMI);
                return n;
            }

            /* Named array type reference: Name : Some_Array_Type; */
            if (tok == TK_IDENT) {
                int tidx = find_sym(tok_val, tok_len);
                if (tidx >= 0 && sym_kind[tidx] == SK_TYPE && sym_type[tidx] == TY_ARRAY) {
                    if (is_const) add_sym(SK_CONST, TY_ARRAY);
                    else add_sym(SK_VAR, TY_ARRAY);
                    sym_arr_lo[sym_count-1] = sym_arr_lo[tidx];
                    sym_arr_hi[sym_count-1] = sym_arr_hi[tidx];
                    sym_arr_el[sym_count-1] = sym_arr_el[tidx];
                    memcpy(sym_name[sym_count-1], vname, vlen);
                    sym_nlen[sym_count-1] = vlen;

                    n = new_node(D_VAR_NAMED_ARRAY);
                    n_str_off[n] = pool_str(vname, vlen);
                    n_str_len[n] = vlen;
                    n_op[n] = is_const;
                    n_aux1[n] = sym_arr_el[tidx];                       /* resolved element type */
                    n_aux2[n] = sym_arr_hi[tidx] - sym_arr_lo[tidx] + 1; /* resolved element count */
                    next_token();
                    if (tok == TK_ASSIGN) {
                        next_token();
                        while (tok != TK_SEMI && tok != TK_EOF) next_token();
                    }
                    expect(TK_SEMI);
                    return n;
                }
            }

            /* Access-typed variable: Name : Some_Access_Type [:= expr];
               Registered as an indexable pointer (TY_ARRAY, lo=1, no fixed
               size) so the existing array index / assign machinery applies;
               only the declaration differs (`Elem *name = NULL;`). */
            if (tok == TK_IDENT) {
                int tidx = find_sym(tok_val, tok_len);
                if (tidx >= 0 && sym_kind[tidx] == SK_TYPE && sym_type[tidx] == TY_ACCESS) {
                    int el = sym_arr_el[tidx];
                    if (is_const) add_sym(SK_CONST, TY_ARRAY);
                    else add_sym(SK_VAR, TY_ARRAY);
                    sym_arr_lo[sym_count-1] = 1;
                    sym_arr_hi[sym_count-1] = 0;
                    sym_arr_el[sym_count-1] = el;
                    memcpy(sym_name[sym_count-1], vname, vlen);
                    sym_nlen[sym_count-1] = vlen;

                    n = new_node(D_VAR_ACCESS);
                    n_str_off[n] = pool_str(vname, vlen);
                    n_str_len[n] = vlen;
                    n_op[n] = is_const;
                    n_aux1[n] = el;                /* element type for `Elem *` */
                    next_token();
                    if (tok == TK_ASSIGN) {
                        next_token();
                        n_left[n] = parse_expression_ast();   /* e.g. new ... */
                    }
                    expect(TK_SEMI);
                    return n;
                }
            }

            /* Record-typed variable: Name : Some_Record_Type;
               -> struct <typename> name = {0};  (registered TY_RECORD so
               field access / whole-record copy resolve correctly). */
            if (tok == TK_IDENT) {
                int tidx = find_sym(tok_val, tok_len);
                if (tidx >= 0 && sym_kind[tidx] == SK_TYPE && sym_type[tidx] == TY_RECORD) {
                    if (is_const) add_sym(SK_CONST, TY_RECORD);
                    else add_sym(SK_VAR, TY_RECORD);
                    /* type name (for `struct <name>`) before we overwrite
                       the symbol's name with the variable's. */
                    n = new_node(D_VAR_RECORD);
                    n_arg2[n] = pool_str(sym_name[tidx], sym_nlen[tidx]);
                    n_int[n] = sym_nlen[tidx];
                    memcpy(sym_name[sym_count-1], vname, vlen);
                    sym_nlen[sym_count-1] = vlen;
                    n_str_off[n] = pool_str(vname, vlen);
                    n_str_len[n] = vlen;
                    n_op[n] = is_const;
                    next_token();
                    if (tok == TK_ASSIGN) {     /* init from another record */
                        next_token();
                        n_left[n] = parse_expression_ast();
                    }
                    expect(TK_SEMI);
                    return n;
                }
            }

            /* String-typed variable: Name : String [:= expr]; */
            if (tok == TK_STRING) {
                next_token();
                if (is_const) add_sym(SK_CONST, TY_STRING);
                else add_sym(SK_VAR, TY_STRING);
                memcpy(sym_name[sym_count-1], vname, vlen);
                sym_nlen[sym_count-1] = vlen;

                n = new_node(D_VAR_STRING);
                n_str_off[n] = pool_str(vname, vlen);
                n_str_len[n] = vlen;
                n_int[n] = sym_count - 1;
                n_op[n] = is_const;
                if (tok == TK_ASSIGN) {
                    next_token();
                    n_left[n] = parse_expression_ast();
                }
                expect(TK_SEMI);
                return n;
            }

            /* Dotted-type variable: File_Type, or another dotted name. */
            if (tok == TK_IDENT) {
                char first_ident[MAX_NAME];
                int first_len = tok_len;
                memcpy(first_ident, tok_val, tok_len);
                next_token();
                if (tok == TK_DOT) {
                    int is_file_type = 0;
                    while (tok == TK_DOT) {
                        next_token();
                        if (tok == TK_IDENT || tok == TK_INTEGER || tok == TK_CHARACTER) {
                            if (tok_eq_ci("File_Type")) is_file_type = 1;
                            next_token();
                        }
                    }
                    if (is_file_type) {
                        if (is_const) add_sym(SK_CONST, TY_INTEGER);
                        else add_sym(SK_VAR, TY_INTEGER);
                        memcpy(sym_name[sym_count-1], vname, vlen);
                        sym_nlen[sym_count-1] = vlen;
                        n = new_node(D_VAR_FILE);
                        n_str_off[n] = pool_str(vname, vlen);
                        n_str_len[n] = vlen;
                        if (tok == TK_ASSIGN) {
                            next_token();
                            while (tok != TK_SEMI && tok != TK_EOF) next_token();
                        }
                        expect(TK_SEMI);
                        return n;
                    }
                    /* Non-File_Type dotted name — treat as int. */
                    if (is_const) add_sym(SK_CONST, TY_INTEGER);
                    else add_sym(SK_VAR, TY_INTEGER);
                    memcpy(sym_name[sym_count-1], vname, vlen);
                    sym_nlen[sym_count-1] = vlen;
                    n = new_node(D_VAR_DOTTED);
                    n_str_off[n] = pool_str(vname, vlen);
                    n_str_len[n] = vlen;
                    n_op[n] = is_const;
                    if (tok == TK_ASSIGN) {
                        next_token();
                        n_left[n] = parse_expression_ast();
                    }
                    expect(TK_SEMI);
                    return n;
                }
                /* Not dotted — first_ident was the type name. */
                int tidx2 = find_sym(first_ident, first_len);
                int typ2 = TY_INTEGER;
                if (tidx2 >= 0 && sym_kind[tidx2] == SK_TYPE) typ2 = sym_type[tidx2];

                if (is_const) add_sym(SK_CONST, typ2);
                else add_sym(SK_VAR, typ2);
                memcpy(sym_name[sym_count-1], vname, vlen);
                sym_nlen[sym_count-1] = vlen;
                n = new_node(D_VAR_SIMPLE);
                n_str_off[n] = pool_str(vname, vlen);
                n_str_len[n] = vlen;
                n_int[n] = typ2;
                n_op[n] = is_const;
                if (tok == TK_ASSIGN) {
                    next_token();
                    n_left[n] = parse_expression_ast();
                }
                expect(TK_SEMI);
                return n;
            }

            /* Generic typed variable (Integer / Character / Boolean keyword). */
            {
                int typ = parse_type_ref();
                if (is_const) add_sym(SK_CONST, typ);
                else add_sym(SK_VAR, typ);
                memcpy(sym_name[sym_count-1], vname, vlen);
                sym_nlen[sym_count-1] = vlen;
                n = new_node(D_VAR_SIMPLE);
                n_str_off[n] = pool_str(vname, vlen);
                n_str_len[n] = vlen;
                n_int[n] = typ;
                n_op[n] = is_const;
                if (tok == TK_ASSIGN) {
                    next_token();
                    n_left[n] = parse_expression_ast();
                }
                expect(TK_SEMI);
                return n;
            }
        }

        /* Not a declaration we recognise — signal "stop". */
        return 0;
}

/* Public wrapper: loop, building one declaration's AST at a time,
   walking it if it's a leaf-decl node, and resetting the pool. */
static void parse_declarations(void) {
    while (tok == TK_TYPE || tok == TK_PROCEDURE || tok == TK_FUNCTION
           || tok == TK_IDENT || tok == TK_PACKAGE) {
        int n = parse_declaration_ast();
        if (n != 0) emit_declaration_ast(n);
        reset_ast();
    }
}

/* Build a chain of variable-declaration nodes for a `declare` block.
   No reset — the chain is part of the enclosing unit's tree, walked
   later via emit_declaration_chain. Type definitions (which produce no
   node) still register their symbol as a side effect. */
static int parse_var_decl_chain(void) {
    int head = 0, prev = 0;
    while (tok == TK_TYPE || tok == TK_PROCEDURE || tok == TK_FUNCTION
           || tok == TK_IDENT || tok == TK_PACKAGE) {
        int d = parse_declaration_ast();
        if (d != 0) {
            if (head == 0) head = d;
            else n_next[prev] = d;
            prev = d;
        }
    }
    return head;
}

static void emit_declaration_chain(int head) {
    for (int n = head; n != 0; n = n_next[n]) emit_declaration_ast(n);
}

/* ---- Parse context clauses ---- */

static void parse_context(void) {
    while (tok == TK_WITH || tok == TK_USE) {
        int is_with = (tok == TK_WITH);
        next_token();
        if (is_with && tok == TK_IDENT) {
            char nm[MAX_NAME];
            int nl = tok_len;
            memcpy(nm, tok_val, tok_len);
            next_token();
            /* A simple `with Name;` is a user package -> #include "name.h".
               A dotted `with Ada.Text_IO;` is a builtin -> ignored. */
            if (tok != TK_DOT && with_count < MAX_WITHS) {
                memcpy(with_buf[with_count], nm, nl);
                with_nlen[with_count] = nl;
                with_count++;
            }
        }
        while (tok != TK_SEMI && tok != TK_EOF) next_token();
        if (tok == TK_SEMI) next_token();
    }
}

static void emit_int_to_str(void) {
    emit_line("static char *int_to_str(int n) {");
    emit_line("    static char buf[20];");
    emit_line("    sprintf(buf, \"%d\", n);");
    emit_line("    return buf;");
    emit_line("}");
    emit_line("");
}

/* ---- Parse a library-level package unit (separate compilation) ----
   A spec  `package P is <subprogram specs> end P;` -> a .h of prototypes.
   A body  `package body P is <bodies> end P;`      -> a .c of definitions. */
static void parse_package_unit(void) {
    next_token();                       /* consume 'package' */
    int is_body = 0;
    if (tok == TK_IDENT && tok_eq_ci("body")) { is_body = 1; next_token(); }
    char pname[MAX_NAME];
    int plen = tok_len;
    memcpy(pname, tok_val, tok_len);
    add_sym(SK_PACKAGE, 0);
    int psym = sym_count - 1;
    next_token();
    expect(TK_IS);
    cur_pkg = psym + 1;

    if (is_body) {
        emit_line("#include <stdio.h>");
        emit_line("#include <stdlib.h>");
        emit_line("#include <string.h>");
        emit("#include \""); emit_str_lower(pname, plen); emit_line(".h\"");
        emit_with_includes();
        emit_line("");
        emit_int_to_str();
        push_scope();
        parse_declarations();
        pop_scope();
    } else {
        emit("#ifndef "); emit_str_upper(pname, plen); emit_line("_H");
        emit("#define "); emit_str_upper(pname, plen); emit_line("_H");
        emit_line("#include \"ada_runtime.h\"");
        emit_with_includes();
        emit_line("");
        push_scope();
        parse_declarations();
        pop_scope();
        emit_line("#endif");
    }

    cur_pkg = 0;
    if (tok == TK_BEGIN) error("package initialization (begin) not supported");
    expect(TK_END);
    if (tok == TK_IDENT) next_token();
    expect(TK_SEMI);
}

/* ---- Parse a compilation unit: a main procedure or a package ---- */

static void parse_program(void) {
    parse_context();

    if (tok == TK_PACKAGE) {
        parse_package_unit();
        return;
    }

    expect(TK_PROCEDURE);

    main_name_len = tok_len;
    memcpy(main_name, tok_val, tok_len);
    next_token();
    expect(TK_IS);

    /* C preamble */
    emit_line("#include <stdio.h>");
    emit_line("#include <stdlib.h>");
    emit_line("#include <string.h>");
    emit_line("#include \"ada_runtime.h\"");
    emit_with_includes();
    emit_line("");
    emit_int_to_str();

    push_scope();
    parse_declarations();

    emit_line("int main(int argc, char **argv) {");
    indent_level++;

    expect(TK_BEGIN);
    in_main_proc = 1;
    parse_statements();
    in_main_proc = 0;

    emit_indent(); emit_line("return 0;");
    indent_level--;
    emit_line("}");

    expect(TK_END);
    if (tok == TK_IDENT) next_token();
    expect(TK_SEMI);
    pop_scope();
}

/* ---- Main ---- */

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "Usage: adacomp <input.adb> <output.c>\n");
        return 1;
    }

    src_name = argv[1];
    read_file(argv[1]);

    out_file = fopen(argv[2], "w");
    if (!out_file) {
        fprintf(stderr, "Cannot create %s\n", argv[2]);
        return 1;
    }

    next_token();
    parse_program();

    fclose(out_file);
    fprintf(stderr, "Compilation successful.\n");
    return 0;
}
