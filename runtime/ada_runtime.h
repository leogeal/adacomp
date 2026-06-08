/* ada_runtime.h - Minimal Ada runtime support for generated C code */
#ifndef ADA_RUNTIME_H
#define ADA_RUNTIME_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

#endif
