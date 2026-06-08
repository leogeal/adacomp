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

#define MAX_SRC    200000
#define MAX_TOK    4096
#define MAX_SYMS   2000
#define MAX_NAME   128
#define MAX_NEST   64

/* Source buffer */
static char src[MAX_SRC];
static int src_len = 0;
static int src_pos = 0;
static int line_num = 1;

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
    TK_STRING=70, TK_REVERSE=71, TK_TICK=72
};

/* Current token */
static int tok = 0;
static char tok_val[MAX_TOK];
static int tok_len = 0;
static int tok_int = 0;

/* Symbol kinds */
enum { SK_VAR=1, SK_CONST=2, SK_PARAM=3, SK_PROC=4, SK_FUNC=5, SK_TYPE=6 };

/* Type kinds */
enum { TY_INTEGER=1, TY_CHARACTER=2, TY_BOOLEAN=3, TY_ARRAY=4, TY_STRING=5 };

/* Symbol table */
static char sym_name[MAX_SYMS][MAX_NAME];
static int sym_nlen[MAX_SYMS];
static int sym_kind[MAX_SYMS];
static int sym_type[MAX_SYMS];
static int sym_arr_lo[MAX_SYMS];
static int sym_arr_hi[MAX_SYMS];
static int sym_arr_el[MAX_SYMS];
static int sym_arr_inner_lo[MAX_SYMS];
static int sym_arr_inner_hi[MAX_SYMS];
static int sym_scope[MAX_SYMS];
static int sym_count = 0;
static int cur_scope = 0;

/* Scope stack */
static int scope_saved[MAX_NEST];
static int scope_depth = 0;

/* Output */
static FILE *out_file = NULL;
static int indent_level = 0;

/* Main procedure name */
static char main_name[MAX_NAME];
static int main_name_len = 0;

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

static void error(const char *msg) {
    fprintf(stderr, "Error at line %d: %s\n", line_num, msg);
    exit(1);
}

/* ---- Source reading ---- */

static void read_file(const char *name) {
    FILE *f = fopen(name, "r");
    if (!f) { fprintf(stderr, "Cannot open %s\n", name); exit(1); }
    src_len = fread(src, 1, MAX_SRC - 1, f);
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
        case '=': tok=TK_EQ; break;
        case '&': tok=TK_AMP; break;
        case '\'': tok=TK_TICK; break;
        default:
            error("unexpected character");
        }
    }
}

static void expect(int expected) {
    if (tok != expected) {
        fprintf(stderr, "Expected token %d, got %d (val='%.*s') at line %d\n",
                expected, tok, tok_len, tok_val, line_num);
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

/* ---- Forward declarations ---- */
static void parse_expression(void);
static void parse_statements(void);
static void parse_declarations(void);

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
    default:           emit("int"); break;
    }
}

/* ---- Expression parser ---- */

static void emit_str_lower(const char *s, int len) {
    for (int i = 0; i < len; i++) fputc(tolower((unsigned char)s[i]), out_file);
}

static void parse_primary(void) {
    if (tok == TK_INT_LIT) {
        emit_tok_val();
        next_token();
    } else if (tok == TK_CHAR_LIT) {
        emit("'");
        if (tok_val[0] == '\'') emit("\\'");
        else if (tok_val[0] == '\\') emit("\\\\");
        else emit_char(tok_val[0]);
        emit("'");
        next_token();
    } else if (tok == TK_STR_LIT) {
        emit("\"");
        for (int i = 0; i < tok_len; i++) {
            if (tok_val[i] == '"') emit("\\\"");
            else if (tok_val[i] == '\\') emit("\\\\");
            else if (tok_val[i] == '\n') emit("\\n");
            else emit_char(tok_val[i]);
        }
        emit("\"");
        next_token();
    } else if (tok == TK_TRUE) {
        emit("1"); next_token();
    } else if (tok == TK_FALSE) {
        emit("0"); next_token();
    } else if (tok == TK_NOT) {
        emit("!"); next_token();
        parse_primary();
    } else if (tok == TK_LPAREN) {
        emit("("); next_token();
        parse_expression();
        emit(")"); expect(TK_RPAREN);
    } else if (tok == TK_MINUS) {
        emit("-"); next_token();
        parse_primary();
    } else if ((tok == TK_INTEGER || tok == TK_CHARACTER || tok == TK_BOOLEAN)
               && src_pos < src_len) {
        /* Type-name attribute: Integer'Image (X), Character'Pos (X), Character'Val (X). */
        next_token();
        if (tok != TK_TICK) error("expected ' after type name");
        next_token();
        char attr[MAX_NAME];
        int attr_len = tok_len;
        memcpy(attr, tok_val, tok_len);
        next_token();
        if (attr_len == 5 && strncasecmp(attr, "Image", 5) == 0) {
            emit("int_to_str(");
            expect(TK_LPAREN); parse_expression();
            emit(")"); expect(TK_RPAREN);
        } else if (attr_len == 3 && strncasecmp(attr, "Pos", 3) == 0) {
            emit("((int)(");
            expect(TK_LPAREN); parse_expression();
            emit("))"); expect(TK_RPAREN);
        } else if (attr_len == 3 && strncasecmp(attr, "Val", 3) == 0) {
            emit("((char)(");
            expect(TK_LPAREN); parse_expression();
            emit("))"); expect(TK_RPAREN);
        } else {
            error("unsupported type-name attribute");
        }
    } else if (tok == TK_IDENT) {
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
            if (attr_len == 6 && strncasecmp(attr, "Length", 6) == 0) {
                emit("(int)strlen(");
                emit_str_lower(saved, saved_len);
                emit(")");
            } else if (attr_len == 5 && strncasecmp(attr, "First", 5) == 0) {
                emit("1");
            } else if (attr_len == 4 && strncasecmp(attr, "Last", 4) == 0) {
                emit("(int)strlen(");
                emit_str_lower(saved, saved_len);
                emit(")");
            } else {
                error("unsupported variable attribute");
            }
            return;
        }

        /* Handle __image, __pos, __val attributes (legacy, kept harmless) */
        if (saved_len == 7 && strncmp(saved, "__image", 7) == 0) {
            /* Integer'Image(X) -> int_to_str(X) */
            emit("int_to_str(");
            expect(TK_LPAREN);
            parse_expression();
            emit(")");
            expect(TK_RPAREN);
            return;
        }
        if (saved_len == 5 && strncmp(saved, "__pos", 5) == 0) {
            emit("((int)(");
            expect(TK_LPAREN);
            parse_expression();
            emit("))");
            expect(TK_RPAREN);
            return;
        }
        if (saved_len == 5 && strncmp(saved, "__val", 5) == 0) {
            emit("((char)(");
            expect(TK_LPAREN);
            parse_expression();
            emit("))");
            expect(TK_RPAREN);
            return;
        }

        if (tok == TK_LPAREN) {
            if (sidx >= 0 && (sym_kind[sidx]==SK_PROC || sym_kind[sidx]==SK_FUNC)) {
                /* Function/procedure call */
                emit_str_lower(saved, saved_len);
                emit("(");
                next_token();
                if (tok != TK_RPAREN) {
                    parse_expression();
                    while (tok == TK_COMMA) { emit(", "); next_token(); parse_expression(); }
                }
                emit(")");
                expect(TK_RPAREN);
            } else {
                /* Array indexing */
                emit_str_lower(saved, saved_len);
                emit("[");
                next_token();
                parse_expression();
                if (sidx >= 0) { emit(" - "); emit_int(sym_arr_lo[sidx]); }
                else emit(" - 1");
                emit("]");
                expect(TK_RPAREN);
                /* Chained index for 2D arrays: name(i)(j) -> name[i-lo][j-inner_lo] */
                if (tok == TK_LPAREN && sidx >= 0 && sym_arr_inner_hi[sidx] != 0) {
                    next_token();
                    emit("[");
                    parse_expression();
                    emit(" - "); emit_int(sym_arr_inner_lo[sidx]);
                    emit("]");
                    expect(TK_RPAREN);
                }
            }
        } else if (tok == TK_DOT) {
            /* Dotted name */
            next_token();
            if (tok == TK_IDENT) {
                char sub[MAX_TOK];
                int sub_len = tok_len;
                memcpy(sub, tok_val, tok_len);
                next_token();

                /* Handle additional dots */
                while (tok == TK_DOT) {
                    next_token();
                    sub_len = tok_len;
                    memcpy(sub, tok_val, tok_len);
                    next_token();
                }

                /* Map known stdlib calls in expression context */
                if (sub_len == 14 && strncasecmp(sub, "Argument_Count", 14) == 0) {
                    emit("(argc - 1)");
                } else if (sub_len == 8 && strncasecmp(sub, "Argument", 8) == 0) {
                    emit("argv[");
                    expect(TK_LPAREN);
                    parse_expression();
                    emit("]");
                    expect(TK_RPAREN);
                } else if (sub_len == 11 && strncasecmp(sub, "End_Of_File", 11) == 0) {
                    emit("feof(");
                    expect(TK_LPAREN);
                    parse_expression();
                    emit(")");
                    expect(TK_RPAREN);
                } else if (sub_len == 8 && strncasecmp(sub, "Get_Line", 8) == 0) {
                    /* In expression context */
                    emit("ada_get_line(");
                    expect(TK_LPAREN);
                    parse_expression();
                    emit(")");
                    expect(TK_RPAREN);
                } else {
                    /* Generic: pkg_func */
                    emit_str_lower(saved, saved_len);
                    emit("_");
                    emit_str_lower(sub, sub_len);
                    if (tok == TK_LPAREN) {
                        emit("(");
                        next_token();
                        if (tok != TK_RPAREN) {
                            parse_expression();
                            while (tok == TK_COMMA) { emit(", "); next_token(); parse_expression(); }
                        }
                        emit(")");
                        expect(TK_RPAREN);
                    }
                }
            } else {
                emit_str_lower(saved, saved_len);
            }
        } else {
            /* Simple variable, or parameterless function call.
               Ada allows `X := Foo;` where Foo is a 0-arg function;
               C needs the trailing `()`. */
            emit_str_lower(saved, saved_len);
            if (sidx >= 0 && sym_kind[sidx] == SK_FUNC) {
                emit("()");
            }
        }
    } else {
        error("expected expression");
    }
}

static void parse_factor(void) {
    parse_primary();
    while (tok == TK_STAR || tok == TK_SLASH || tok == TK_MOD) {
        if (tok == TK_STAR) emit(" * ");
        else if (tok == TK_SLASH) emit(" / ");
        else emit(" % ");
        next_token();
        parse_primary();
    }
}

static void parse_term(void) {
    parse_factor();
    while (tok == TK_PLUS || tok == TK_MINUS || tok == TK_AMP) {
        if (tok == TK_AMP) emit(" + "); /* simplified concatenation */
        else if (tok == TK_PLUS) emit(" + ");
        else emit(" - ");
        next_token();
        parse_factor();
    }
}

static void parse_comparison(void) {
    parse_term();
    if (tok == TK_EQ)      { emit(" == "); next_token(); parse_term(); }
    else if (tok == TK_NEQ) { emit(" != "); next_token(); parse_term(); }
    else if (tok == TK_LT)  { emit(" < ");  next_token(); parse_term(); }
    else if (tok == TK_GT)  { emit(" > ");  next_token(); parse_term(); }
    else if (tok == TK_LE)  { emit(" <= "); next_token(); parse_term(); }
    else if (tok == TK_GE)  { emit(" >= "); next_token(); parse_term(); }
}

static void parse_expression(void) {
    parse_comparison();
    while (tok == TK_AND || tok == TK_OR) {
        if (tok == TK_AND) {
            emit(" && "); next_token();
            if (tok == TK_THEN) next_token(); /* and then */
        } else {
            emit(" || "); next_token();
            if (tok == TK_ELSE) next_token(); /* or else */
        }
        parse_comparison();
    }
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

static void parse_statement(void) {
    if (tok == TK_NULL) {
        emit_indent(); emit_line("/* null */;");
        next_token(); expect(TK_SEMI);

    } else if (tok == TK_RETURN) {
        emit_indent(); emit("return");
        next_token();
        if (tok != TK_SEMI) { emit(" "); parse_expression(); }
        else if (in_main_proc) { emit(" 0"); }
        emit_line(";"); expect(TK_SEMI);

    } else if (tok == TK_RAISE) {
        /* raise X; -> error and exit */
        next_token();
        emit_indent();
        emit("{ fprintf(stderr, \"Exception raised at line %d\\n\", ");
        emit_int(line_num);
        emit_line("); exit(1); }");
        while (tok != TK_SEMI && tok != TK_EOF) next_token();
        expect(TK_SEMI);

    } else if (tok == TK_EXIT) {
        next_token();
        if (tok == TK_WHEN) {
            emit_indent(); emit("if (");
            next_token(); parse_expression();
            emit_line(") break;");
        } else {
            emit_indent(); emit_line("break;");
        }
        expect(TK_SEMI);

    } else if (tok == TK_IF) {
        emit_indent(); emit("if (");
        next_token(); parse_expression();
        emit_line(") {"); expect(TK_THEN);
        indent_level++; parse_statements(); indent_level--;
        while (tok == TK_ELSIF) {
            emit_indent(); emit("} else if (");
            next_token(); parse_expression();
            emit_line(") {"); expect(TK_THEN);
            indent_level++; parse_statements(); indent_level--;
        }
        if (tok == TK_ELSE) {
            emit_indent(); emit_line("} else {");
            next_token();
            indent_level++; parse_statements(); indent_level--;
        }
        emit_indent(); emit_line("}");
        expect(TK_END); expect(TK_IF); expect(TK_SEMI);

    } else if (tok == TK_WHILE) {
        emit_indent(); emit("while (");
        next_token(); parse_expression();
        emit_line(") {"); expect(TK_LOOP);
        indent_level++; parse_statements(); indent_level--;
        emit_indent(); emit_line("}");
        expect(TK_END); expect(TK_LOOP); expect(TK_SEMI);

    } else if (tok == TK_LOOP) {
        emit_indent(); emit_line("while (1) {");
        next_token();
        indent_level++; parse_statements(); indent_level--;
        emit_indent(); emit_line("}");
        expect(TK_END); expect(TK_LOOP); expect(TK_SEMI);

    } else if (tok == TK_FOR) {
        next_token();
        char loop_var[MAX_NAME];
        int lv_len = tok_len;
        memcpy(loop_var, tok_val, tok_len);
        next_token();
        expect(TK_IN);

        int is_reverse = 0;
        if (tok == TK_REVERSE) { is_reverse = 1; next_token(); }

        emit_indent();
        if (is_reverse) {
            /* Wrap in a block so __lo/__hi temps can scope-shadow when nested. */
            emit("{ int __lo = ");
            parse_expression();
            expect(TK_DOTDOT);
            emit("; int __hi = ");
            parse_expression();
            emit("; for (int ");
            emit_str_lower(loop_var, lv_len);
            emit(" = __hi; ");
            emit_str_lower(loop_var, lv_len);
            emit(" >= __lo; ");
            emit_str_lower(loop_var, lv_len);
            emit_line("--) {");
        } else {
            emit("for (int ");
            emit_str_lower(loop_var, lv_len);
            emit(" = ");
            parse_expression();
            expect(TK_DOTDOT);
            emit("; ");
            emit_str_lower(loop_var, lv_len);
            emit(" <= ");
            parse_expression();
            emit("; ");
            emit_str_lower(loop_var, lv_len);
            emit_line("++) {");
        }

        expect(TK_LOOP);
        indent_level++; parse_statements(); indent_level--;
        emit_indent();
        if (is_reverse) emit_line("} }");
        else emit_line("}");
        expect(TK_END); expect(TK_LOOP); expect(TK_SEMI);

    } else if (tok == TK_DECLARE) {
        next_token();
        emit_indent(); emit_line("{");
        indent_level++;
        parse_declarations();
        expect(TK_BEGIN);
        parse_statements();
        indent_level--;
        emit_indent(); emit_line("}");
        expect(TK_END); expect(TK_SEMI);

    } else if (tok == TK_BEGIN) {
        /* Bare begin...end block */
        next_token();
        emit_indent(); emit_line("{");
        indent_level++;
        parse_statements();
        indent_level--;
        emit_indent(); emit_line("}");
        expect(TK_END); expect(TK_SEMI);

    } else if (tok == TK_IDENT) {
        char saved[MAX_TOK];
        int saved_len = tok_len;
        memcpy(saved, tok_val, tok_len);
        int sidx = find_sym(tok_val, tok_len);
        next_token();

        if (tok == TK_ASSIGN) {
            /* Assignment */
            emit_indent();
            emit_str_lower(saved, saved_len);
            emit(" = "); next_token();
            parse_expression();
            emit_line(";"); expect(TK_SEMI);

        } else if (tok == TK_LPAREN) {
            next_token();
            if (sidx >= 0 && (sym_kind[sidx]==SK_PROC || sym_kind[sidx]==SK_FUNC)) {
                /* Procedure call */
                emit_indent();
                emit_str_lower(saved, saved_len);
                emit("(");
                if (tok != TK_RPAREN) {
                    parse_expression();
                    while (tok == TK_COMMA) { emit(", "); next_token(); parse_expression(); }
                }
                emit_line(");");
                expect(TK_RPAREN); expect(TK_SEMI);
            } else {
                /* Array element assignment or function call as statement */
                /* Look ahead: after ) if := then array assignment, else call */
                /* We need to parse the index, then check */
                emit_indent();
                emit_str_lower(saved, saved_len);

                /* Save position for lookahead - but single pass, so check sym */
                if (sidx >= 0 && (sym_kind[sidx]==SK_VAR || sym_kind[sidx]==SK_PARAM) &&
                    (sym_type[sidx]==TY_ARRAY)) {
                    /* Array assignment */
                    emit("[");
                    parse_expression();
                    if (sidx >= 0) { emit(" - "); emit_int(sym_arr_lo[sidx]); }
                    else emit(" - 1");
                    emit("]");
                    expect(TK_RPAREN);
                    /* Chained second index for 2D arrays */
                    if (tok == TK_LPAREN && sym_arr_inner_hi[sidx] != 0) {
                        next_token();
                        emit("[");
                        parse_expression();
                        emit(" - "); emit_int(sym_arr_inner_lo[sidx]);
                        emit("]");
                        expect(TK_RPAREN);
                    }
                    expect(TK_ASSIGN);
                    emit(" = ");
                    parse_expression();
                    emit_line(";"); expect(TK_SEMI);
                } else {
                    /* Treat as procedure/function call */
                    emit("(");
                    if (tok != TK_RPAREN) {
                        parse_expression();
                        while (tok == TK_COMMA) { emit(", "); next_token(); parse_expression(); }
                    }
                    emit_line(");");
                    expect(TK_RPAREN); expect(TK_SEMI);
                }
            }

        } else if (tok == TK_DOT) {
            /* Package-qualified call */
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

            emit_indent();

            if (name_eq_ci(sub, sub_len, "Put_Line")) {
                expect(TK_LPAREN);
                if (has_arg_separator_ahead()) {
                    emit("ada_fput_line(");
                    parse_expression();
                    expect(TK_COMMA); emit(", ");
                    parse_expression();
                } else {
                    emit("ada_put_line(");
                    parse_expression();
                }
                emit_line(");"); expect(TK_RPAREN);
            } else if (name_eq_ci(sub, sub_len, "Put")) {
                expect(TK_LPAREN);
                if (has_arg_separator_ahead()) {
                    if (second_arg_is_char()) {
                        emit("ada_fput_char(");
                    } else {
                        emit("ada_fput_str(");
                    }
                    parse_expression();
                    expect(TK_COMMA); emit(", ");
                    parse_expression();
                } else {
                    emit("ada_put_str(");
                    parse_expression();
                }
                emit_line(");"); expect(TK_RPAREN);
            } else if (name_eq_ci(sub, sub_len, "New_Line")) {
                if (tok == TK_LPAREN) {
                    expect(TK_LPAREN);
                    if (tok != TK_RPAREN) {
                        emit("ada_fput_newline(");
                        parse_expression();
                        emit_line(");");
                    } else {
                        emit_line("ada_new_line();");
                    }
                    expect(TK_RPAREN);
                } else {
                    emit_line("ada_new_line();");
                }
            } else if (name_eq_ci(sub, sub_len, "Open")) {
                /* Ada.Text_IO.Open(F, In_File, Name) */
                expect(TK_LPAREN);
                /* First arg is file variable */
                char fvar[MAX_TOK];
                int fvar_len = tok_len;
                memcpy(fvar, tok_val, tok_len);
                parse_expression(); /* emits file var name */
                expect(TK_COMMA);
                /* Skip second arg (mode) but capture to determine r/w */
                /* Just skip tokens until comma */
                char mode[64] = "r";
                while (tok != TK_COMMA && tok != TK_RPAREN && tok != TK_EOF) {
                    if (tok_eq_ci("Out_File")) strcpy(mode, "w");
                    next_token();
                    if (tok == TK_DOT) { next_token(); next_token(); }
                }
                if (tok == TK_COMMA) next_token();
                /* Rewrite: fvar = fopen(name, mode) */
                emit(" = fopen(");
                parse_expression();
                fprintf(out_file, ", \"%s\"", mode);
                emit_line(");"); expect(TK_RPAREN);
            } else if (name_eq_ci(sub, sub_len, "Create")) {
                expect(TK_LPAREN);
                parse_expression(); /* file var */
                expect(TK_COMMA);
                while (tok != TK_COMMA && tok != TK_RPAREN && tok != TK_EOF) {
                    next_token();
                    if (tok == TK_DOT) { next_token(); next_token(); }
                }
                if (tok == TK_COMMA) next_token();
                emit(" = fopen(");
                parse_expression();
                emit(", \"w\"");
                emit_line(");"); expect(TK_RPAREN);
            } else if (name_eq_ci(sub, sub_len, "Close")) {
                emit("fclose(");
                expect(TK_LPAREN); parse_expression();
                emit_line(");"); expect(TK_RPAREN);
            } else if (name_eq_ci(sub, sub_len, "Get_Line")) {
                emit("ada_get_line(");
                expect(TK_LPAREN); parse_expression();
                emit_line(");"); expect(TK_RPAREN);
            } else if (name_eq_ci(sub, sub_len, "Get")) {
                /* Ada.Text_IO.Get(F, Ch) -> ch = fgetc(f); */
                expect(TK_LPAREN);
                /* Skip first arg (file), capture second (char var) */
                char farg[MAX_TOK]; int farg_len = 0;
                /* Emit: second_arg = fgetc(first_arg); */
                /* We need both args. Parse first into temp. */
                /* Actually, just emit inline */
                emit("{int __gc = fgetc(");
                parse_expression(); /* file arg */
                emit("); if (__gc != EOF) ");
                expect(TK_COMMA);
                parse_expression(); /* char var */
                emit_line(" = (char)__gc;}");
                expect(TK_RPAREN);
            } else {
                emit_str_lower(saved, saved_len);
                emit("_");
                emit_str_lower(sub, sub_len);
                if (tok == TK_LPAREN) {
                    emit("("); next_token();
                    if (tok != TK_RPAREN) {
                        parse_expression();
                        while (tok == TK_COMMA) { emit(", "); next_token(); parse_expression(); }
                    }
                    emit_line(");"); expect(TK_RPAREN);
                } else {
                    emit_line("();");
                }
            }
            expect(TK_SEMI);

        } else if (tok == TK_SEMI) {
            /* Procedure call with no args */
            emit_indent();
            emit_str_lower(saved, saved_len);
            emit_line("();");
            next_token();

        } else {
            fprintf(stderr, "After ident '%.*s', got token %d\n", saved_len, saved, tok);
            error("expected := or ( after identifier");
        }

    } else {
        fprintf(stderr, "Got token %d (val='%.*s')\n", tok, tok_len, tok_val);
        error("unexpected token in statement");
    }
}

static void parse_statements(void) {
    while (tok != TK_END && tok != TK_ELSIF && tok != TK_ELSE &&
           tok != TK_EOF && tok != TK_WHEN) {
        /* Skip 'exception' handler blocks */
        if (tok == TK_IDENT && tok_eq_ci("exception")) {
            /* Skip to matching 'end' */
            next_token();
            while (tok != TK_END && tok != TK_EOF) next_token();
            return;
        }
        parse_statement();
    }
}

/* ---- Declaration parser ---- */

static void parse_declarations(void) {
    while (tok != TK_BEGIN && tok != TK_EOF) {
        if (tok == TK_TYPE) {
            next_token();
            char tname[MAX_NAME];
            int tlen = tok_len;
            memcpy(tname, tok_val, tok_len);
            add_sym(SK_TYPE, TY_ARRAY);
            next_token();
            expect(TK_IS);
            if (tok == TK_ARRAY) {
                next_token();
                expect(TK_LPAREN);
                int lo = tok_int; next_token();
                expect(TK_DOTDOT);
                int hi = tok_int; next_token();
                /* Handle Name .. Name or int .. int */
                /* For multi-dimensional: (1..N, 1..M) */
                if (tok == TK_COMMA) {
                    /* 2D array */
                    next_token();
                    int lo2 = tok_int; next_token();
                    expect(TK_DOTDOT);
                    int hi2 = tok_int; next_token();
                    expect(TK_RPAREN);
                    expect(TK_OF);
                    int el = parse_type_ref();
                    sym_arr_lo[sym_count-1] = lo;
                    sym_arr_hi[sym_count-1] = hi;
                    sym_arr_el[sym_count-1] = el;
                    /* Store second dimension info - simplified */
                } else {
                    expect(TK_RPAREN);
                    expect(TK_OF);
                    int el = parse_type_ref();
                    sym_arr_lo[sym_count-1] = lo;
                    sym_arr_hi[sym_count-1] = hi;
                    sym_arr_el[sym_count-1] = el;
                }
            } else {
                /* Skip other type definitions for now */
                while (tok != TK_SEMI && tok != TK_EOF) next_token();
            }
            expect(TK_SEMI);

        } else if (tok == TK_PROCEDURE) {
            next_token();
            char pname[MAX_NAME];
            int plen = tok_len;
            memcpy(pname, tok_val, tok_len);
            add_sym(SK_PROC, 0);
            next_token();

            emit("void ");
            emit_str_lower(pname, plen);
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
                    /* Named array type as parameter: decays to pointer */
                    int arr_idx = -1;
                    if (tok == TK_IDENT) {
                        int ti = find_sym(tok_val, tok_len);
                        if (ti >= 0 && sym_kind[ti] == SK_TYPE && sym_type[ti] == TY_ARRAY) {
                            arr_idx = ti;
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
                continue;
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

        } else if (tok == TK_FUNCTION) {
            next_token();
            char fname[MAX_NAME];
            int flen = tok_len;
            memcpy(fname, tok_val, tok_len);
            add_sym(SK_FUNC, TY_INTEGER);
            next_token();

            push_scope();

            /* Collect params */
            char pnames[20][MAX_NAME];
            int plens[20];
            int ptypes[20];
            int pel_type[20];   /* element type when ptypes[i]==TY_ARRAY, else 0 */
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
                    if (tok == TK_IDENT) {
                        int ti = find_sym(tok_val, tok_len);
                        if (ti >= 0 && sym_kind[ti] == SK_TYPE && sym_type[ti] == TY_ARRAY) {
                            arr_idx = ti;
                        }
                    }
                    if (arr_idx >= 0) {
                        ptypes[pcount] = TY_ARRAY;
                        pel_type[pcount] = sym_arr_el[arr_idx];
                        sym_type[sym_count-1] = TY_ARRAY;
                        sym_arr_lo[sym_count-1] = sym_arr_lo[arr_idx];
                        sym_arr_hi[sym_count-1] = sym_arr_hi[arr_idx];
                        sym_arr_el[sym_count-1] = sym_arr_el[arr_idx];
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
            emit_str_lower(fname, flen);
            emit("(");
            for (int i = 0; i < pcount; i++) {
                if (i > 0) emit(", ");
                if (ptypes[i] == TY_ARRAY) {
                    emit_c_type(pel_type[i]);
                    emit(" *");
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
                continue;
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

        } else if (tok == TK_IDENT) {
            /* Variable declaration */
            char vname[MAX_NAME];
            int vlen = tok_len;
            memcpy(vname, tok_val, tok_len);
            next_token();

            /* Handle comma-separated names: A, B : Integer; */
            /* For simplicity, handle single names */
            expect(TK_COLON);

            int is_const = 0;
            if (tok == TK_CONSTANT) { is_const = 1; next_token(); }

            /* Anonymous inline array: Name : array (lo .. hi) of T; */
            if (tok == TK_ARRAY) {
                next_token();
                expect(TK_LPAREN);
                int lo = tok_int; next_token();
                expect(TK_DOTDOT);
                int hi = tok_int; next_token();
                expect(TK_RPAREN);
                expect(TK_OF);

                /* Element type may itself be a named array type */
                int el_type = TY_INTEGER;
                int inner_lo = 0, inner_hi = 0, inner_el = TY_INTEGER;
                int is_nested = 0;
                if (tok == TK_IDENT) {
                    int tidx = find_sym(tok_val, tok_len);
                    if (tidx >= 0 && sym_kind[tidx] == SK_TYPE && sym_type[tidx] == TY_ARRAY) {
                        is_nested = 1;
                        inner_lo = sym_arr_lo[tidx];
                        inner_hi = sym_arr_hi[tidx];
                        inner_el = sym_arr_el[tidx];
                        el_type = inner_el;
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

                emit_indent();
                if (is_const) emit("const ");
                emit_c_type(el_type);
                emit(" ");
                emit_str_lower(vname, vlen);
                emit("[");
                emit_int(hi - lo + 1);
                emit("]");
                if (is_nested) {
                    emit("[");
                    emit_int(inner_hi - inner_lo + 1);
                    emit("]");
                }
                if (tok == TK_ASSIGN) {
                    next_token();
                    emit(" = {0}");
                    while (tok != TK_SEMI && tok != TK_EOF) next_token();
                }
                emit_line(";");
                expect(TK_SEMI);
                continue;
            }

            /* Check for array type */
            if (tok == TK_IDENT) {
                int tidx = find_sym(tok_val, tok_len);
                if (tidx >= 0 && sym_kind[tidx] == SK_TYPE && sym_type[tidx] == TY_ARRAY) {
                    if (is_const) add_sym(SK_CONST, TY_ARRAY);
                    else add_sym(SK_VAR, TY_ARRAY);
                    /* Copy array info from type to variable */
                    sym_arr_lo[sym_count-1] = sym_arr_lo[tidx];
                    sym_arr_hi[sym_count-1] = sym_arr_hi[tidx];
                    sym_arr_el[sym_count-1] = sym_arr_el[tidx];
                    /* Update sym name to variable name */
                    memcpy(sym_name[sym_count-1], vname, vlen);
                    sym_nlen[sym_count-1] = vlen;

                    emit_indent();
                    emit_c_type(sym_arr_el[tidx]);
                    emit(" ");
                    emit_str_lower(vname, vlen);
                    emit("[");
                    emit_int(sym_arr_hi[tidx] - sym_arr_lo[tidx] + 1);
                    emit("]");
                    next_token();
                    if (tok == TK_ASSIGN) {
                        next_token();
                        emit(" = {0}");
                        /* Skip initializer expression */
                        while (tok != TK_SEMI && tok != TK_EOF) next_token();
                    }
                    emit_line(";");
                    expect(TK_SEMI);
                    continue;
                }
            }

            /* Check for String type with constraint */
            if (tok == TK_STRING) {
                next_token();
                if (is_const) add_sym(SK_CONST, TY_STRING);
                else add_sym(SK_VAR, TY_STRING);
                memcpy(sym_name[sym_count-1], vname, vlen);
                sym_nlen[sym_count-1] = vlen;

                emit_indent();
                emit("const char *");
                emit_str_lower(vname, vlen);

                if (tok == TK_ASSIGN) {
                    emit(" = ");
                    next_token();
                    parse_expression();
                } else {
                    emit(" = \"\"");
                }
                emit_line(";");
                expect(TK_SEMI);
                continue;
            }

            /* Check if this is a dotted type like Ada.Text_IO.File_Type */
            /* Save position to detect File_Type */
            int is_file_type = 0;
            if (tok == TK_IDENT) {
                /* peek: does this identifier lead to dots? */
                char first_ident[MAX_NAME];
                int first_len = tok_len;
                memcpy(first_ident, tok_val, tok_len);
                /* Check if next token will be a dot (look at source) */
                int save_pos = src_pos;
                int save_line = line_num;
                int save_tok = tok;
                int save_tok_len = tok_len;
                int save_tok_int = tok_int;
                char save_tok_val[MAX_TOK];
                memcpy(save_tok_val, tok_val, tok_len);

                next_token(); /* consume the ident */
                if (tok == TK_DOT) {
                    /* It's a dotted type name */
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
                        emit_indent();
                        emit("FILE *");
                        emit_str_lower(vname, vlen);
                        emit(" = NULL");
                        emit_line(";");
                        if (tok == TK_ASSIGN) {
                            next_token();
                            while (tok != TK_SEMI && tok != TK_EOF) next_token();
                        }
                        expect(TK_SEMI);
                        continue;
                    }
                    /* Non-file dotted type - treat as int */
                    if (is_const) add_sym(SK_CONST, TY_INTEGER);
                    else add_sym(SK_VAR, TY_INTEGER);
                    memcpy(sym_name[sym_count-1], vname, vlen);
                    sym_nlen[sym_count-1] = vlen;
                    emit_indent();
                    if (is_const) emit("const ");
                    emit("int ");
                    emit_str_lower(vname, vlen);
                    if (tok == TK_ASSIGN) {
                        emit(" = "); next_token();
                        parse_expression();
                    } else {
                        emit(" = 0");
                    }
                    emit_line(";");
                    expect(TK_SEMI);
                    continue;
                }
                /* Not a dotted type - restore and proceed with normal type parsing */
                /* We already consumed first_ident and have next token */
                /* The ident was consumed by next_token, need to handle it */
                /* Actually we can't easily restore. Let's handle inline. */
                /* We consumed first_ident via next_token and now tok is whatever follows */
                /* first_ident was the type name. Look it up. */
                int tidx2 = find_sym(first_ident, first_len);
                int typ2 = TY_INTEGER;
                if (tidx2 >= 0 && sym_kind[tidx2] == SK_TYPE) typ2 = sym_type[tidx2];

                if (is_const) add_sym(SK_CONST, typ2);
                else add_sym(SK_VAR, typ2);
                memcpy(sym_name[sym_count-1], vname, vlen);
                sym_nlen[sym_count-1] = vlen;
                emit_indent();
                if (is_const) emit("const ");
                emit_c_type(typ2);
                emit(" ");
                emit_str_lower(vname, vlen);
                if (tok == TK_ASSIGN) {
                    emit(" = "); next_token();
                    parse_expression();
                } else {
                    emit(" = 0");
                }
                emit_line(";");
                expect(TK_SEMI);
                continue;
            }

            int typ = parse_type_ref();
            if (is_const) add_sym(SK_CONST, typ);
            else add_sym(SK_VAR, typ);
            /* Update sym name to variable name */
            memcpy(sym_name[sym_count-1], vname, vlen);
            sym_nlen[sym_count-1] = vlen;

            emit_indent();
            if (is_const) emit("const ");
            emit_c_type(typ);
            emit(" ");
            emit_str_lower(vname, vlen);

            if (tok == TK_ASSIGN) {
                emit(" = "); next_token();
                parse_expression();
            } else if (typ == TY_STRING) {
                emit(" = \"\"");
            } else {
                emit(" = 0");
            }
            emit_line(";");
            expect(TK_SEMI);

        } else {
            /* Not a declaration - break out */
            return;
        }
    }
}

/* ---- Parse context clauses ---- */

static void parse_context(void) {
    while (tok == TK_WITH || tok == TK_USE) {
        next_token();
        while (tok != TK_SEMI && tok != TK_EOF) next_token();
        if (tok == TK_SEMI) next_token();
    }
}

/* ---- Parse main program ---- */

static void parse_program(void) {
    parse_context();
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
    emit_line("");
    emit_line("static char *int_to_str(int n) {");
    emit_line("    static char buf[20];");
    emit_line("    sprintf(buf, \"%d\", n);");
    emit_line("    return buf;");
    emit_line("}");
    emit_line("");

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
