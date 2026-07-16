/* ada_runtime.h - Minimal Ada runtime support for generated C code */
#ifndef ADA_RUNTIME_H
#define ADA_RUNTIME_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>

/* Ada Integer type */
typedef int Integer;
typedef int Boolean;
typedef char Character;

#define True 1
#define False 0

/* Simple string buffer for Ada string operations */
typedef struct {
    char data[4096];
    int length;
} Ada_String;

static void ada_put_char(char c) { putchar(c); }
static void ada_put_str(const char *s) { fputs(s, stdout); }
static void ada_put_int(int n) { printf("%d", n); }
static void ada_put_line(const char *s) { puts(s); }
static void ada_new_line(void) { putchar('\n'); }

static void ada_fput_char(FILE *f, char c) { fputc(c, f); }
static void ada_fput_str(FILE *f, const char *s) { fputs(s, f); }
static void ada_fput_int(FILE *f, int n) { fprintf(f, "%d", n); }
static void ada_fput_line(FILE *f, const char *s) { fprintf(f, "%s\n", s); }
static void ada_fput_newline(FILE *f) { fputc('\n', f); }

static void ada_error(const char *msg, int line) {
    fprintf(stderr, "Error at line %d: %s\n", line, msg);
    exit(1);
}

static int ada_argument_count(int argc) { return argc - 1; }

static const char *ada_argument(int argc, char **argv, int n) {
    if (n >= 1 && n < argc) return argv[n];
    return "";
}

static int ada_char_val(char c) { return (int)c; }
static char ada_char_chr(int n) { return (char)n; }

/* ---- Exception support (setjmp/longjmp model) ----
   A `begin ... exception ... end` frame pushes an ada_handler onto a
   global stack; `raise E` sets the current exception and longjmps to the
   top frame. With no frame installed, an unhandled exception prints to
   stderr and exits 1 (matching Ada's default behaviour). Exceptions are
   identified by small integer ids assigned by the compiler; the name is
   carried alongside purely for the unhandled-exception message. */
typedef struct ada_handler {
    jmp_buf buf;
    struct ada_handler *prev;
} ada_handler;

static ada_handler *ada_handler_top = 0;
static int ada_cur_exc = 0;                 /* id of exception in flight */
static const char *ada_cur_exc_name = "";
static const char *ada_cur_exc_msg = "";    /* from `raise E with "msg"` */

static void ada_raise_msg(int id, const char *name, const char *msg) {
    ada_cur_exc = id;
    ada_cur_exc_name = name;
    ada_cur_exc_msg = msg;
    if (ada_handler_top) longjmp(ada_handler_top->buf, 1);
    if (msg[0]) fprintf(stderr, "\nraised %s : %s\n", name, msg);
    else fprintf(stderr, "\nraised %s : unhandled exception\n", name);
    exit(1);
}

static void ada_raise(int id, const char *name) {
    ada_raise_msg(id, name, "");
}

/* Scalar range check for constrained subtypes. Returns the value if it
   lies in [lo, hi], else raises Constraint_Error (id 1). */
static int ada_range_check(int v, int lo, int hi) {
    if (v < lo || v > hi) ada_raise(1, "Constraint_Error");
    return v;
}

#endif
