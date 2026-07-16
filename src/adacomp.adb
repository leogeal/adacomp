-- adacomp.adb - Minimal self-hosting Ada-to-C compiler
-- Supports the subset of Ada needed to compile itself.
-- Usage: adacomp <input.adb> <output.c>
-- Features: procedures, functions, if/elsif/else, while/for[/reverse] loops,
--   Integer/Character/Boolean/String types, 1D and nested arrays,
--   forward declarations, attributes (Image, Pos, Val, Length, First, Last),
--   basic I/O and file I/O.

with Ada.Text_IO;
with Ada.Command_Line;

procedure Adacomp is

   -- Source buffer (dynamically grown via an access-to-unconstrained-array;
   -- 1-based, so indexing matches the old fixed array exactly).
   type Char_Vec is array (Integer range <>) of Character;
   type Char_Vec_Ptr is access Char_Vec;
   Src      : Char_Vec_Ptr;
   Src_Cap  : Integer := 0;
   Src_Len  : Integer := 0;
   Src_Pos  : Integer := 1;
   Line_Num : Integer := 1;
   Src_Name : String := "<input>";  -- input file name, for diagnostics
   Tok_Line : Integer := 1;         -- line where the current token starts
   Tok_Pos  : Integer := 1;         -- Src index where the current token starts

   -- Token types (constants)
   TK_EOF       : constant Integer := 0;
   TK_IDENT     : constant Integer := 1;
   TK_INT_LIT   : constant Integer := 2;
   TK_STR_LIT   : constant Integer := 3;
   TK_CHAR_LIT  : constant Integer := 4;
   TK_LPAREN    : constant Integer := 5;
   TK_RPAREN    : constant Integer := 6;
   TK_SEMI      : constant Integer := 7;
   TK_COLON     : constant Integer := 8;
   TK_ASSIGN    : constant Integer := 9;
   TK_COMMA     : constant Integer := 10;
   TK_DOT       : constant Integer := 11;
   TK_DOTDOT    : constant Integer := 12;
   TK_PLUS      : constant Integer := 13;
   TK_MINUS     : constant Integer := 14;
   TK_STAR      : constant Integer := 15;
   TK_SLASH     : constant Integer := 16;
   TK_EQ        : constant Integer := 17;
   TK_NEQ       : constant Integer := 18;
   TK_LT        : constant Integer := 19;
   TK_GT        : constant Integer := 20;
   TK_LE        : constant Integer := 21;
   TK_GE        : constant Integer := 22;
   TK_AMP       : constant Integer := 23;
   TK_WITH      : constant Integer := 30;
   TK_PROCEDURE : constant Integer := 32;
   TK_FUNCTION  : constant Integer := 33;
   TK_IS        : constant Integer := 34;
   TK_BEGIN     : constant Integer := 35;
   TK_END       : constant Integer := 36;
   TK_IF        : constant Integer := 37;
   TK_THEN      : constant Integer := 38;
   TK_ELSIF     : constant Integer := 39;
   TK_ELSE      : constant Integer := 40;
   TK_WHILE     : constant Integer := 41;
   TK_LOOP      : constant Integer := 42;
   TK_FOR       : constant Integer := 43;
   TK_IN        : constant Integer := 44;
   TK_RETURN    : constant Integer := 45;
   TK_TYPE      : constant Integer := 46;
   TK_ARRAY     : constant Integer := 47;
   TK_OF        : constant Integer := 48;
   TK_NOT       : constant Integer := 54;
   TK_AND       : constant Integer := 55;
   TK_OR        : constant Integer := 56;
   TK_MOD       : constant Integer := 57;
   TK_NULL      : constant Integer := 58;
   TK_CONSTANT  : constant Integer := 59;
   TK_EXIT      : constant Integer := 60;
   TK_WHEN      : constant Integer := 61;
   TK_USE       : constant Integer := 62;
   TK_INTEGER   : constant Integer := 63;
   TK_CHARACTER : constant Integer := 64;
   TK_BOOLEAN   : constant Integer := 65;
   TK_TRUE      : constant Integer := 66;
   TK_FALSE     : constant Integer := 67;
   TK_DECLARE   : constant Integer := 68;
   TK_RAISE     : constant Integer := 69;
   TK_STRING    : constant Integer := 70;
   TK_REVERSE   : constant Integer := 71;
   TK_TICK      : constant Integer := 72;
   TK_ACCESS    : constant Integer := 73;
   TK_NEW       : constant Integer := 74;
   TK_RANGE     : constant Integer := 75;
   TK_BOX       : constant Integer := 76;
   TK_RECORD    : constant Integer := 77;
   TK_PACKAGE   : constant Integer := 78;
   TK_CASE      : constant Integer := 79;
   TK_ARROW     : constant Integer := 80;
   TK_BAR       : constant Integer := 81;
   TK_EXCEPTION : constant Integer := 82;
   TK_SUBTYPE   : constant Integer := 83;
   TK_NATURAL   : constant Integer := 84;
   TK_POSITIVE  : constant Integer := 85;

   -- Current token
   type Tok_Buffer is array (1 .. 4096) of Character;
   Tok      : Integer := 0;
   Tok_Val  : Tok_Buffer;
   Tok_Len  : Integer := 0;
   Tok_Int  : Integer := 0;

   -- Symbol kinds
   SK_VAR   : constant Integer := 1;
   SK_CONST : constant Integer := 2;
   SK_PARAM : constant Integer := 3;
   SK_PROC  : constant Integer := 4;
   SK_FUNC  : constant Integer := 5;
   SK_TYPE  : constant Integer := 6;
   SK_PACKAGE : constant Integer := 7;
   SK_EXCEPTION : constant Integer := 8;

   -- Type kinds
   TY_INTEGER   : constant Integer := 1;
   TY_CHARACTER : constant Integer := 2;
   TY_BOOLEAN   : constant Integer := 3;
   TY_ARRAY     : constant Integer := 4;
   TY_STRING    : constant Integer := 5;
   TY_ACCESS    : constant Integer := 6;
   TY_RECORD    : constant Integer := 7;
   TY_ENUM      : constant Integer := 8;

   -- Symbol table (dynamically grown). Names live in a growable character
   -- pool addressed by offset+length; the per-symbol fields are growable
   -- integer arrays kept in lock-step (all share Sym_Cap).
   type Int_Vec is array (Integer range <>) of Integer;
   type Int_Vec_Ptr is access Int_Vec;
   Name_Pool         : Char_Vec_Ptr;
   Name_Pool_Cap     : Integer := 0;
   Name_Pool_Len     : Integer := 0;
   Sym_Name_Off      : Int_Vec_Ptr;
   Sym_Name_Len      : Int_Vec_Ptr;
   Sym_Kind          : Int_Vec_Ptr;
   Sym_Type          : Int_Vec_Ptr;
   Sym_Arr_Lo        : Int_Vec_Ptr;
   Sym_Arr_Hi        : Int_Vec_Ptr;
   Sym_Arr_El        : Int_Vec_Ptr;
   Sym_Arr_Inner_Lo  : Int_Vec_Ptr;
   Sym_Arr_Inner_Hi  : Int_Vec_Ptr;
   --  Scalar range constraint (subtypes and `X : Integer range L..H`):
   --  Sym_Has_Range = 1 means values are checked against
   --  [Sym_Range_Lo, Sym_Range_Hi] on assignment/initialization.
   Sym_Has_Range     : Int_Vec_Ptr;
   Sym_Range_Lo      : Int_Vec_Ptr;
   Sym_Range_Hi      : Int_Vec_Ptr;
   Sym_Cap           : Integer := 0;
   Sym_Count         : Integer := 0;

   -- Scope stack
   type Scope_Buf is array (1 .. 64) of Integer;
   Scope_Saved : Scope_Buf;
   Scope_Depth : Integer := 0;

   -- While compiling a package's declarations: the package symbol index + 1
   -- (0 = not in a package; +1 so a package at symbol index 0 isn't the
   -- "none" sentinel). Subprograms here are mangled <pkg>_<op> and tagged
   -- via Sym_Arr_Lo so call sites mangle to match.
   Cur_Pkg : Integer := 0;

   -- Exception ids: 1..4 are the predefined Ada exceptions (seeded at
   -- startup); user-declared exceptions take ids from 5 upward. The id is
   -- stored in Sym_Arr_Lo of an SK_EXCEPTION symbol.
   Next_Exc_Id : Integer := 5;

   -- Handler-arm chain produced by the most recently completed
   -- Parse_Statement_Chain that ended at an `exception` keyword (else 0).
   -- Read immediately by the enclosing begin/end frame.
   G_Pending_Handlers : Integer := 0;

   -- Simple `with P;` clauses (user packages) collected for #include "p.h".
   -- Dotted withs (Ada.Text_IO, ...) are builtins and are not collected.
   -- Anonymous inline arrays (not named types) so the nested 2D indexing
   -- With_Buf (I) (J) is recognised, as for P_Names elsewhere.
   With_Buf   : array (1 .. 32) of Tok_Buffer;
   With_NLen  : array (1 .. 32) of Integer;
   With_Count : Integer := 0;

   -- Set by `use Ada.Text_IO;` in the context clause: bare Put_Line /
   -- Put / New_Line / ... statements then resolve to the Text_IO builtins.
   Use_Text_IO : Boolean := False;

   -- Output
   Out_File : Ada.Text_IO.File_Type;

   -- Indentation
   Indent_Level : Integer := 0;

   -- True while emitting the outer program's body (so a bare `return;`
   -- becomes `return 0;` in C's int main).
   In_Main_Proc : Integer := 0;

   -- ---- AST (expressions only, for now) ----
   -- The parser builds an explicit tree for each top-level expression,
   -- then the walker emits it. Statements and declarations still emit
   -- directly; Phase 1 introduces the AST incrementally. Index 0 is
   -- reserved as "no node"; allocations start at 1.

   -- AST node kinds
   A_INT_LIT   : constant Integer := 1;
   A_CHAR_LIT  : constant Integer := 2;
   A_STR_LIT   : constant Integer := 3;
   A_BOOL_LIT  : constant Integer := 4;
   A_IDENT     : constant Integer := 5;
   A_UNARY     : constant Integer := 6;
   A_BINARY    : constant Integer := 7;
   A_INDEX     : constant Integer := 8;
   A_INDEX2    : constant Integer := 9;
   A_CALL      : constant Integer := 10;
   A_DOTTED    : constant Integer := 11;
   A_ATTR_TYPE : constant Integer := 12;
   A_ATTR_VAR  : constant Integer := 13;
   A_NEW       : constant Integer := 14;
   A_FIELD     : constant Integer := 15;
   A_ALL       : constant Integer := 16;
   --  Case range choice `when lo .. hi =>`; only appears in case arms.
   A_RANGE     : constant Integer := 17;

   -- Operator codes (for UNARY / BINARY)
   OP_ADD : constant Integer := 1;
   OP_SUB : constant Integer := 2;
   OP_MUL : constant Integer := 3;
   OP_DIV : constant Integer := 4;
   OP_MOD : constant Integer := 5;
   OP_EQ  : constant Integer := 6;
   OP_NEQ : constant Integer := 7;
   OP_LT  : constant Integer := 8;
   OP_GT  : constant Integer := 9;
   OP_LE  : constant Integer := 10;
   OP_GE  : constant Integer := 11;
   OP_AND : constant Integer := 12;
   OP_OR  : constant Integer := 13;
   OP_NEG : constant Integer := 14;
   OP_NOT : constant Integer := 15;

   -- Attribute kinds (for ATTR_TYPE / ATTR_VAR)
   ATTR_IMAGE  : constant Integer := 1;
   ATTR_POS    : constant Integer := 2;
   ATTR_VAL    : constant Integer := 3;
   ATTR_LENGTH : constant Integer := 4;
   ATTR_FIRST  : constant Integer := 5;
   ATTR_LAST   : constant Integer := 6;
   ATTR_SUCC   : constant Integer := 7;
   ATTR_PRED   : constant Integer := 8;

   -- Statement-leaf AST node kinds.
   S_NULL         : constant Integer := 20;
   S_RETURN       : constant Integer := 21;
   S_RAISE        : constant Integer := 22;
   S_EXIT         : constant Integer := 23;
   S_ASSIGN       : constant Integer := 24;
   S_CALL         : constant Integer := 25;
   S_PARAMLESS    : constant Integer := 26;
   S_ARRAY_ASSIGN : constant Integer := 27;
   S_FIELD_ASSIGN : constant Integer := 28;

   -- Compound statements and dotted package calls (Pass B.2): full
   -- subtree nodes, so a program unit's body is one tree walked after
   -- the unit is fully parsed.
   S_IF      : constant Integer := 40;
   S_ELSIF   : constant Integer := 41;
   S_WHILE   : constant Integer := 42;
   S_LOOP    : constant Integer := 43;
   S_FOR     : constant Integer := 44;
   S_DECLARE : constant Integer := 45;
   S_BLOCK   : constant Integer := 46;
   S_PKG     : constant Integer := 47;
   S_CASE    : constant Integer := 48;
   S_WHEN    : constant Integer := 49;
   S_EXC_ID  : constant Integer := 50;
   S_ALL_ASSIGN : constant Integer := 51;
   S_FREE    : constant Integer := 52;

   -- Sub-ops for S_PKG (dotted Ada.Text_IO.* statement calls).
   PKG_PUT_LINE : constant Integer := 1;
   PKG_PUT      : constant Integer := 2;
   PKG_NEW_LINE : constant Integer := 3;
   PKG_OPEN     : constant Integer := 4;
   PKG_CREATE   : constant Integer := 5;
   PKG_CLOSE    : constant Integer := 6;
   PKG_GET_LINE : constant Integer := 7;
   PKG_GET      : constant Integer := 8;
   PKG_GENERIC  : constant Integer := 9;

   -- Variable-declaration leaf nodes. Type definitions and procedure /
   -- function declarations still direct-emit during parse and return 0.
   D_VAR_SIMPLE      : constant Integer := 30;
   D_VAR_NAMED_ARRAY : constant Integer := 31;
   D_VAR_ANON_ARRAY  : constant Integer := 32;
   D_VAR_STRING      : constant Integer := 33;
   D_VAR_FILE        : constant Integer := 34;
   D_VAR_DOTTED      : constant Integer := 35;
   D_VAR_ACCESS      : constant Integer := 36;
   D_VAR_RECORD      : constant Integer := 37;

   -- Node storage: 13 parallel growable arrays (access-to-Int_Vec, the
   -- type introduced for the symbol table). Reset_AST only rewinds the
   -- lengths and keeps the capacity, so a unit's peak allocation is
   -- reached once and reused for every later unit.
   N_Kind    : Int_Vec_Ptr;
   N_Op      : Int_Vec_Ptr;
   N_Int     : Int_Vec_Ptr;  -- literal value, sym index, or sub-name length for DOTTED
   N_Str_Off : Int_Vec_Ptr;  -- offset into NPool
   N_Str_Len : Int_Vec_Ptr;
   N_Left    : Int_Vec_Ptr;  -- primary operand
   N_Right   : Int_Vec_Ptr;  -- BINARY rhs / INDEX rhs
   N_Arg2    : Int_Vec_Ptr;  -- INDEX2 second index / DOTTED sub-name offset
   N_First   : Int_Vec_Ptr;  -- arg list head for CALL / DOTTED
   N_Next    : Int_Vec_Ptr;  -- sibling pointer in arg lists
   N_Aux1    : Int_Vec_Ptr;  -- resolved-at-build scratch: inner subtrahend / el type / had-parens
   N_Aux2    : Int_Vec_Ptr;  -- resolved-at-build scratch: outer dim count
   N_Line    : Int_Vec_Ptr;
   N_Cap     : Integer := 0;
   N_Count   : Integer := 1;  -- index 0 reserved; allocations start at 1

   -- Character pool for AST names and string literals (growable).
   NPool     : Char_Vec_Ptr;
   NPool_Cap : Integer := 0;
   NPool_Len : Integer := 0;

   -- Helper: lowercase character
   function To_Lower (C : Character) return Character is
   begin
      if C >= 'A' and C <= 'Z' then
         return Character'Val (Character'Pos (C) + 32);
      end if;
      return C;
   end To_Lower;

   -- Helper: uppercase character (for header include guards)
   function To_Upper (C : Character) return Character is
   begin
      if C >= 'a' and C <= 'z' then
         return Character'Val (Character'Pos (C) - 32);
      end if;
      return C;
   end To_Upper;

   function Is_Alpha (C : Character) return Boolean is
   begin
      return (C >= 'a' and C <= 'z') or (C >= 'A' and C <= 'Z') or C = '_';
   end Is_Alpha;

   function Is_Digit (C : Character) return Boolean is
   begin
      return C >= '0' and C <= '9';
   end Is_Digit;

   function Is_Alnum (C : Character) return Boolean is
   begin
      return Is_Alpha (C) or Is_Digit (C);
   end Is_Alnum;

   -- Report an error located at the current token, in the gcc-style
   -- `file:line:col: error: msg` form, followed by the offending source
   -- line and a caret under the column.
   procedure Error (Msg : String) is
      Pos : Integer;
      LS  : Integer;
      LE  : Integer;
      Col : Integer;
   begin
      Pos := Tok_Pos;
      if Pos > Src_Len then Pos := Src_Len; end if;
      if Pos < 1 then Pos := 1; end if;
      LS := Pos;
      while LS > 1 and then Src (LS - 1) /= Character'Val (10) loop
         LS := LS - 1;
      end loop;
      LE := Pos;
      while LE <= Src_Len and then Src (LE) /= Character'Val (10) loop
         LE := LE + 1;
      end loop;
      Col := Pos - LS + 1;
      Ada.Text_IO.Put (Src_Name);
      Ada.Text_IO.Put (":");
      Ada.Text_IO.Put (Integer'Image (Tok_Line));
      Ada.Text_IO.Put (":");
      Ada.Text_IO.Put (Integer'Image (Col));
      Ada.Text_IO.Put (": error: ");
      Ada.Text_IO.Put_Line (Msg);
      if Src_Len > 0 then
         Ada.Text_IO.Put ("  ");
         for I in LS .. LE - 1 loop
            Ada.Text_IO.Put (Src (I));
         end loop;
         Ada.Text_IO.New_Line;
         Ada.Text_IO.Put ("  ");
         for I in LS .. Pos - 1 loop
            Ada.Text_IO.Put (' ');
         end loop;
         Ada.Text_IO.Put_Line ("^");
      end if;
      raise Program_Error;
   end Error;

   -- Grow Src so it can hold at least Need characters (geometric growth).
   procedure Ensure_Src_Cap (Need : Integer) is
      New_Cap : Integer;
      New_Buf : Char_Vec_Ptr;
   begin
      if Need <= Src_Cap then return; end if;
      New_Cap := Src_Cap * 2 + 65536;
      if New_Cap < Need then New_Cap := Need; end if;
      New_Buf := new Char_Vec (1 .. New_Cap);
      for I in 1 .. Src_Len loop
         New_Buf (I) := Src (I);
      end loop;
      Src := New_Buf;
      Src_Cap := New_Cap;
   end Ensure_Src_Cap;

   procedure Read_Source (Name : String) is
      F  : Ada.Text_IO.File_Type;
      Ch : Character;
   begin
      Ada.Text_IO.Open (F, Ada.Text_IO.In_File, Name);
      Src_Len := 0;
      while not Ada.Text_IO.End_Of_File (F) loop
         Ada.Text_IO.Get (F, Ch);
         --  Grow BEFORE bumping Src_Len, so Ensure_Src_Cap's copy loop
         --  (1 .. Src_Len) only touches already-valid elements — the old
         --  buffer may still be null on the first growth.
         Ensure_Src_Cap (Src_Len + 1);
         Src_Len := Src_Len + 1;
         Src (Src_Len) := Ch;
      end loop;
      Ada.Text_IO.Close (F);
      if Src_Len > 0 and then Character'Pos (Src (Src_Len)) > 127 then
         Src_Len := Src_Len - 1;
      end if;
   end Read_Source;

   function Peek return Character is
   begin
      if Src_Pos > Src_Len then
         return Character'Val (0);
      end if;
      return Src (Src_Pos);
   end Peek;

   procedure Advance is
   begin
      if Src_Pos <= Src_Len then
         if Src (Src_Pos) = Character'Val (10) then
            Line_Num := Line_Num + 1;
         end if;
         Src_Pos := Src_Pos + 1;
      end if;
   end Advance;

   procedure Skip_Space is
   begin
      loop
         while Src_Pos <= Src_Len and then
               (Peek = ' ' or Peek = Character'Val (9) or
                Peek = Character'Val (10) or Peek = Character'Val (13))
         loop
            Advance;
         end loop;
         if Src_Pos < Src_Len and then Peek = '-' and then Src (Src_Pos + 1) = '-' then
            while Src_Pos <= Src_Len and then Peek /= Character'Val (10) loop
               Advance;
            end loop;
         else
            exit;
         end if;
      end loop;
   end Skip_Space;

   function Tok_Eq_CI (S : String) return Boolean is
   begin
      if Tok_Len /= S'Length then
         return False;
      end if;
      for I in 1 .. Tok_Len loop
         if To_Lower (Tok_Val (I)) /= To_Lower (S (S'First + I - 1)) then
            return False;
         end if;
      end loop;
      return True;
   end Tok_Eq_CI;

   function Check_Keyword return Integer is
   begin
      if Tok_Eq_CI ("with") then return TK_WITH; end if;
      if Tok_Eq_CI ("use") then return TK_USE; end if;
      if Tok_Eq_CI ("procedure") then return TK_PROCEDURE; end if;
      if Tok_Eq_CI ("function") then return TK_FUNCTION; end if;
      if Tok_Eq_CI ("is") then return TK_IS; end if;
      if Tok_Eq_CI ("begin") then return TK_BEGIN; end if;
      if Tok_Eq_CI ("end") then return TK_END; end if;
      if Tok_Eq_CI ("if") then return TK_IF; end if;
      if Tok_Eq_CI ("then") then return TK_THEN; end if;
      if Tok_Eq_CI ("elsif") then return TK_ELSIF; end if;
      if Tok_Eq_CI ("else") then return TK_ELSE; end if;
      if Tok_Eq_CI ("while") then return TK_WHILE; end if;
      if Tok_Eq_CI ("loop") then return TK_LOOP; end if;
      if Tok_Eq_CI ("for") then return TK_FOR; end if;
      if Tok_Eq_CI ("in") then return TK_IN; end if;
      if Tok_Eq_CI ("reverse") then return TK_REVERSE; end if;
      if Tok_Eq_CI ("return") then return TK_RETURN; end if;
      if Tok_Eq_CI ("type") then return TK_TYPE; end if;
      if Tok_Eq_CI ("subtype") then return TK_SUBTYPE; end if;
      if Tok_Eq_CI ("array") then return TK_ARRAY; end if;
      if Tok_Eq_CI ("of") then return TK_OF; end if;
      if Tok_Eq_CI ("access") then return TK_ACCESS; end if;
      if Tok_Eq_CI ("new") then return TK_NEW; end if;
      if Tok_Eq_CI ("range") then return TK_RANGE; end if;
      if Tok_Eq_CI ("record") then return TK_RECORD; end if;
      if Tok_Eq_CI ("package") then return TK_PACKAGE; end if;
      if Tok_Eq_CI ("case") then return TK_CASE; end if;
      if Tok_Eq_CI ("not") then return TK_NOT; end if;
      if Tok_Eq_CI ("and") then return TK_AND; end if;
      if Tok_Eq_CI ("or") then return TK_OR; end if;
      if Tok_Eq_CI ("mod") then return TK_MOD; end if;
      if Tok_Eq_CI ("null") then return TK_NULL; end if;
      if Tok_Eq_CI ("constant") then return TK_CONSTANT; end if;
      if Tok_Eq_CI ("exit") then return TK_EXIT; end if;
      if Tok_Eq_CI ("when") then return TK_WHEN; end if;
      if Tok_Eq_CI ("declare") then return TK_DECLARE; end if;
      if Tok_Eq_CI ("raise") then return TK_RAISE; end if;
      if Tok_Eq_CI ("exception") then return TK_EXCEPTION; end if;
      if Tok_Eq_CI ("Integer") then return TK_INTEGER; end if;
      if Tok_Eq_CI ("Natural") then return TK_NATURAL; end if;
      if Tok_Eq_CI ("Positive") then return TK_POSITIVE; end if;
      if Tok_Eq_CI ("Character") then return TK_CHARACTER; end if;
      if Tok_Eq_CI ("Boolean") then return TK_BOOLEAN; end if;
      if Tok_Eq_CI ("String") then return TK_STRING; end if;
      if Tok_Eq_CI ("True") then return TK_TRUE; end if;
      if Tok_Eq_CI ("False") then return TK_FALSE; end if;
      return TK_IDENT;
   end Check_Keyword;

   -- Get next token. The apostrophe after an identifier (e.g. `S'Length`,
   -- `Integer'Image`) is intentionally NOT consumed here — the parser
   -- receives a TK_TICK next and dispatches based on the prefix.
   procedure Next_Token is
   begin
      Skip_Space;
      Tok_Line := Line_Num;   -- record where this token starts, for diagnostics
      Tok_Pos := Src_Pos;
      Tok_Len := 0;
      Tok_Int := 0;

      if Src_Pos > Src_Len then
         Tok := TK_EOF;
         return;
      end if;

      -- Identifiers and keywords
      if Is_Alpha (Peek) then
         while Src_Pos <= Src_Len and then Is_Alnum (Peek) loop
            Tok_Len := Tok_Len + 1;
            Tok_Val (Tok_Len) := Peek;
            Advance;
         end loop;
         Tok := Check_Keyword;
         return;
      end if;

      -- Integer literals
      if Is_Digit (Peek) then
         while Src_Pos <= Src_Len and then Is_Digit (Peek) loop
            Tok_Int := Tok_Int * 10 + (Character'Pos (Peek) - Character'Pos ('0'));
            Tok_Len := Tok_Len + 1;
            Tok_Val (Tok_Len) := Peek;
            Advance;
         end loop;
         Tok := TK_INT_LIT;
         return;
      end if;

      -- String literals. Ada doubles `"` to embed a literal quote inside a
      -- string ("" -> "), so each `"` we encounter must be checked against
      -- its follower before being treated as the closer.
      if Peek = '"' then
         Advance;
         while Src_Pos <= Src_Len loop
            if Peek = '"' then
               if Src_Pos < Src_Len and then Src (Src_Pos + 1) = '"' then
                  Tok_Len := Tok_Len + 1;
                  Tok_Val (Tok_Len) := '"';
                  Advance;
                  Advance;
               else
                  Advance;
                  exit;
               end if;
            else
               Tok_Len := Tok_Len + 1;
               Tok_Val (Tok_Len) := Peek;
               Advance;
            end if;
         end loop;
         Tok := TK_STR_LIT;
         return;
      end if;

      -- Character literals: '<c>'
      if Peek = ''' and then Src_Pos + 2 <= Src_Len and then Src (Src_Pos + 2) = ''' then
         Advance;
         Tok_Len := 1;
         Tok_Val (1) := Peek;
         Advance;
         Advance;
         Tok := TK_CHAR_LIT;
         return;
      end if;

      -- Operators and punctuation
      declare
         C : Character;
      begin
         C := Peek;
         Advance;
         if C = ':' then
            if Src_Pos <= Src_Len and then Peek = '=' then
               Advance; Tok := TK_ASSIGN;
            else
               Tok := TK_COLON;
            end if;
         elsif C = '.' then
            if Src_Pos <= Src_Len and then Peek = '.' then
               Advance; Tok := TK_DOTDOT;
            else
               Tok := TK_DOT;
            end if;
         elsif C = '/' then
            if Src_Pos <= Src_Len and then Peek = '=' then
               Advance; Tok := TK_NEQ;
            else
               Tok := TK_SLASH;
            end if;
         elsif C = '<' then
            if Src_Pos <= Src_Len and then Peek = '=' then
               Advance; Tok := TK_LE;
            elsif Src_Pos <= Src_Len and then Peek = '>' then
               Advance; Tok := TK_BOX;
            else
               Tok := TK_LT;
            end if;
         elsif C = '>' then
            if Src_Pos <= Src_Len and then Peek = '=' then
               Advance; Tok := TK_GE;
            else
               Tok := TK_GT;
            end if;
         elsif C = '(' then Tok := TK_LPAREN;
         elsif C = ')' then Tok := TK_RPAREN;
         elsif C = ';' then Tok := TK_SEMI;
         elsif C = ',' then Tok := TK_COMMA;
         elsif C = '+' then Tok := TK_PLUS;
         elsif C = '-' then Tok := TK_MINUS;
         elsif C = '*' then Tok := TK_STAR;
         elsif C = '=' then
            if Src_Pos <= Src_Len and then Peek = '>' then
               Advance; Tok := TK_ARROW;
            else
               Tok := TK_EQ;
            end if;
         elsif C = '&' then Tok := TK_AMP;
         elsif C = ''' then Tok := TK_TICK;
         elsif C = '|' then Tok := TK_BAR;
         else
            Error ("unexpected character");
         end if;
      end;
   end Next_Token;

   procedure Expect (Expected : Integer) is
   begin
      if Tok /= Expected then
         Error ("unexpected token");
      end if;
      Next_Token;
   end Expect;

   -- Look ahead from the current position to determine whether a top-level
   -- ',' appears before the matching ')'. Saves/restores all lex state.
   function Has_Arg_Separator_Ahead return Boolean is
      Save_Src_Pos : Integer;
      Save_Line    : Integer;
      Save_Tok     : Integer;
      Save_Tok_Len : Integer;
      Save_Tok_Int : Integer;
      Save_Tok_Val : Tok_Buffer;
      Depth        : Integer := 0;
      Found        : Boolean := False;
   begin
      Save_Src_Pos := Src_Pos;
      Save_Line    := Line_Num;
      Save_Tok     := Tok;
      Save_Tok_Len := Tok_Len;
      Save_Tok_Int := Tok_Int;
      for I in 1 .. Tok_Len loop
         Save_Tok_Val (I) := Tok_Val (I);
      end loop;

      while Tok /= TK_EOF loop
         if Tok = TK_LPAREN then
            Depth := Depth + 1;
         elsif Tok = TK_RPAREN then
            if Depth = 0 then exit; end if;
            Depth := Depth - 1;
         elsif Tok = TK_COMMA and Depth = 0 then
            Found := True;
            exit;
         end if;
         Next_Token;
      end loop;

      Src_Pos  := Save_Src_Pos;
      Line_Num := Save_Line;
      Tok      := Save_Tok;
      Tok_Len  := Save_Tok_Len;
      Tok_Int  := Save_Tok_Int;
      for I in 1 .. Save_Tok_Len loop
         Tok_Val (I) := Save_Tok_Val (I);
      end loop;
      return Found;
   end Has_Arg_Separator_Ahead;

   -- With the current token being '.', check whether the next token is
   -- the reserved word `all` (P.all dereference). Saves/restores state.
   function All_Follows_Dot return Boolean is
      Save_Src_Pos : Integer;
      Save_Line    : Integer;
      Save_Tok     : Integer;
      Save_Tok_Len : Integer;
      Save_Tok_Int : Integer;
      Save_Tok_Val : Tok_Buffer;
      Found        : Boolean;
   begin
      Save_Src_Pos := Src_Pos;
      Save_Line    := Line_Num;
      Save_Tok     := Tok;
      Save_Tok_Len := Tok_Len;
      Save_Tok_Int := Tok_Int;
      for I in 1 .. Tok_Len loop
         Save_Tok_Val (I) := Tok_Val (I);
      end loop;

      Next_Token;
      Found := Tok = TK_IDENT and then Tok_Eq_CI ("all");

      Src_Pos  := Save_Src_Pos;
      Line_Num := Save_Line;
      Tok      := Save_Tok;
      Tok_Len  := Save_Tok_Len;
      Tok_Int  := Save_Tok_Int;
      for I in 1 .. Save_Tok_Len loop
         Tok_Val (I) := Save_Tok_Val (I);
      end loop;
      return Found;
   end All_Follows_Dot;

   -- With the current token being `is`, check whether the next token is
   -- `new` (a generic instantiation). Saves/restores lexer state.
   function New_Follows_Is return Boolean is
      Save_Src_Pos : Integer;
      Save_Line    : Integer;
      Save_Tok     : Integer;
      Save_Tok_Len : Integer;
      Save_Tok_Int : Integer;
      Save_Tok_Val : Tok_Buffer;
      Found        : Boolean;
   begin
      Save_Src_Pos := Src_Pos;
      Save_Line    := Line_Num;
      Save_Tok     := Tok;
      Save_Tok_Len := Tok_Len;
      Save_Tok_Int := Tok_Int;
      for I in 1 .. Tok_Len loop
         Save_Tok_Val (I) := Tok_Val (I);
      end loop;

      Next_Token;
      Found := Tok = TK_NEW;

      Src_Pos  := Save_Src_Pos;
      Line_Num := Save_Line;
      Tok      := Save_Tok;
      Tok_Len  := Save_Tok_Len;
      Tok_Int  := Save_Tok_Int;
      for I in 1 .. Save_Tok_Len loop
         Tok_Val (I) := Save_Tok_Val (I);
      end loop;
      return Found;
   end New_Follows_Is;

   -- With the current token being an identifier, check whether the next
   -- token is ':' (a handler occurrence parameter `when E : ...`).
   function Colon_Follows_Ident return Boolean is
      Save_Src_Pos : Integer;
      Save_Line    : Integer;
      Save_Tok     : Integer;
      Save_Tok_Len : Integer;
      Save_Tok_Int : Integer;
      Save_Tok_Val : Tok_Buffer;
      Found        : Boolean;
   begin
      Save_Src_Pos := Src_Pos;
      Save_Line    := Line_Num;
      Save_Tok     := Tok;
      Save_Tok_Len := Tok_Len;
      Save_Tok_Int := Tok_Int;
      for I in 1 .. Tok_Len loop
         Save_Tok_Val (I) := Tok_Val (I);
      end loop;

      Next_Token;
      Found := Tok = TK_COLON;

      Src_Pos  := Save_Src_Pos;
      Line_Num := Save_Line;
      Tok      := Save_Tok;
      Tok_Len  := Save_Tok_Len;
      Tok_Int  := Save_Tok_Int;
      for I in 1 .. Save_Tok_Len loop
         Tok_Val (I) := Save_Tok_Val (I);
      end loop;
      return Found;
   end Colon_Follows_Ident;

   -- Given we're positioned just past `(` of a 2-arg call (and we already
   -- confirmed a top-level comma is present), look ahead to determine
   -- whether the second argument is character-typed. Saves/restores state.
   function Find_Sym (Buf : Tok_Buffer; BLen : Integer) return Integer;

   function Second_Arg_Is_Char return Boolean is
      Save_Src_Pos : Integer;
      Save_Line    : Integer;
      Save_Tok     : Integer;
      Save_Tok_Len : Integer;
      Save_Tok_Int : Integer;
      Save_Tok_Val : Tok_Buffer;
      Depth        : Integer := 0;
      Reached      : Boolean := False;
      Is_Char      : Boolean := False;
      Idx          : Integer;
   begin
      Save_Src_Pos := Src_Pos;
      Save_Line    := Line_Num;
      Save_Tok     := Tok;
      Save_Tok_Len := Tok_Len;
      Save_Tok_Int := Tok_Int;
      for I in 1 .. Tok_Len loop
         Save_Tok_Val (I) := Tok_Val (I);
      end loop;

      while Tok /= TK_EOF loop
         if Tok = TK_LPAREN then
            Depth := Depth + 1;
            Next_Token;
         elsif Tok = TK_RPAREN then
            if Depth = 0 then exit; end if;
            Depth := Depth - 1;
            Next_Token;
         elsif Tok = TK_COMMA and Depth = 0 then
            Next_Token;
            Reached := True;
            exit;
         else
            Next_Token;
         end if;
      end loop;

      if Reached then
         if Tok = TK_CHAR_LIT then
            Is_Char := True;
         elsif Tok = TK_IDENT then
            Idx := Find_Sym (Tok_Val, Tok_Len);
            if Idx > 0 then
               if Sym_Type (Idx) = TY_CHARACTER then
                  Is_Char := True;
               elsif Sym_Type (Idx) = TY_ARRAY
                     and then Sym_Arr_El (Idx) = TY_CHARACTER then
                  Next_Token;
                  if Tok = TK_LPAREN then
                     Is_Char := True;
                  end if;
               end if;
            end if;
         end if;
      end if;

      Src_Pos  := Save_Src_Pos;
      Line_Num := Save_Line;
      Tok      := Save_Tok;
      Tok_Len  := Save_Tok_Len;
      Tok_Int  := Save_Tok_Int;
      for I in 1 .. Save_Tok_Len loop
         Tok_Val (I) := Save_Tok_Val (I);
      end loop;
      return Is_Char;
   end Second_Arg_Is_Char;

   -- Whether the argument at the current position (just past a consumed
   -- "(") is character-typed — picks ada_put_char vs ada_put_str for the
   -- one-argument Put form.
   function First_Arg_Is_Char return Boolean is
      Save_Src_Pos : Integer;
      Save_Line    : Integer;
      Save_Tok     : Integer;
      Save_Tok_Len : Integer;
      Save_Tok_Int : Integer;
      Save_Tok_Val : Tok_Buffer;
      Is_Char      : Boolean := False;
      Idx          : Integer;
   begin
      Save_Src_Pos := Src_Pos;
      Save_Line    := Line_Num;
      Save_Tok     := Tok;
      Save_Tok_Len := Tok_Len;
      Save_Tok_Int := Tok_Int;
      for I in 1 .. Tok_Len loop
         Save_Tok_Val (I) := Tok_Val (I);
      end loop;

      if Tok = TK_CHAR_LIT then
         Is_Char := True;
      elsif Tok = TK_IDENT then
         Idx := Find_Sym (Tok_Val, Tok_Len);
         if Idx > 0 then
            if Sym_Type (Idx) = TY_CHARACTER then
               Is_Char := True;
            elsif Sym_Type (Idx) = TY_ARRAY
                  and then Sym_Arr_El (Idx) = TY_CHARACTER then
               Next_Token;
               if Tok = TK_LPAREN then
                  Is_Char := True;
               end if;
            end if;
         end if;
      end if;

      Src_Pos  := Save_Src_Pos;
      Line_Num := Save_Line;
      Tok      := Save_Tok;
      Tok_Len  := Save_Tok_Len;
      Tok_Int  := Save_Tok_Int;
      for I in 1 .. Save_Tok_Len loop
         Tok_Val (I) := Save_Tok_Val (I);
      end loop;
      return Is_Char;
   end First_Arg_Is_Char;

   -- Emitter helpers
   procedure Emit (S : String) is
   begin
      Ada.Text_IO.Put (Out_File, S);
   end Emit;

   procedure Emit_Ch (C : Character) is
   begin
      Ada.Text_IO.Put (Out_File, C);
   end Emit_Ch;

   procedure Emit_Ln (S : String) is
   begin
      Ada.Text_IO.Put_Line (Out_File, S);
   end Emit_Ln;

   procedure Emit_Indent is
   begin
      for I in 1 .. Indent_Level loop
         Emit ("    ");
      end loop;
   end Emit_Indent;

   procedure Emit_Int (N : Integer) is
      Tmp : Integer;
      Buf : array (1 .. 12) of Character;
      Pos : Integer := 12;
      Neg : Boolean := False;
   begin
      if N = 0 then
         Emit_Ch ('0');
         return;
      end if;
      Tmp := N;
      if Tmp < 0 then
         Neg := True;
         Tmp := 0 - Tmp;
      end if;
      while Tmp > 0 loop
         Buf (Pos) := Character'Val (Character'Pos ('0') + (Tmp mod 10));
         Pos := Pos - 1;
         Tmp := Tmp / 10;
      end loop;
      if Neg then
         Emit_Ch ('-');
      end if;
      for I in Pos + 1 .. 12 loop
         Emit_Ch (Buf (I));
      end loop;
   end Emit_Int;

   procedure Emit_Tok is
   begin
      for I in 1 .. Tok_Len loop
         Emit_Ch (Tok_Val (I));
      end loop;
   end Emit_Tok;

   procedure Emit_Lower (Buf : Tok_Buffer; Len : Integer) is
   begin
      for I in 1 .. Len loop
         Emit_Ch (To_Lower (Buf (I)));
      end loop;
   end Emit_Lower;

   procedure Emit_Upper (Buf : Tok_Buffer; Len : Integer) is
   begin
      for I in 1 .. Len loop
         Emit_Ch (To_Upper (Buf (I)));
      end loop;
   end Emit_Upper;

   -- Emit `#include "<pkg>.h"` for each simple `with` clause collected.
   procedure Emit_With_Includes is
   begin
      for I in 1 .. With_Count loop
         Emit ("#include """);
         Emit_Lower (With_Buf (I), With_NLen (I));
         Emit_Ln (".h""");
      end loop;
   end Emit_With_Includes;

   -- Emit a symbol's name (held in the Name_Pool) in lowercase.
   procedure Emit_Name_Pool_Lower (Off : Integer; Len : Integer) is
   begin
      for I in 1 .. Len loop
         Emit_Ch (To_Lower (Name_Pool (Off + I - 1)));
      end loop;
   end Emit_Name_Pool_Lower;

   procedure Emit_Name_Pool_Upper (Off : Integer; Len : Integer) is
   begin
      for I in 1 .. Len loop
         Emit_Ch (To_Upper (Name_Pool (Off + I - 1)));
      end loop;
   end Emit_Name_Pool_Upper;

   -- A subprogram's emitted C name: <pkg>_<name> inside a package, else
   -- just <name>. Cur_Pkg is the package symbol index + 1 (0 = none).
   procedure Emit_Sub_Name (Buf : Tok_Buffer; Len : Integer) is
   begin
      if Cur_Pkg /= 0 then
         Emit_Name_Pool_Lower (Sym_Name_Off (Cur_Pkg - 1), Sym_Name_Len (Cur_Pkg - 1));
         Emit ("_");
      end if;
      Emit_Lower (Buf, Len);
   end Emit_Sub_Name;

   -- Symbol table
   function Pool_Eq (Off : Integer; Len : Integer; Buf : Tok_Buffer; BLen : Integer) return Boolean is
   begin
      if Len /= BLen then
         return False;
      end if;
      for I in 1 .. Len loop
         if To_Lower (Name_Pool (Off + I - 1)) /= To_Lower (Buf (I)) then
            return False;
         end if;
      end loop;
      return True;
   end Pool_Eq;

   function Find_Sym (Buf : Tok_Buffer; BLen : Integer) return Integer is
   begin
      for I in reverse 1 .. Sym_Count loop
         if Pool_Eq (Sym_Name_Off (I), Sym_Name_Len (I), Buf, BLen) then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Sym;

   --  Grow the name pool to hold at least Need characters.
   procedure Ensure_Name_Pool_Cap (Need : Integer) is
      New_Cap : Integer;
      New_Buf : Char_Vec_Ptr;
   begin
      if Need <= Name_Pool_Cap then return; end if;
      New_Cap := Name_Pool_Cap * 2 + 65536;
      if New_Cap < Need then New_Cap := Need; end if;
      New_Buf := new Char_Vec (1 .. New_Cap);
      for I in 1 .. Name_Pool_Len loop
         New_Buf (I) := Name_Pool (I);
      end loop;
      Name_Pool := New_Buf;
      Name_Pool_Cap := New_Cap;
   end Ensure_Name_Pool_Cap;

   --  Grow all per-symbol arrays in lock-step to hold at least Need entries.
   procedure Ensure_Sym_Cap (Need : Integer) is
      New_Cap : Integer;
      A1 : Int_Vec_Ptr;
      A2 : Int_Vec_Ptr;
      A3 : Int_Vec_Ptr;
      A4 : Int_Vec_Ptr;
      A5 : Int_Vec_Ptr;
      A6 : Int_Vec_Ptr;
      A7 : Int_Vec_Ptr;
      A8 : Int_Vec_Ptr;
      A9 : Int_Vec_Ptr;
      A10 : Int_Vec_Ptr;
      A11 : Int_Vec_Ptr;
      A12 : Int_Vec_Ptr;
   begin
      if Need <= Sym_Cap then return; end if;
      New_Cap := Sym_Cap * 2;
      if New_Cap < 2048 then New_Cap := 2048; end if;
      if New_Cap < Need then New_Cap := Need; end if;
      A1 := new Int_Vec (1 .. New_Cap);
      A2 := new Int_Vec (1 .. New_Cap);
      A3 := new Int_Vec (1 .. New_Cap);
      A4 := new Int_Vec (1 .. New_Cap);
      A5 := new Int_Vec (1 .. New_Cap);
      A6 := new Int_Vec (1 .. New_Cap);
      A7 := new Int_Vec (1 .. New_Cap);
      A8 := new Int_Vec (1 .. New_Cap);
      A9 := new Int_Vec (1 .. New_Cap);
      A10 := new Int_Vec (1 .. New_Cap);
      A11 := new Int_Vec (1 .. New_Cap);
      A12 := new Int_Vec (1 .. New_Cap);
      for I in 1 .. Sym_Count loop
         A1 (I) := Sym_Name_Off (I);
         A2 (I) := Sym_Name_Len (I);
         A3 (I) := Sym_Kind (I);
         A4 (I) := Sym_Type (I);
         A5 (I) := Sym_Arr_Lo (I);
         A6 (I) := Sym_Arr_Hi (I);
         A7 (I) := Sym_Arr_El (I);
         A8 (I) := Sym_Arr_Inner_Lo (I);
         A9 (I) := Sym_Arr_Inner_Hi (I);
         A10 (I) := Sym_Has_Range (I);
         A11 (I) := Sym_Range_Lo (I);
         A12 (I) := Sym_Range_Hi (I);
      end loop;
      Sym_Name_Off := A1;
      Sym_Name_Len := A2;
      Sym_Kind := A3;
      Sym_Type := A4;
      Sym_Arr_Lo := A5;
      Sym_Arr_Hi := A6;
      Sym_Arr_El := A7;
      Sym_Arr_Inner_Lo := A8;
      Sym_Arr_Inner_Hi := A9;
      Sym_Has_Range := A10;
      Sym_Range_Lo := A11;
      Sym_Range_Hi := A12;
      Sym_Cap := New_Cap;
   end Ensure_Sym_Cap;

   procedure Add_Sym (Kind : Integer; Typ : Integer) is
   begin
      Ensure_Sym_Cap (Sym_Count + 1);
      Ensure_Name_Pool_Cap (Name_Pool_Len + Tok_Len);
      Sym_Count := Sym_Count + 1;
      Sym_Name_Off (Sym_Count) := Name_Pool_Len + 1;
      Sym_Name_Len (Sym_Count) := Tok_Len;
      for I in 1 .. Tok_Len loop
         Name_Pool_Len := Name_Pool_Len + 1;
         Name_Pool (Name_Pool_Len) := Tok_Val (I);
      end loop;
      Sym_Kind (Sym_Count) := Kind;
      Sym_Type (Sym_Count) := Typ;
      -- Ada Strings are 1-indexed by default.
      if Typ = TY_STRING then
         Sym_Arr_Lo (Sym_Count) := 1;
      else
         Sym_Arr_Lo (Sym_Count) := 0;
      end if;
      Sym_Arr_Hi (Sym_Count) := 0;
      Sym_Arr_El (Sym_Count) := 0;
      Sym_Arr_Inner_Lo (Sym_Count) := 0;
      Sym_Arr_Inner_Hi (Sym_Count) := 0;
      Sym_Has_Range (Sym_Count) := 0;
      Sym_Range_Lo (Sym_Count) := 0;
      Sym_Range_Hi (Sym_Count) := 0;
   end Add_Sym;

   procedure Add_Sym_Named (Buf : Tok_Buffer; BLen : Integer; Kind : Integer; Typ : Integer) is
   begin
      Ensure_Sym_Cap (Sym_Count + 1);
      Ensure_Name_Pool_Cap (Name_Pool_Len + BLen);
      Sym_Count := Sym_Count + 1;
      Sym_Name_Off (Sym_Count) := Name_Pool_Len + 1;
      Sym_Name_Len (Sym_Count) := BLen;
      for I in 1 .. BLen loop
         Name_Pool_Len := Name_Pool_Len + 1;
         Name_Pool (Name_Pool_Len) := Buf (I);
      end loop;
      Sym_Kind (Sym_Count) := Kind;
      Sym_Type (Sym_Count) := Typ;
      if Typ = TY_STRING then
         Sym_Arr_Lo (Sym_Count) := 1;
      else
         Sym_Arr_Lo (Sym_Count) := 0;
      end if;
      Sym_Arr_Hi (Sym_Count) := 0;
      Sym_Arr_El (Sym_Count) := 0;
      Sym_Arr_Inner_Lo (Sym_Count) := 0;
      Sym_Arr_Inner_Hi (Sym_Count) := 0;
      Sym_Has_Range (Sym_Count) := 0;
      Sym_Range_Lo (Sym_Count) := 0;
      Sym_Range_Hi (Sym_Count) := 0;
   end Add_Sym_Named;

   -- Register an exception by explicit name and id (no current token).
   -- Used to seed the predefined exceptions before parsing begins.
   procedure Seed_Exception (Name : String; Id : Integer) is
      Buf : Tok_Buffer;
   begin
      for I in 1 .. Name'Length loop
         Buf (I) := Name (Name'First + I - 1);
      end loop;
      Add_Sym_Named (Buf, Name'Length, SK_EXCEPTION, 0);
      Sym_Arr_Lo (Sym_Count) := Id;
   end Seed_Exception;

   -- The four predefined Ada exceptions, with fixed ids 1..4.
   procedure Seed_Predefined_Exceptions is
   begin
      Seed_Exception ("Constraint_Error", 1);
      Seed_Exception ("Program_Error", 2);
      Seed_Exception ("Storage_Error", 3);
      Seed_Exception ("Tasking_Error", 4);
   end Seed_Predefined_Exceptions;

   procedure Push_Scope is
   begin
      Scope_Depth := Scope_Depth + 1;
      Scope_Saved (Scope_Depth) := Sym_Count;
   end Push_Scope;

   procedure Pop_Scope is
   begin
      Sym_Count := Scope_Saved (Scope_Depth);
      Scope_Depth := Scope_Depth - 1;
   end Pop_Scope;

   -- ---- AST helpers ----

   procedure Reset_AST is
   begin
      --  Rewind lengths only; keep the grown capacity for reuse.
      N_Count := 1;
      NPool_Len := 0;
   end Reset_AST;

   --  Grow all node arrays in lock-step so index Need is valid. Existing
   --  nodes are 1 .. N_Count - 1 (index 0 is reserved, N_Count is the next
   --  free slot), so only those are copied.
   procedure Ensure_Node_Cap (Need : Integer) is
      New_Cap : Integer;
      A1 : Int_Vec_Ptr;
      A2 : Int_Vec_Ptr;
      A3 : Int_Vec_Ptr;
      A4 : Int_Vec_Ptr;
      A5 : Int_Vec_Ptr;
      A6 : Int_Vec_Ptr;
      A7 : Int_Vec_Ptr;
      A8 : Int_Vec_Ptr;
      A9 : Int_Vec_Ptr;
      A10 : Int_Vec_Ptr;
      A11 : Int_Vec_Ptr;
      A12 : Int_Vec_Ptr;
      A13 : Int_Vec_Ptr;
   begin
      if Need <= N_Cap then return; end if;
      New_Cap := N_Cap * 2;
      if New_Cap < 16384 then New_Cap := 16384; end if;
      if New_Cap < Need then New_Cap := Need; end if;
      A1  := new Int_Vec (1 .. New_Cap);
      A2  := new Int_Vec (1 .. New_Cap);
      A3  := new Int_Vec (1 .. New_Cap);
      A4  := new Int_Vec (1 .. New_Cap);
      A5  := new Int_Vec (1 .. New_Cap);
      A6  := new Int_Vec (1 .. New_Cap);
      A7  := new Int_Vec (1 .. New_Cap);
      A8  := new Int_Vec (1 .. New_Cap);
      A9  := new Int_Vec (1 .. New_Cap);
      A10 := new Int_Vec (1 .. New_Cap);
      A11 := new Int_Vec (1 .. New_Cap);
      A12 := new Int_Vec (1 .. New_Cap);
      A13 := new Int_Vec (1 .. New_Cap);
      for I in 1 .. N_Count - 1 loop
         A1 (I)  := N_Kind (I);
         A2 (I)  := N_Op (I);
         A3 (I)  := N_Int (I);
         A4 (I)  := N_Str_Off (I);
         A5 (I)  := N_Str_Len (I);
         A6 (I)  := N_Left (I);
         A7 (I)  := N_Right (I);
         A8 (I)  := N_Arg2 (I);
         A9 (I)  := N_First (I);
         A10 (I) := N_Next (I);
         A11 (I) := N_Aux1 (I);
         A12 (I) := N_Aux2 (I);
         A13 (I) := N_Line (I);
      end loop;
      N_Kind := A1;
      N_Op := A2;
      N_Int := A3;
      N_Str_Off := A4;
      N_Str_Len := A5;
      N_Left := A6;
      N_Right := A7;
      N_Arg2 := A8;
      N_First := A9;
      N_Next := A10;
      N_Aux1 := A11;
      N_Aux2 := A12;
      N_Line := A13;
      N_Cap := New_Cap;
   end Ensure_Node_Cap;

   function New_Node (Kind : Integer) return Integer is
      N : Integer;
   begin
      Ensure_Node_Cap (N_Count);
      N := N_Count;
      N_Count := N_Count + 1;
      N_Kind (N) := Kind;
      N_Op (N) := 0;
      N_Int (N) := 0;
      N_Str_Off (N) := 0;
      N_Str_Len (N) := 0;
      N_Left (N) := 0;
      N_Right (N) := 0;
      N_Arg2 (N) := 0;
      N_First (N) := 0;
      N_Next (N) := 0;
      N_Aux1 (N) := 0;
      N_Aux2 (N) := 0;
      N_Line (N) := Line_Num;
      return N;
   end New_Node;

   --  Grow the AST string pool to hold at least Need characters.
   procedure Ensure_NPool_Cap (Need : Integer) is
      New_Cap : Integer;
      New_Buf : Char_Vec_Ptr;
   begin
      if Need <= NPool_Cap then return; end if;
      New_Cap := NPool_Cap * 2 + 65536;
      if New_Cap < Need then New_Cap := Need; end if;
      New_Buf := new Char_Vec (1 .. New_Cap);
      for I in 1 .. NPool_Len loop
         New_Buf (I) := NPool (I);
      end loop;
      NPool := New_Buf;
      NPool_Cap := New_Cap;
   end Ensure_NPool_Cap;

   function Pool_Str (Buf : Tok_Buffer; Len : Integer) return Integer is
      Off : Integer;
   begin
      Ensure_NPool_Cap (NPool_Len + Len);
      Off := NPool_Len + 1;
      for I in 1 .. Len loop
         NPool_Len := NPool_Len + 1;
         NPool (NPool_Len) := Buf (I);
      end loop;
      return Off;
   end Pool_Str;

   -- Pool a symbol's name (which lives in Name_Pool) into the node
   -- string pool, so nodes can carry type names past symbol-table pops.
   function Pool_Name_Pool (Off : Integer; Len : Integer) return Integer is
      O : Integer;
   begin
      Ensure_NPool_Cap (NPool_Len + Len);
      O := NPool_Len + 1;
      for I in 1 .. Len loop
         NPool_Len := NPool_Len + 1;
         NPool (NPool_Len) := Name_Pool (Off + I - 1);
      end loop;
      return O;
   end Pool_Name_Pool;

   -- Set node N's call name: <pkg>_<name> when the callee is a package
   -- subprogram (tagged in Sym_Arr_Lo as index+1), else <name>. Resolved
   -- at build time so the walker stays symbol-table-independent.
   procedure Set_Call_Name (N : Integer; Name : Tok_Buffer; Len : Integer; Sidx : Integer) is
      Buf  : Tok_Buffer;
      BLen : Integer := 0;
      Pk   : Integer;
   begin
      if Sidx > 0 and then (Sym_Kind (Sidx) = SK_PROC or Sym_Kind (Sidx) = SK_FUNC)
         and then Sym_Arr_Lo (Sidx) /= 0
      then
         Pk := Sym_Arr_Lo (Sidx) - 1;
         for I in 1 .. Sym_Name_Len (Pk) loop
            BLen := BLen + 1;
            Buf (BLen) := Name_Pool (Sym_Name_Off (Pk) + I - 1);
         end loop;
         BLen := BLen + 1;
         Buf (BLen) := '_';
         for I in 1 .. Len loop
            BLen := BLen + 1;
            Buf (BLen) := Name (I);
         end loop;
         N_Str_Off (N) := Pool_Str (Buf, BLen);
         N_Str_Len (N) := BLen;
      else
         N_Str_Off (N) := Pool_Str (Name, Len);
         N_Str_Len (N) := Len;
      end if;
   end Set_Call_Name;

   function NPool_Eq_CI (Off : Integer; Len : Integer; S : String) return Boolean is
   begin
      if Len /= S'Length then
         return False;
      end if;
      for I in 1 .. Len loop
         if To_Lower (NPool (Off + I - 1)) /= To_Lower (S (S'First + I - 1)) then
            return False;
         end if;
      end loop;
      return True;
   end NPool_Eq_CI;

   procedure Emit_Pool_Lower (Off : Integer; Len : Integer) is
   begin
      for I in 1 .. Len loop
         Emit_Ch (To_Lower (NPool (Off + I - 1)));
      end loop;
   end Emit_Pool_Lower;

   -- Emit pooled text verbatim (original case) -- used for the exception
   -- name carried into the unhandled-exception message.
   procedure Emit_Pool_Raw (Off : Integer; Len : Integer) is
   begin
      for I in 1 .. Len loop
         Emit_Ch (NPool (Off + I - 1));
      end loop;
   end Emit_Pool_Raw;

   -- Forward declarations
   procedure Parse_Expression;
   procedure Parse_Statements;
   procedure Parse_Declarations;
   function  Parse_Expression_AST return Integer;
   function  Parse_Comparison_AST return Integer;
   function  Parse_Term_AST return Integer;
   function  Parse_Factor_AST return Integer;
   function  Parse_Primary_AST return Integer;
   function  Parse_Statement_AST return Integer;
   function  Parse_Statement_Chain return Integer;
   procedure Emit_Statement_Chain (Head : Integer);
   function  Parse_Handler_Arms return Integer;
   procedure Emit_Handled (Body_Head : Integer; Handlers : Integer);
   function  Parse_Declaration_AST return Integer;
   function  Parse_Var_Decl_Chain return Integer;
   procedure Emit_Declaration_Chain (Head : Integer);
   procedure Emit_Expression_AST (N : Integer);
   procedure Emit_Checked_Index (Idx : Integer; Lo : Integer; Hi : Integer);
   procedure Emit_Statement_AST (N : Integer);
   procedure Emit_Declaration_AST (N : Integer);

   -- Parse type reference
   function Parse_Type_Ref return Integer is
   begin
      if Tok = TK_INTEGER then
         Next_Token;
         return TY_INTEGER;
      elsif Tok = TK_NATURAL or Tok = TK_POSITIVE then
         Next_Token;
         return TY_INTEGER;
      elsif Tok = TK_CHARACTER then
         Next_Token;
         return TY_CHARACTER;
      elsif Tok = TK_BOOLEAN then
         Next_Token;
         return TY_BOOLEAN;
      elsif Tok = TK_STRING then
         Next_Token;
         return TY_STRING;
      elsif Tok = TK_IDENT then
         declare
            Idx : Integer;
         begin
            Idx := Find_Sym (Tok_Val, Tok_Len);
            Next_Token;
            if Idx > 0 and then Sym_Kind (Idx) = SK_TYPE then
               return Sym_Type (Idx);
            end if;
         end;
         return TY_INTEGER;
      else
         while Tok = TK_DOT loop
            Next_Token;
            if Tok = TK_IDENT or Tok = TK_INTEGER or Tok = TK_CHARACTER then
               Next_Token;
            end if;
         end loop;
         return TY_INTEGER;
      end if;
   end Parse_Type_Ref;

   procedure Emit_C_Type (Typ : Integer) is
   begin
      if Typ = TY_INTEGER then
         Emit ("int");
      elsif Typ = TY_CHARACTER then
         Emit ("char");
      elsif Typ = TY_BOOLEAN then
         Emit ("int");
      elsif Typ = TY_STRING then
         Emit ("const char *");
      elsif Typ = TY_ENUM then
         Emit ("int");   -- enums are plain ints
      else
         Emit ("int");
      end if;
   end Emit_C_Type;

   function Name_Eq (Buf : Tok_Buffer; BLen : Integer; S : String) return Boolean is
   begin
      if BLen /= S'Length then
         return False;
      end if;
      for I in 1 .. BLen loop
         if To_Lower (Buf (I)) /= To_Lower (S (S'First + I - 1)) then
            return False;
         end if;
      end loop;
      return True;
   end Name_Eq;

   -- ---- AST-building expression parsers ----
   -- Each returns the index of the AST node it constructs.

   function Parse_Primary_AST return Integer is
      N : Integer;
      Saved : Tok_Buffer;
      Saved_Len : Integer;
      Sym_Idx : Integer;
   begin
      if Tok = TK_INT_LIT then
         N := New_Node (A_INT_LIT);
         N_Int (N) := Tok_Int;
         Next_Token;
         return N;
      end if;
      if Tok = TK_CHAR_LIT then
         N := New_Node (A_CHAR_LIT);
         N_Int (N) := Character'Pos (Tok_Val (1));
         Next_Token;
         return N;
      end if;
      if Tok = TK_STR_LIT then
         N := New_Node (A_STR_LIT);
         N_Str_Off (N) := Pool_Str (Tok_Val, Tok_Len);
         N_Str_Len (N) := Tok_Len;
         Next_Token;
         return N;
      end if;
      if Tok = TK_TRUE then
         N := New_Node (A_BOOL_LIT);
         N_Int (N) := 1;
         Next_Token;
         return N;
      end if;
      if Tok = TK_FALSE then
         N := New_Node (A_BOOL_LIT);
         N_Int (N) := 0;
         Next_Token;
         return N;
      end if;
      if Tok = TK_NULL then
         -- null access value -> 0 (C pointers compare/assign against 0).
         N := New_Node (A_INT_LIT);
         N_Int (N) := 0;
         Next_Token;
         return N;
      end if;
      if Tok = TK_NOT then
         Next_Token;
         N := New_Node (A_UNARY);
         N_Op (N) := OP_NOT;
         N_Left (N) := Parse_Primary_AST;
         return N;
      end if;
      if Tok = TK_MINUS then
         Next_Token;
         N := New_Node (A_UNARY);
         N_Op (N) := OP_NEG;
         N_Left (N) := Parse_Primary_AST;
         return N;
      end if;
      if Tok = TK_NEW then
         -- Allocator. `new <ArrayType> (lo .. hi)` -> malloc of that many
         -- elements (element type in N_Op, bounds in N_Left / N_Right).
         -- `new <RecordType>` / `new <ScalarType>` (no bounds, N_Left = 0)
         -- -> calloc of one zeroed object; a record target pools its type
         -- name into N_Str for `sizeof(struct <name>)`.
         declare
            El      : Integer := TY_INTEGER;
            Rec_Idx : Integer := -1;
            Ti      : Integer;
         begin
            Next_Token;
            if Tok = TK_IDENT then
               Ti := Find_Sym (Tok_Val, Tok_Len);
               if Ti > 0 and then Sym_Kind (Ti) = SK_TYPE then
                  if Sym_Type (Ti) = TY_RECORD then
                     Rec_Idx := Ti;
                  else
                     El := Sym_Arr_El (Ti);
                  end if;
               end if;
               Next_Token;
            else
               El := Parse_Type_Ref;
            end if;
            N := New_Node (A_NEW);
            if Rec_Idx > 0 then
               N_Op (N) := TY_RECORD;
               N_Str_Off (N) := Pool_Name_Pool (Sym_Name_Off (Rec_Idx),
                                                Sym_Name_Len (Rec_Idx));
               N_Str_Len (N) := Sym_Name_Len (Rec_Idx);
            else
               N_Op (N) := El;
            end if;
            if Tok = TK_LPAREN then
               Next_Token;
               N_Left (N) := Parse_Expression_AST;
               Expect (TK_DOTDOT);
               N_Right (N) := Parse_Expression_AST;
               Expect (TK_RPAREN);
            end if;
            return N;
         end;
      end if;
      if Tok = TK_LPAREN then
         -- Parens contribute no node; the inner expression carries through.
         Next_Token;
         N := Parse_Expression_AST;
         Expect (TK_RPAREN);
         return N;
      end if;
      if Tok = TK_INTEGER or Tok = TK_NATURAL or Tok = TK_POSITIVE
         or Tok = TK_CHARACTER or Tok = TK_BOOLEAN
      then
         -- Type-name attribute: Integer'Image (X), Character'Pos/Val (X)
         Next_Token;
         if Tok /= TK_TICK then Error ("expected ' after type name"); end if;
         Next_Token;
         declare
            Attr : Tok_Buffer;
            Attr_Len : Integer;
         begin
            Attr_Len := Tok_Len;
            for I in 1 .. Tok_Len loop
               Attr (I) := Tok_Val (I);
            end loop;
            Next_Token;
            N := New_Node (A_ATTR_TYPE);
            if Name_Eq (Attr, Attr_Len, "Image") then
               N_Op (N) := ATTR_IMAGE;
            elsif Name_Eq (Attr, Attr_Len, "Pos") then
               N_Op (N) := ATTR_POS;
            elsif Name_Eq (Attr, Attr_Len, "Val") then
               N_Op (N) := ATTR_VAL;
            elsif Name_Eq (Attr, Attr_Len, "Succ") then
               N_Op (N) := ATTR_SUCC;
            elsif Name_Eq (Attr, Attr_Len, "Pred") then
               N_Op (N) := ATTR_PRED;
            else
               Error ("unsupported type-name attribute");
            end if;
            Expect (TK_LPAREN);
            N_Left (N) := Parse_Expression_AST;
            Expect (TK_RPAREN);
            return N;
         end;
      end if;
      if Tok = TK_IDENT then
         Saved_Len := Tok_Len;
         for I in 1 .. Tok_Len loop
            Saved (I) := Tok_Val (I);
         end loop;
         Sym_Idx := Find_Sym (Tok_Val, Tok_Len);
         Next_Token;

         if Tok = TK_TICK then
            -- Attribute: S'Length / S'First / S'Last on a variable, or an
            -- enum-type attribute T'First / T'Last / T'Pos (X) / T'Val (N)
            -- / T'Image (X).
            Next_Token;
            declare
               Attr : Tok_Buffer;
               Attr_Len : Integer;
               Is_Enum_Type : Boolean;
            begin
               Attr_Len := Tok_Len;
               for I in 1 .. Tok_Len loop
                  Attr (I) := Tok_Val (I);
               end loop;
               Next_Token;
               Is_Enum_Type := Sym_Idx > 0
                  and then Sym_Kind (Sym_Idx) = SK_TYPE
                  and then Sym_Type (Sym_Idx) = TY_ENUM;
               if Is_Enum_Type then
                  if Name_Eq (Attr, Attr_Len, "First") then
                     N := New_Node (A_INT_LIT);
                     N_Int (N) := Sym_Range_Lo (Sym_Idx);
                     return N;
                  elsif Name_Eq (Attr, Attr_Len, "Last") then
                     N := New_Node (A_INT_LIT);
                     N_Int (N) := Sym_Range_Hi (Sym_Idx);
                     return N;
                  elsif Name_Eq (Attr, Attr_Len, "Pos")
                     or else Name_Eq (Attr, Attr_Len, "Val")
                  then
                     -- Pos and Val are identities for an int-backed enum;
                     -- return the argument unchanged. A bad Val is caught
                     -- by the target's range check on assignment.
                     Expect (TK_LPAREN);
                     N := Parse_Expression_AST;
                     Expect (TK_RPAREN);
                     return N;
                  elsif Name_Eq (Attr, Attr_Len, "Image") then
                     N := New_Node (A_ATTR_TYPE);
                     N_Op (N) := ATTR_IMAGE;
                     N_Str_Off (N) := Pool_Str (Saved, Saved_Len);
                     N_Str_Len (N) := Saved_Len;
                     Expect (TK_LPAREN);
                     N_Left (N) := Parse_Expression_AST;
                     Expect (TK_RPAREN);
                     return N;
                  elsif Name_Eq (Attr, Attr_Len, "Succ")
                     or else Name_Eq (Attr, Attr_Len, "Pred")
                  then
                     -- Range-checked against the type's position range,
                     -- so T'Succ (T'Last) raises Constraint_Error.
                     N := New_Node (A_ATTR_TYPE);
                     if Name_Eq (Attr, Attr_Len, "Succ") then
                        N_Op (N) := ATTR_SUCC;
                     else
                        N_Op (N) := ATTR_PRED;
                     end if;
                     N_Aux1 (N) := 1;                  -- checked
                     N_Aux2 (N) := Sym_Range_Lo (Sym_Idx);
                     N_Int (N) := Sym_Range_Hi (Sym_Idx);
                     Expect (TK_LPAREN);
                     N_Left (N) := Parse_Expression_AST;
                     Expect (TK_RPAREN);
                     return N;
                  else
                     Error ("unsupported enum attribute");
                  end if;
               end if;
               N := New_Node (A_ATTR_VAR);
               N_Str_Off (N) := Pool_Str (Saved, Saved_Len);
               N_Str_Len (N) := Saved_Len;
               if Name_Eq (Attr, Attr_Len, "Length") then
                  N_Op (N) := ATTR_LENGTH;
               elsif Name_Eq (Attr, Attr_Len, "First") then
                  N_Op (N) := ATTR_FIRST;
               elsif Name_Eq (Attr, Attr_Len, "Last") then
                  N_Op (N) := ATTR_LAST;
               else
                  Error ("unsupported variable attribute");
               end if;
               return N;
            end;
         end if;

         if Tok = TK_LPAREN then
            if Sym_Idx > 0 and then (Sym_Kind (Sym_Idx) = SK_PROC or Sym_Kind (Sym_Idx) = SK_FUNC) then
               -- Function/procedure call: name (arg, arg, ...)
               Next_Token;
               N := New_Node (A_CALL);
               Set_Call_Name (N, Saved, Saved_Len, Sym_Idx);
               N_Int (N) := Sym_Idx;
               if Tok /= TK_RPAREN then
                  declare
                     First : Integer;
                     Prev : Integer;
                     Arg : Integer;
                  begin
                     First := Parse_Expression_AST;
                     N_First (N) := First;
                     Prev := First;
                     while Tok = TK_COMMA loop
                        Next_Token;
                        Arg := Parse_Expression_AST;
                        N_Next (Prev) := Arg;
                        Prev := Arg;
                     end loop;
                  end;
               end if;
               Expect (TK_RPAREN);
               return N;
            end if;
            -- Array indexing, possibly chained for 2D. Outer subtrahend
            -- (lower bound, or 1 when unresolved) resolved here into N_Op
            -- and inner into N_Aux1, so the walker is symbol-independent.
            Next_Token;
            N := New_Node (A_INDEX);
            N_Str_Off (N) := Pool_Str (Saved, Saved_Len);
            N_Str_Len (N) := Saved_Len;
            if Sym_Idx > 0 then
               N_Op (N) := Sym_Arr_Lo (Sym_Idx);
               --  Outer high bound (0 = no static bound -> no check).
               N_Aux2 (N) := Sym_Arr_Hi (Sym_Idx);
            else
               N_Op (N) := 1;
               N_Aux2 (N) := 0;
            end if;
            N_Right (N) := Parse_Expression_AST;
            Expect (TK_RPAREN);
            if Tok = TK_LPAREN and then Sym_Idx > 0
               and then Sym_Arr_Inner_Hi (Sym_Idx) /= 0
            then
               Next_Token;
               N_Kind (N) := A_INDEX2;
               N_Aux1 (N) := Sym_Arr_Inner_Lo (Sym_Idx);
               N_Int (N) := Sym_Arr_Inner_Hi (Sym_Idx);   -- inner high bound
               N_Arg2 (N) := Parse_Expression_AST;
               Expect (TK_RPAREN);
            end if;
            return N;
         end if;

         if Tok = TK_DOT and then Sym_Idx > 0
            and then (Sym_Kind (Sym_Idx) = SK_VAR or Sym_Kind (Sym_Idx) = SK_PARAM
                      or Sym_Kind (Sym_Idx) = SK_CONST)
            and then (Sym_Type (Sym_Idx) = TY_RECORD
                      or Sym_Type (Sym_Idx) = TY_ACCESS
                      or (Sym_Type (Sym_Idx) = TY_ARRAY
                          and then Sym_Arr_Hi (Sym_Idx) = 0
                          and then All_Follows_Dot))
         then
            -- Record field access (var.field -> var.field), implicit
            -- dereference through an access value (p.field -> p->field),
            -- or explicit dereference (p.all -> (*p)).
            Next_Token;   -- consume '.'
            if Tok = TK_IDENT and then Tok_Eq_CI ("all") then
               N := New_Node (A_ALL);
               N_Str_Off (N) := Pool_Str (Saved, Saved_Len);
               N_Str_Len (N) := Saved_Len;
               Next_Token;   -- consume 'all'
               return N;
            end if;
            N := New_Node (A_FIELD);
            N_Str_Off (N) := Pool_Str (Saved, Saved_Len);
            N_Str_Len (N) := Saved_Len;
            N_Arg2 (N) := Pool_Str (Tok_Val, Tok_Len);
            N_Int (N) := Tok_Len;
            if Sym_Type (Sym_Idx) = TY_ACCESS then
               N_Op (N) := 1;                        -- -> instead of .
            end if;
            Next_Token;   -- consume field name
            return N;
         end if;

         if Tok = TK_DOT then
            Next_Token;
            declare
               Sub : Tok_Buffer;
               Sub_Len : Integer;
            begin
               Sub_Len := Tok_Len;
               for I in 1 .. Tok_Len loop
                  Sub (I) := Tok_Val (I);
               end loop;
               Next_Token;
               while Tok = TK_DOT loop
                  Next_Token;
                  Sub_Len := Tok_Len;
                  for I in 1 .. Tok_Len loop
                     Sub (I) := Tok_Val (I);
                  end loop;
                  Next_Token;
               end loop;
               N := New_Node (A_DOTTED);
               N_Str_Off (N) := Pool_Str (Saved, Saved_Len);
               N_Str_Len (N) := Saved_Len;
               N_Arg2 (N) := Pool_Str (Sub, Sub_Len);
               N_Int (N) := Sub_Len;
               if Tok = TK_LPAREN then
                  Next_Token;
                  if Tok /= TK_RPAREN then
                     declare
                        First : Integer;
                        Prev : Integer;
                        Arg : Integer;
                     begin
                        First := Parse_Expression_AST;
                        N_First (N) := First;
                        Prev := First;
                        while Tok = TK_COMMA loop
                           Next_Token;
                           Arg := Parse_Expression_AST;
                           N_Next (Prev) := Arg;
                           Prev := Arg;
                        end loop;
                     end;
                  end if;
                  Expect (TK_RPAREN);
               end if;
               return N;
            end;
         end if;

         -- Simple variable, or parameterless function call. The trailing
         -- "()" need is resolved here into N_Op so walk is symbol-free.
         N := New_Node (A_IDENT);
         N_Str_Off (N) := Pool_Str (Saved, Saved_Len);
         N_Str_Len (N) := Saved_Len;
         if Sym_Idx > 0 and then Sym_Kind (Sym_Idx) = SK_FUNC then
            N_Op (N) := 1;
         else
            N_Op (N) := 0;
         end if;
         return N;
      end if;
      Error ("expected expression");
      return 0;
   end Parse_Primary_AST;

   function Parse_Factor_AST return Integer is
      LHS : Integer;
      RHS : Integer;
      N : Integer;
      Op : Integer;
   begin
      LHS := Parse_Primary_AST;
      while Tok = TK_STAR or Tok = TK_SLASH or Tok = TK_MOD loop
         if Tok = TK_STAR then
            Op := OP_MUL;
         elsif Tok = TK_SLASH then
            Op := OP_DIV;
         else
            Op := OP_MOD;
         end if;
         Next_Token;
         RHS := Parse_Primary_AST;
         N := New_Node (A_BINARY);
         N_Op (N) := Op;
         N_Left (N) := LHS;
         N_Right (N) := RHS;
         LHS := N;
      end loop;
      return LHS;
   end Parse_Factor_AST;

   function Parse_Term_AST return Integer is
      LHS : Integer;
      RHS : Integer;
      N : Integer;
      Op : Integer;
   begin
      LHS := Parse_Factor_AST;
      while Tok = TK_PLUS or Tok = TK_MINUS or Tok = TK_AMP loop
         if Tok = TK_PLUS then
            Op := OP_ADD;
         elsif Tok = TK_MINUS then
            Op := OP_SUB;
         else
            Op := OP_ADD;  -- `&` simplified to concatenation-as-add
         end if;
         Next_Token;
         RHS := Parse_Factor_AST;
         N := New_Node (A_BINARY);
         N_Op (N) := Op;
         N_Left (N) := LHS;
         N_Right (N) := RHS;
         LHS := N;
      end loop;
      return LHS;
   end Parse_Term_AST;

   function Parse_Comparison_AST return Integer is
      LHS : Integer;
      RHS : Integer;
      N : Integer;
      Op : Integer := 0;
   begin
      LHS := Parse_Term_AST;
      if Tok = TK_EQ then
         Op := OP_EQ;
      elsif Tok = TK_NEQ then
         Op := OP_NEQ;
      elsif Tok = TK_LT then
         Op := OP_LT;
      elsif Tok = TK_GT then
         Op := OP_GT;
      elsif Tok = TK_LE then
         Op := OP_LE;
      elsif Tok = TK_GE then
         Op := OP_GE;
      end if;
      if Op /= 0 then
         Next_Token;
         RHS := Parse_Term_AST;
         N := New_Node (A_BINARY);
         N_Op (N) := Op;
         N_Left (N) := LHS;
         N_Right (N) := RHS;
         return N;
      end if;
      return LHS;
   end Parse_Comparison_AST;

   function Parse_Expression_AST return Integer is
      LHS : Integer;
      RHS : Integer;
      N : Integer;
      Op : Integer;
   begin
      LHS := Parse_Comparison_AST;
      while Tok = TK_AND or Tok = TK_OR loop
         if Tok = TK_AND then
            Op := OP_AND;
            Next_Token;
            if Tok = TK_THEN then Next_Token; end if;
         else
            Op := OP_OR;
            Next_Token;
            if Tok = TK_ELSE then Next_Token; end if;
         end if;
         RHS := Parse_Comparison_AST;
         N := New_Node (A_BINARY);
         N_Op (N) := Op;
         N_Left (N) := LHS;
         N_Right (N) := RHS;
         LHS := N;
      end loop;
      return LHS;
   end Parse_Expression_AST;

   -- ---- AST walker ----
   -- Walks an expression tree and emits the equivalent C. Binary nodes
   -- get wrapped in `(...)` so source-explicit groupings survive and
   -- C-precedence ambiguities are impossible.

   -- Emit one array subscript as C: the Ada index expression,
   -- bounds-checked against [Lo, Hi] when Hi /= 0 (a statically-known
   -- upper bound), then the `- Lo` that converts to a 0-based C index.
   -- Hi = 0 means no static bound (access types, strings, unresolved
   -- names) -> no check.
   procedure Emit_Checked_Index (Idx : Integer; Lo : Integer; Hi : Integer) is
   begin
      if Hi /= 0 then
         Emit ("ada_range_check(");
         Emit_Expression_AST (Idx);
         Emit (", "); Emit_Int (Lo);
         Emit (", "); Emit_Int (Hi); Emit (")");
      else
         Emit_Expression_AST (Idx);
      end if;
      Emit (" - "); Emit_Int (Lo);
   end Emit_Checked_Index;

   procedure Emit_Expression_AST (N : Integer) is
      Kind : Integer;
      C : Character;
      Sub_Off : Integer;
      Sub_Len : Integer;
      A : Integer;
      First : Boolean;
   begin
      if N = 0 then return; end if;
      Kind := N_Kind (N);
      if Kind = A_INT_LIT then
         Emit_Int (N_Int (N));
      elsif Kind = A_CHAR_LIT then
         C := Character'Val (N_Int (N));
         Emit ("'");
         if C = ''' then
            Emit ("\'");
         elsif C = '\' then
            Emit ("\\");
         else
            Emit_Ch (C);
         end if;
         Emit ("'");
      elsif Kind = A_STR_LIT then
         Emit_Ch ('"');
         for I in 1 .. N_Str_Len (N) loop
            C := NPool (N_Str_Off (N) + I - 1);
            if C = '"' then
               Emit ("\""");
            elsif C = '\' then
               Emit ("\\");
            else
               Emit_Ch (C);
            end if;
         end loop;
         Emit_Ch ('"');
      elsif Kind = A_BOOL_LIT then
         if N_Int (N) = 1 then
            Emit ("1");
         else
            Emit ("0");
         end if;
      elsif Kind = A_IDENT then
         Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
         if N_Op (N) = 1 then   -- resolved paramless-function call
            Emit ("()");
         end if;
      elsif Kind = A_UNARY then
         if N_Op (N) = OP_NEG then
            Emit ("-");
         else
            Emit ("!");
         end if;
         Emit_Expression_AST (N_Left (N));
      elsif Kind = A_BINARY then
         Emit ("(");
         Emit_Expression_AST (N_Left (N));
         if N_Op (N) = OP_ADD then Emit (" + ");
         elsif N_Op (N) = OP_SUB then Emit (" - ");
         elsif N_Op (N) = OP_MUL then Emit (" * ");
         elsif N_Op (N) = OP_DIV then Emit (" / ");
         elsif N_Op (N) = OP_MOD then Emit (" % ");
         elsif N_Op (N) = OP_EQ then Emit (" == ");
         elsif N_Op (N) = OP_NEQ then Emit (" != ");
         elsif N_Op (N) = OP_LT then Emit (" < ");
         elsif N_Op (N) = OP_GT then Emit (" > ");
         elsif N_Op (N) = OP_LE then Emit (" <= ");
         elsif N_Op (N) = OP_GE then Emit (" >= ");
         elsif N_Op (N) = OP_AND then Emit (" && ");
         elsif N_Op (N) = OP_OR then Emit (" || ");
         end if;
         Emit_Expression_AST (N_Right (N));
         Emit (")");
      elsif Kind = A_INDEX then
         Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
         Emit ("[");
         Emit_Checked_Index (N_Right (N), N_Op (N), N_Aux2 (N));
         Emit ("]");
      elsif Kind = A_INDEX2 then
         Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
         Emit ("[");
         Emit_Checked_Index (N_Right (N), N_Op (N), N_Aux2 (N));
         Emit ("][");
         Emit_Checked_Index (N_Arg2 (N), N_Aux1 (N), N_Int (N));
         Emit ("]");
      elsif Kind = A_CALL then
         Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
         Emit ("(");
         A := N_First (N);
         First := True;
         while A /= 0 loop
            if not First then Emit (", "); end if;
            First := False;
            Emit_Expression_AST (A);
            A := N_Next (A);
         end loop;
         Emit (")");
      elsif Kind = A_ATTR_TYPE then
         if N_Op (N) = ATTR_IMAGE then
            if N_Str_Len (N) /= 0 then         -- enum: <type>_image(v)
               Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
               Emit ("_image(");
               Emit_Expression_AST (N_Left (N));
               Emit (")");
            else                               -- Integer'Image
               Emit ("int_to_str(");
               Emit_Expression_AST (N_Left (N));
               Emit (")");
            end if;
         elsif N_Op (N) = ATTR_POS then
            Emit ("((int)(");
            Emit_Expression_AST (N_Left (N));
            Emit ("))");
         elsif N_Op (N) = ATTR_VAL then
            Emit ("((char)(");
            Emit_Expression_AST (N_Left (N));
            Emit ("))");
         elsif N_Op (N) = ATTR_SUCC or N_Op (N) = ATTR_PRED then
            -- N_Aux1 = 1: enum, checked against [N_Aux2, N_Int]
            if N_Aux1 (N) = 1 then
               Emit ("ada_range_check((");
               Emit_Expression_AST (N_Left (N));
               if N_Op (N) = ATTR_SUCC then
                  Emit (") + 1, ");
               else
                  Emit (") - 1, ");
               end if;
               Emit_Int (N_Aux2 (N));
               Emit (", ");
               Emit_Int (N_Int (N));
               Emit (")");
            else
               Emit ("((");
               Emit_Expression_AST (N_Left (N));
               if N_Op (N) = ATTR_SUCC then
                  Emit (") + 1)");
               else
                  Emit (") - 1)");
               end if;
            end if;
         end if;
      elsif Kind = A_ATTR_VAR then
         if N_Op (N) = ATTR_LENGTH or N_Op (N) = ATTR_LAST then
            Emit ("(int)strlen(");
            Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
            Emit (")");
         elsif N_Op (N) = ATTR_FIRST then
            Emit ("1");
         end if;
      elsif Kind = A_NEW then
         if N_Left (N) /= 0 then
            -- new T (lo..hi) -> malloc(((hi) - (lo) + 1) * sizeof(T))
            Emit ("malloc((");
            Emit_Expression_AST (N_Right (N));
            Emit (" - ");
            Emit_Expression_AST (N_Left (N));
            Emit (" + 1) * sizeof(");
            Emit_C_Type (N_Op (N));
            Emit ("))");
         else
            -- new T -> calloc(1, sizeof(T)): one zeroed object, matching
            -- the compiler's zero-default init convention.
            Emit ("calloc(1, sizeof(");
            if N_Op (N) = TY_RECORD then
               Emit ("struct ");
               Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
            else
               Emit_C_Type (N_Op (N));
            end if;
            Emit ("))");
         end if;
      elsif Kind = A_FIELD then
         -- record field access: base.field, or base->field via access
         Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
         if N_Op (N) = 1 then
            Emit ("->");
         else
            Emit (".");
         end if;
         Emit_Pool_Lower (N_Arg2 (N), N_Int (N));
      elsif Kind = A_ALL then
         -- pointer dereference: P.all -> (*p)
         Emit ("(*");
         Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
         Emit (")");
      elsif Kind = A_DOTTED then
         Sub_Off := N_Arg2 (N);
         Sub_Len := N_Int (N);
         if NPool_Eq_CI (Sub_Off, Sub_Len, "Exception_Message") then
            Emit ("ada_cur_exc_msg");     -- occurrence arg is cosmetic
         elsif NPool_Eq_CI (Sub_Off, Sub_Len, "Exception_Name") then
            Emit ("ada_cur_exc_name");
         elsif NPool_Eq_CI (Sub_Off, Sub_Len, "Argument_Count") then
            Emit ("(argc - 1)");
         elsif NPool_Eq_CI (Sub_Off, Sub_Len, "Argument") then
            Emit ("argv[");
            Emit_Expression_AST (N_First (N));
            Emit ("]");
         elsif NPool_Eq_CI (Sub_Off, Sub_Len, "End_Of_File") then
            Emit ("feof(");
            Emit_Expression_AST (N_First (N));
            Emit (")");
         elsif NPool_Eq_CI (Sub_Off, Sub_Len, "Get_Line") then
            Emit ("ada_get_line(");
            Emit_Expression_AST (N_First (N));
            Emit (")");
         else
            Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
            Emit ("_");
            Emit_Pool_Lower (Sub_Off, Sub_Len);
            if N_First (N) /= 0 then
               Emit ("(");
               A := N_First (N);
               First := True;
               while A /= 0 loop
                  if not First then Emit (", "); end if;
                  First := False;
                  Emit_Expression_AST (A);
                  A := N_Next (A);
               end loop;
               Emit (")");
            end if;
         end if;
      end if;
   end Emit_Expression_AST;

   -- Public wrapper: build AST, walk it, discard the nodes.
   -- All external callers in Parse_Statement / Parse_Declarations still
   -- call Parse_Expression — only the internal recursive structure has
   -- changed.
   procedure Parse_Expression is
      N : Integer;
   begin
      N := Parse_Expression_AST;
      Emit_Expression_AST (N);
      Reset_AST;
   end Parse_Expression;

   -- ---- Statement-AST walker (leaf and compound) ----
   procedure Emit_Statement_AST (N : Integer) is
      Kind : Integer;
      A : Integer;
      E : Integer;
      Sub : Integer;
      First : Boolean;
   begin
      if N = 0 then return; end if;
      Kind := N_Kind (N);
      if Kind = S_NULL then
         Emit_Indent; Emit_Ln ("/* null */;");
      elsif Kind = S_RETURN then
         Emit_Indent; Emit ("return");
         if N_Left (N) /= 0 then
            Emit (" ");
            Emit_Expression_AST (N_Left (N));
         elsif N_Op (N) = 1 then
            Emit (" 0");
         end if;
         Emit_Ln (";");
      elsif Kind = S_RAISE then
         Emit_Indent;
         if N_Op (N) = 1 then
            -- bare re-raise preserves the occurrence, message included
            Emit_Ln ("ada_raise_msg(ada_cur_exc, ada_cur_exc_name, ada_cur_exc_msg);");
         elsif N_Arg2 (N) /= 0 then
            Emit ("ada_raise_msg(");
            Emit_Int (N_Aux1 (N));
            Emit (", """);
            Emit_Pool_Raw (N_Str_Off (N), N_Str_Len (N));
            Emit (""", ");
            Emit_Expression_AST (N_Arg2 (N));
            Emit_Ln (");");
         else
            Emit ("ada_raise(");
            Emit_Int (N_Aux1 (N));
            Emit (", """);
            Emit_Pool_Raw (N_Str_Off (N), N_Str_Len (N));
            Emit_Ln (""");");
         end if;
      elsif Kind = S_EXIT then
         if N_Left (N) /= 0 then
            Emit_Indent; Emit ("if (");
            Emit_Expression_AST (N_Left (N));
            Emit_Ln (") break;");
         else
            Emit_Indent; Emit_Ln ("break;");
         end if;
      elsif Kind = S_ASSIGN then
         Emit_Indent;
         Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
         Emit (" = ");
         if N_Op (N) = 1 then            -- range-constrained target
            Emit ("ada_range_check(");
            Emit_Expression_AST (N_Right (N));
            Emit (", "); Emit_Int (N_Aux1 (N));
            Emit (", "); Emit_Int (N_Aux2 (N)); Emit (")");
         else
            Emit_Expression_AST (N_Right (N));
         end if;
         Emit_Ln (";");
      elsif Kind = S_CALL then
         Emit_Indent;
         Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
         Emit ("(");
         A := N_First (N);
         First := True;
         while A /= 0 loop
            if not First then Emit (", "); end if;
            First := False;
            Emit_Expression_AST (A);
            A := N_Next (A);
         end loop;
         Emit_Ln (");");
      elsif Kind = S_PARAMLESS then
         Emit_Indent;
         Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
         Emit_Ln ("();");
      elsif Kind = S_ARRAY_ASSIGN then
         Emit_Indent;
         Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
         Emit ("[");
         Emit_Checked_Index (N_Right (N), N_Op (N), N_Aux2 (N));
         Emit ("]");
         if N_Arg2 (N) /= 0 then
            Emit ("[");
            Emit_Checked_Index (N_Arg2 (N), N_Aux1 (N), N_Int (N));
            Emit ("]");
         end if;
         Emit (" = ");
         Emit_Expression_AST (N_First (N));
         Emit_Ln (";");
      elsif Kind = S_FIELD_ASSIGN then
         -- field assignment: base.field = rhs; or base->field = rhs;
         Emit_Indent;
         Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
         if N_Op (N) = 1 then
            Emit ("->");
         else
            Emit (".");
         end if;
         Emit_Pool_Lower (N_Arg2 (N), N_Int (N));
         Emit (" = ");
         Emit_Expression_AST (N_Right (N));
         Emit_Ln (";");
      elsif Kind = S_ALL_ASSIGN then
         -- dereference assignment: *base = rhs;
         Emit_Indent;
         Emit ("*");
         Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
         Emit (" = ");
         Emit_Expression_AST (N_Right (N));
         Emit_Ln (";");
      elsif Kind = S_FREE then
         -- instantiated Unchecked_Deallocation: free + null out, matching
         -- Ada's post-condition that the access value becomes null.
         Emit_Indent;
         Emit ("free(");
         Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
         Emit ("); ");
         Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
         Emit_Ln (" = NULL;");
      elsif Kind = S_IF then
         Emit_Indent; Emit ("if (");
         Emit_Expression_AST (N_Left (N));
         Emit_Ln (") {");
         Indent_Level := Indent_Level + 1;
         Emit_Statement_Chain (N_First (N));
         Indent_Level := Indent_Level - 1;
         E := N_Right (N);
         while E /= 0 loop
            Emit_Indent; Emit ("} else if (");
            Emit_Expression_AST (N_Left (E));
            Emit_Ln (") {");
            Indent_Level := Indent_Level + 1;
            Emit_Statement_Chain (N_First (E));
            Indent_Level := Indent_Level - 1;
            E := N_Next (E);
         end loop;
         if N_Arg2 (N) /= 0 then
            Emit_Indent; Emit_Ln ("} else {");
            Indent_Level := Indent_Level + 1;
            Emit_Statement_Chain (N_Arg2 (N));
            Indent_Level := Indent_Level - 1;
         end if;
         Emit_Indent; Emit_Ln ("}");
      elsif Kind = S_CASE then
         Emit_Indent; Emit ("switch (");
         Emit_Expression_AST (N_Left (N));
         Emit_Ln (") {");
         Indent_Level := Indent_Level + 1;
         declare
            Arm : Integer;
            C   : Integer;
         begin
            Arm := N_First (N);
            while Arm /= 0 loop
               if N_Op (Arm) = 1 then
                  Emit_Indent; Emit_Ln ("default: {");
               else
                  C := N_First (Arm);
                  while C /= 0 loop
                     Emit_Indent; Emit ("case ");
                     if N_Kind (C) = A_RANGE then
                        -- GNU C case range (gcc and clang both accept it)
                        Emit_Expression_AST (N_Left (C));
                        Emit (" ... ");
                        Emit_Expression_AST (N_Right (C));
                     else
                        Emit_Expression_AST (C);
                     end if;
                     if N_Next (C) = 0 then
                        Emit_Ln (": {");
                     else
                        Emit_Ln (":");
                     end if;
                     C := N_Next (C);
                  end loop;
               end if;
               Indent_Level := Indent_Level + 1;
               Emit_Statement_Chain (N_Arg2 (Arm));
               Emit_Indent; Emit_Ln ("break;");
               Indent_Level := Indent_Level - 1;
               Emit_Indent; Emit_Ln ("}");
               Arm := N_Next (Arm);
            end loop;
         end;
         Indent_Level := Indent_Level - 1;
         Emit_Indent; Emit_Ln ("}");
      elsif Kind = S_WHILE then
         Emit_Indent; Emit ("while (");
         Emit_Expression_AST (N_Left (N));
         Emit_Ln (") {");
         Indent_Level := Indent_Level + 1;
         Emit_Statement_Chain (N_First (N));
         Indent_Level := Indent_Level - 1;
         Emit_Indent; Emit_Ln ("}");
      elsif Kind = S_LOOP then
         Emit_Indent; Emit_Ln ("while (1) {");
         Indent_Level := Indent_Level + 1;
         Emit_Statement_Chain (N_First (N));
         Indent_Level := Indent_Level - 1;
         Emit_Indent; Emit_Ln ("}");
      elsif Kind = S_FOR then
         Emit_Indent;
         if N_Op (N) = 1 then
            Emit ("{ int __lo = ");
            Emit_Expression_AST (N_Left (N));
            Emit ("; int __hi = ");
            Emit_Expression_AST (N_Right (N));
            Emit ("; for (int ");
            Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
            Emit (" = __hi; ");
            Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
            Emit (" >= __lo; ");
            Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
            Emit_Ln ("--) {");
         else
            Emit ("for (int ");
            Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
            Emit (" = ");
            Emit_Expression_AST (N_Left (N));
            Emit ("; ");
            Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
            Emit (" <= ");
            Emit_Expression_AST (N_Right (N));
            Emit ("; ");
            Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
            Emit_Ln ("++) {");
         end if;
         Indent_Level := Indent_Level + 1;
         Emit_Statement_Chain (N_First (N));
         Indent_Level := Indent_Level - 1;
         Emit_Indent;
         if N_Op (N) = 1 then
            Emit_Ln ("} }");
         else
            Emit_Ln ("}");
         end if;
      elsif Kind = S_DECLARE then
         Emit_Indent; Emit_Ln ("{");
         Indent_Level := Indent_Level + 1;
         Emit_Declaration_Chain (N_First (N));
         if N_Right (N) /= 0 then
            Emit_Handled (N_Arg2 (N), N_Right (N));
         else
            Emit_Statement_Chain (N_Arg2 (N));
         end if;
         Indent_Level := Indent_Level - 1;
         Emit_Indent; Emit_Ln ("}");
      elsif Kind = S_BLOCK then
         Emit_Indent; Emit_Ln ("{");
         Indent_Level := Indent_Level + 1;
         if N_Arg2 (N) /= 0 then
            Emit_Handled (N_First (N), N_Arg2 (N));
         else
            Emit_Statement_Chain (N_First (N));
         end if;
         Indent_Level := Indent_Level - 1;
         Emit_Indent; Emit_Ln ("}");
      elsif Kind = S_PKG then
         Sub := N_Op (N);
         Emit_Indent;
         if Sub = PKG_PUT_LINE then
            if N_Right (N) /= 0 then
               Emit ("ada_fput_line(");
               Emit_Expression_AST (N_Left (N));
               Emit (", ");
               Emit_Expression_AST (N_Right (N));
            else
               Emit ("ada_put_line(");
               Emit_Expression_AST (N_Left (N));
            end if;
            Emit_Ln (");");
         elsif Sub = PKG_PUT then
            if N_Right (N) /= 0 then
               if N_Aux1 (N) = 1 then
                  Emit ("ada_fput_char(");
               else
                  Emit ("ada_fput_str(");
               end if;
               Emit_Expression_AST (N_Left (N));
               Emit (", ");
               Emit_Expression_AST (N_Right (N));
            else
               if N_Aux1 (N) = 1 then
                  Emit ("ada_put_char(");
               else
                  Emit ("ada_put_str(");
               end if;
               Emit_Expression_AST (N_Left (N));
            end if;
            Emit_Ln (");");
         elsif Sub = PKG_NEW_LINE then
            if N_Left (N) /= 0 then
               Emit ("ada_fput_newline(");
               Emit_Expression_AST (N_Left (N));
               Emit_Ln (");");
            else
               Emit_Ln ("ada_new_line();");
            end if;
         elsif Sub = PKG_OPEN then
            Emit_Expression_AST (N_Left (N));
            Emit (" = fopen(");
            Emit_Expression_AST (N_Right (N));
            if N_Int (N) = 1 then
               Emit (", ""w""");
            else
               Emit (", ""r""");
            end if;
            Emit_Ln (");");
         elsif Sub = PKG_CREATE then
            Emit_Expression_AST (N_Left (N));
            Emit (" = fopen(");
            Emit_Expression_AST (N_Right (N));
            Emit (", ""w""");
            Emit_Ln (");");
         elsif Sub = PKG_CLOSE then
            Emit ("fclose(");
            Emit_Expression_AST (N_Left (N));
            Emit_Ln (");");
         elsif Sub = PKG_GET_LINE then
            Emit ("ada_get_line(");
            Emit_Expression_AST (N_Left (N));
            Emit_Ln (");");
         elsif Sub = PKG_GET then
            Emit ("{int __gc = fgetc(");
            Emit_Expression_AST (N_Left (N));
            Emit ("); if (__gc != EOF) ");
            Emit_Expression_AST (N_Right (N));
            Emit_Ln (" = (char)__gc;}");
         elsif Sub = PKG_GENERIC then
            Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
            Emit ("_");
            Emit_Pool_Lower (N_Arg2 (N), N_Int (N));
            if N_Aux1 (N) = 1 then
               Emit ("(");
               A := N_First (N);
               First := True;
               while A /= 0 loop
                  if not First then Emit (", "); end if;
                  First := False;
                  Emit_Expression_AST (A);
                  A := N_Next (A);
               end loop;
               Emit_Ln (");");
            else
               Emit_Ln ("();");
            end if;
         end if;
      end if;
   end Emit_Statement_AST;

   -- Build an S_PKG statement node for a Text_IO-style builtin call. The
   -- caller has consumed the subprogram name; Sub is that name and Saved
   -- the original prefix (equal to Sub for a bare call made visible by
   -- `use Ada.Text_IO`). Positioned at '(' or ';'; leaves the trailing
   -- ';' for the caller. Unknown names become PKG_GENERIC (a dotted
   -- user-package call, mangled <pkg>_<sub>).
   function Build_Pkg_Stmt (Saved : Tok_Buffer; Saved_Len : Integer;
                            Sub : Tok_Buffer; Sub_Len : Integer)
      return Integer
   is
      N : Integer;
   begin
      N := New_Node (S_PKG);
      if Name_Eq (Sub, Sub_Len, "Put_Line") then
         N_Op (N) := PKG_PUT_LINE;
         Expect (TK_LPAREN);
         if Has_Arg_Separator_Ahead then
            N_Left (N) := Parse_Expression_AST;
            Expect (TK_COMMA);
            N_Right (N) := Parse_Expression_AST;
         else
            N_Left (N) := Parse_Expression_AST;
         end if;
         Expect (TK_RPAREN);
      elsif Name_Eq (Sub, Sub_Len, "Put") then
         N_Op (N) := PKG_PUT;
         Expect (TK_LPAREN);
         if Has_Arg_Separator_Ahead then
            if Second_Arg_Is_Char then
               N_Aux1 (N) := 1;
            else
               N_Aux1 (N) := 0;
            end if;
            N_Left (N) := Parse_Expression_AST;
            Expect (TK_COMMA);
            N_Right (N) := Parse_Expression_AST;
         else
            if First_Arg_Is_Char then
               N_Aux1 (N) := 1;
            else
               N_Aux1 (N) := 0;
            end if;
            N_Left (N) := Parse_Expression_AST;
         end if;
         Expect (TK_RPAREN);
      elsif Name_Eq (Sub, Sub_Len, "New_Line") then
         N_Op (N) := PKG_NEW_LINE;
         if Tok = TK_LPAREN then
            Expect (TK_LPAREN);
            if Tok /= TK_RPAREN then
               N_Left (N) := Parse_Expression_AST;
            end if;
            Expect (TK_RPAREN);
         end if;
      elsif Name_Eq (Sub, Sub_Len, "Open") then
         N_Op (N) := PKG_OPEN;
         Expect (TK_LPAREN);
         N_Left (N) := Parse_Expression_AST;   -- file var
         Expect (TK_COMMA);
         while Tok /= TK_COMMA and Tok /= TK_RPAREN and Tok /= TK_EOF loop
            if Tok_Eq_CI ("Out_File") then N_Int (N) := 1; end if;
            Next_Token;
            if Tok = TK_DOT then Next_Token; Next_Token; end if;
         end loop;
         if Tok = TK_COMMA then Next_Token; end if;
         N_Right (N) := Parse_Expression_AST;   -- name
         Expect (TK_RPAREN);
      elsif Name_Eq (Sub, Sub_Len, "Create") then
         N_Op (N) := PKG_CREATE;
         Expect (TK_LPAREN);
         N_Left (N) := Parse_Expression_AST;
         Expect (TK_COMMA);
         while Tok /= TK_COMMA and Tok /= TK_RPAREN and Tok /= TK_EOF loop
            Next_Token;
            if Tok = TK_DOT then Next_Token; Next_Token; end if;
         end loop;
         if Tok = TK_COMMA then Next_Token; end if;
         N_Right (N) := Parse_Expression_AST;
         Expect (TK_RPAREN);
      elsif Name_Eq (Sub, Sub_Len, "Close") then
         N_Op (N) := PKG_CLOSE;
         Expect (TK_LPAREN);
         N_Left (N) := Parse_Expression_AST;
         Expect (TK_RPAREN);
      elsif Name_Eq (Sub, Sub_Len, "Get_Line") then
         N_Op (N) := PKG_GET_LINE;
         Expect (TK_LPAREN);
         N_Left (N) := Parse_Expression_AST;
         Expect (TK_RPAREN);
      elsif Name_Eq (Sub, Sub_Len, "Get") then
         N_Op (N) := PKG_GET;
         Expect (TK_LPAREN);
         N_Left (N) := Parse_Expression_AST;   -- file
         Expect (TK_COMMA);
         N_Right (N) := Parse_Expression_AST;   -- char var
         Expect (TK_RPAREN);
      else
         N_Op (N) := PKG_GENERIC;
         N_Str_Off (N) := Pool_Str (Saved, Saved_Len);
         N_Str_Len (N) := Saved_Len;
         N_Arg2 (N) := Pool_Str (Sub, Sub_Len);
         N_Int (N) := Sub_Len;
         if Tok = TK_LPAREN then
            N_Aux1 (N) := 1;
            Next_Token;
            if Tok /= TK_RPAREN then
               declare
                  First : Integer;
                  Prev : Integer;
                  Arg : Integer;
               begin
                  First := Parse_Expression_AST;
                  N_First (N) := First;
                  Prev := First;
                  while Tok = TK_COMMA loop
                     Next_Token;
                     Arg := Parse_Expression_AST;
                     N_Next (Prev) := Arg;
                     Prev := Arg;
                  end loop;
               end;
            end if;
            Expect (TK_RPAREN);
         end if;
      end if;
      return N;
   end Build_Pkg_Stmt;

   -- The statement-level Text_IO builtins that `use Ada.Text_IO;` makes
   -- visible without a prefix.
   function Is_Textio_Sub (S : Tok_Buffer; Len : Integer) return Boolean is
   begin
      return Name_Eq (S, Len, "Put_Line")
         or else Name_Eq (S, Len, "Put")
         or else Name_Eq (S, Len, "New_Line")
         or else Name_Eq (S, Len, "Get_Line")
         or else Name_Eq (S, Len, "Get")
         or else Name_Eq (S, Len, "Open")
         or else Name_Eq (S, Len, "Close")
         or else Name_Eq (S, Len, "Create");
   end Is_Textio_Sub;

   -- One case-arm choice: an expression, or a range choice `lo .. hi`
   -- (an A_RANGE node, emitted as a GNU C case range `case lo ... hi:`).
   function Parse_Case_Choice return Integer is
      C : Integer;
      R : Integer;
   begin
      C := Parse_Expression_AST;
      if Tok = TK_DOTDOT then
         Next_Token;
         R := New_Node (A_RANGE);
         N_Left (R) := C;
         N_Right (R) := Parse_Expression_AST;
         return R;
      end if;
      return C;
   end Parse_Case_Choice;

   function Parse_Statement_AST return Integer is
      N : Integer;
      Saved : Tok_Buffer;
      Saved_Len : Integer;
      Sym_Idx : Integer;
      Sub : Tok_Buffer;
      Sub_Len : Integer;
   begin
      if Tok = TK_NULL then
         N := New_Node (S_NULL);
         Next_Token; Expect (TK_SEMI);
         return N;
      end if;
      if Tok = TK_RETURN then
         N := New_Node (S_RETURN);
         Next_Token;
         if Tok /= TK_SEMI then
            N_Left (N) := Parse_Expression_AST;
         elsif In_Main_Proc = 1 then
            N_Op (N) := 1;
         end if;
         Expect (TK_SEMI);
         return N;
      end if;
      if Tok = TK_RAISE then
         N := New_Node (S_RAISE);
         N_Int (N) := Line_Num;
         Next_Token;
         if Tok = TK_SEMI then
            N_Op (N) := 1;                 -- bare `raise;` -> re-raise
         else
            -- raise Name [with "msg"];  resolve Name to its exception id;
            -- unknown names default to Program_Error (id 2).
            declare
               Idx : Integer := Find_Sym (Tok_Val, Tok_Len);
            begin
               if Idx > 0 and then Sym_Kind (Idx) = SK_EXCEPTION then
                  N_Aux1 (N) := Sym_Arr_Lo (Idx);
               else
                  N_Aux1 (N) := 2;
               end if;
            end;
            N_Str_Off (N) := Pool_Str (Tok_Val, Tok_Len);
            N_Str_Len (N) := Tok_Len;
            Next_Token;
            if Tok = TK_WITH then
               -- optional message expression -> N_Arg2 (0 = none)
               Next_Token;
               N_Arg2 (N) := Parse_Expression_AST;
            end if;
            while Tok /= TK_SEMI and Tok /= TK_EOF loop
               Next_Token;
            end loop;
         end if;
         Expect (TK_SEMI);
         return N;
      end if;
      if Tok = TK_EXIT then
         N := New_Node (S_EXIT);
         Next_Token;
         if Tok = TK_WHEN then
            Next_Token;
            N_Left (N) := Parse_Expression_AST;
         end if;
         Expect (TK_SEMI);
         return N;
      end if;

      -- Compound statements: build a subtree; children are sub-chains.
      if Tok = TK_IF then
         N := New_Node (S_IF);
         Next_Token;
         N_Left (N) := Parse_Expression_AST;
         Expect (TK_THEN);
         N_First (N) := Parse_Statement_Chain;
         declare
            Prev_Elsif : Integer := 0;
            E : Integer;
         begin
            while Tok = TK_ELSIF loop
               Next_Token;
               E := New_Node (S_ELSIF);
               N_Left (E) := Parse_Expression_AST;
               Expect (TK_THEN);
               N_First (E) := Parse_Statement_Chain;
               if Prev_Elsif = 0 then
                  N_Right (N) := E;
               else
                  N_Next (Prev_Elsif) := E;
               end if;
               Prev_Elsif := E;
            end loop;
         end;
         if Tok = TK_ELSE then
            Next_Token;
            N_Arg2 (N) := Parse_Statement_Chain;
         end if;
         Expect (TK_END); Expect (TK_IF); Expect (TK_SEMI);
         return N;
      end if;
      if Tok = TK_CASE then
         -- case Sel is when C|C => stmts ... when others => stmts end case;
         N := New_Node (S_CASE);
         Next_Token;
         N_Left (N) := Parse_Expression_AST;   -- selector
         Expect (TK_IS);
         declare
            Prev_Arm : Integer := 0;
            Arm : Integer;
         begin
            while Tok = TK_WHEN loop
               Next_Token;
               Arm := New_Node (S_WHEN);
               if Tok = TK_IDENT and then Tok_Eq_CI ("others") then
                  N_Op (Arm) := 1;             -- default:
                  Next_Token;
               else
                  declare
                     First_C : Integer;
                     Prev_C  : Integer;
                     C       : Integer;
                  begin
                     First_C := Parse_Case_Choice;
                     N_First (Arm) := First_C;
                     Prev_C := First_C;
                     while Tok = TK_BAR loop
                        Next_Token;
                        C := Parse_Case_Choice;
                        N_Next (Prev_C) := C;
                        Prev_C := C;
                     end loop;
                  end;
               end if;
               Expect (TK_ARROW);
               N_Arg2 (Arm) := Parse_Statement_Chain;   -- stops at when/end
               if Prev_Arm = 0 then
                  N_First (N) := Arm;
               else
                  N_Next (Prev_Arm) := Arm;
               end if;
               Prev_Arm := Arm;
            end loop;
         end;
         Expect (TK_END); Expect (TK_CASE); Expect (TK_SEMI);
         return N;
      end if;
      if Tok = TK_WHILE then
         N := New_Node (S_WHILE);
         Next_Token;
         N_Left (N) := Parse_Expression_AST;
         Expect (TK_LOOP);
         N_First (N) := Parse_Statement_Chain;
         Expect (TK_END); Expect (TK_LOOP); Expect (TK_SEMI);
         return N;
      end if;
      if Tok = TK_LOOP then
         N := New_Node (S_LOOP);
         Next_Token;
         N_First (N) := Parse_Statement_Chain;
         Expect (TK_END); Expect (TK_LOOP); Expect (TK_SEMI);
         return N;
      end if;
      if Tok = TK_FOR then
         N := New_Node (S_FOR);
         Next_Token;
         N_Str_Off (N) := Pool_Str (Tok_Val, Tok_Len);
         N_Str_Len (N) := Tok_Len;
         Next_Token;
         Expect (TK_IN);
         if Tok = TK_REVERSE then
            N_Op (N) := 1;
            Next_Token;
         end if;
         -- Enum iteration: `for X in T ['Range] loop` over an enum type T
         -- becomes a numeric loop across the type's position range.
         declare
            Eidx : Integer := -1;
            Lo_N : Integer;
            Hi_N : Integer;
         begin
            if Tok = TK_IDENT then
               Eidx := Find_Sym (Tok_Val, Tok_Len);
            end if;
            if Eidx > 0 and then Sym_Kind (Eidx) = SK_TYPE
               and then Sym_Type (Eidx) = TY_ENUM
            then
               Next_Token;                       -- consume type name
               if Tok = TK_TICK then
                  Next_Token; Next_Token;        -- 'Range
               end if;
               Lo_N := New_Node (A_INT_LIT);
               N_Int (Lo_N) := Sym_Range_Lo (Eidx);
               Hi_N := New_Node (A_INT_LIT);
               N_Int (Hi_N) := Sym_Range_Hi (Eidx);
               N_Left (N) := Lo_N;
               N_Right (N) := Hi_N;
            else
               N_Left (N) := Parse_Expression_AST;
               Expect (TK_DOTDOT);
               N_Right (N) := Parse_Expression_AST;
            end if;
         end;
         Expect (TK_LOOP);
         N_First (N) := Parse_Statement_Chain;
         Expect (TK_END); Expect (TK_LOOP); Expect (TK_SEMI);
         return N;
      end if;
      if Tok = TK_DECLARE then
         N := New_Node (S_DECLARE);
         Next_Token;
         N_First (N) := Parse_Var_Decl_Chain;
         Expect (TK_BEGIN);
         N_Arg2 (N) := Parse_Statement_Chain;
         N_Right (N) := G_Pending_Handlers;    -- handler arms, or 0
         Expect (TK_END); Expect (TK_SEMI);
         return N;
      end if;
      if Tok = TK_BEGIN then
         N := New_Node (S_BLOCK);
         Next_Token;
         N_First (N) := Parse_Statement_Chain;
         N_Arg2 (N) := G_Pending_Handlers;      -- handler arms, or 0
         Expect (TK_END); Expect (TK_SEMI);
         return N;
      end if;

      -- Identifier-prefixed: assignment, call, array-assign, paramless,
      -- or dotted package call. The first four become AST nodes; dotted
      -- still direct-emits.
      if Tok = TK_IDENT then
         Saved_Len := Tok_Len;
         for I in 1 .. Tok_Len loop
            Saved (I) := Tok_Val (I);
         end loop;
         Sym_Idx := Find_Sym (Tok_Val, Tok_Len);
         Next_Token;

         if Tok = TK_ASSIGN then
            N := New_Node (S_ASSIGN);
            N_Str_Off (N) := Pool_Str (Saved, Saved_Len);
            N_Str_Len (N) := Saved_Len;
            -- If the target is a range-constrained variable, resolve its
            -- bounds now so the walker can wrap the rhs in a check.
            if Sym_Idx > 0 and then Sym_Has_Range (Sym_Idx) = 1 then
               N_Op (N) := 1;
               N_Aux1 (N) := Sym_Range_Lo (Sym_Idx);
               N_Aux2 (N) := Sym_Range_Hi (Sym_Idx);
            end if;
            Next_Token;
            N_Right (N) := Parse_Expression_AST;
            Expect (TK_SEMI);
            return N;
         end if;

         -- Bare Text_IO builtin made visible by `use Ada.Text_IO;`:
         -- Put_Line ("x"); / New_Line; / ... without the package prefix.
         -- Only for names that don't resolve to a user symbol, so a
         -- user-defined Put_Line still wins.
         if Use_Text_IO and then Sym_Idx <= 0
            and then (Tok = TK_LPAREN or Tok = TK_SEMI)
            and then Is_Textio_Sub (Saved, Saved_Len)
         then
            N := Build_Pkg_Stmt (Saved, Saved_Len, Saved, Saved_Len);
            Expect (TK_SEMI);
            return N;
         end if;

         if Tok = TK_LPAREN then
            Next_Token;
            if Sym_Idx > 0 and then Sym_Kind (Sym_Idx) = SK_PROC
               and then Sym_Arr_Hi (Sym_Idx) = 1
            then
               -- Instantiated Unchecked_Deallocation: Free (P);
               N := New_Node (S_FREE);
               N_Str_Off (N) := Pool_Str (Tok_Val, Tok_Len);
               N_Str_Len (N) := Tok_Len;
               Next_Token;
               Expect (TK_RPAREN); Expect (TK_SEMI);
               return N;
            end if;
            if Sym_Idx > 0 and then (Sym_Kind (Sym_Idx) = SK_PROC or Sym_Kind (Sym_Idx) = SK_FUNC) then
               N := New_Node (S_CALL);
               Set_Call_Name (N, Saved, Saved_Len, Sym_Idx);
               N_Int (N) := Sym_Idx;
               if Tok /= TK_RPAREN then
                  declare
                     First : Integer;
                     Prev : Integer;
                     Arg : Integer;
                  begin
                     First := Parse_Expression_AST;
                     N_First (N) := First;
                     Prev := First;
                     while Tok = TK_COMMA loop
                        Next_Token;
                        Arg := Parse_Expression_AST;
                        N_Next (Prev) := Arg;
                        Prev := Arg;
                     end loop;
                  end;
               end if;
               Expect (TK_RPAREN); Expect (TK_SEMI);
               return N;
            end if;
            if Sym_Idx > 0
               and then (Sym_Kind (Sym_Idx) = SK_VAR or Sym_Kind (Sym_Idx) = SK_PARAM)
               and then Sym_Type (Sym_Idx) = TY_ARRAY
            then
               N := New_Node (S_ARRAY_ASSIGN);
               N_Str_Off (N) := Pool_Str (Saved, Saved_Len);
               N_Str_Len (N) := Saved_Len;
               N_Op (N) := Sym_Arr_Lo (Sym_Idx);         -- resolved outer subtrahend
               N_Aux1 (N) := Sym_Arr_Inner_Lo (Sym_Idx); -- resolved inner subtrahend
               N_Aux2 (N) := Sym_Arr_Hi (Sym_Idx);       -- outer high bound (0 = none)
               N_Int (N) := Sym_Arr_Inner_Hi (Sym_Idx);  -- inner high bound (0 = none)
               N_Right (N) := Parse_Expression_AST;
               Expect (TK_RPAREN);
               if Tok = TK_LPAREN and then Sym_Arr_Inner_Hi (Sym_Idx) /= 0 then
                  Next_Token;
                  N_Arg2 (N) := Parse_Expression_AST;
                  Expect (TK_RPAREN);
               end if;
               Expect (TK_ASSIGN);
               N_First (N) := Parse_Expression_AST;
               Expect (TK_SEMI);
               return N;
            end if;
            -- Unresolved IDENT(...) — treat as call
            N := New_Node (S_CALL);
            Set_Call_Name (N, Saved, Saved_Len, Sym_Idx);
            N_Int (N) := Sym_Idx;
            if Tok /= TK_RPAREN then
               declare
                  First : Integer;
                  Prev : Integer;
                  Arg : Integer;
               begin
                  First := Parse_Expression_AST;
                  N_First (N) := First;
                  Prev := First;
                  while Tok = TK_COMMA loop
                     Next_Token;
                     Arg := Parse_Expression_AST;
                     N_Next (Prev) := Arg;
                     Prev := Arg;
                  end loop;
               end;
            end if;
            Expect (TK_RPAREN); Expect (TK_SEMI);
            return N;
         end if;

         if Tok = TK_SEMI then
            N := New_Node (S_PARAMLESS);
            N_Str_Off (N) := Pool_Str (Saved, Saved_Len);
            N_Str_Len (N) := Saved_Len;
            Next_Token;
            return N;
         end if;

         if Tok = TK_DOT and then Sym_Idx > 0
            and then (Sym_Kind (Sym_Idx) = SK_VAR or Sym_Kind (Sym_Idx) = SK_PARAM)
            and then (Sym_Type (Sym_Idx) = TY_RECORD
                      or Sym_Type (Sym_Idx) = TY_ACCESS
                      or (Sym_Type (Sym_Idx) = TY_ARRAY
                          and then Sym_Arr_Hi (Sym_Idx) = 0
                          and then All_Follows_Dot))
         then
            -- Field assignment (var.field := / p.field := via access) or
            -- dereference assignment (p.all := expr; -> *p = expr;).
            Next_Token;   -- consume '.'
            if Tok = TK_IDENT and then Tok_Eq_CI ("all") then
               N := New_Node (S_ALL_ASSIGN);
               N_Str_Off (N) := Pool_Str (Saved, Saved_Len);
               N_Str_Len (N) := Saved_Len;
               Next_Token;   -- consume 'all'
               Expect (TK_ASSIGN);
               N_Right (N) := Parse_Expression_AST;
               Expect (TK_SEMI);
               return N;
            end if;
            N := New_Node (S_FIELD_ASSIGN);
            N_Str_Off (N) := Pool_Str (Saved, Saved_Len);
            N_Str_Len (N) := Saved_Len;
            N_Arg2 (N) := Pool_Str (Tok_Val, Tok_Len);
            N_Int (N) := Tok_Len;
            if Sym_Type (Sym_Idx) = TY_ACCESS then
               N_Op (N) := 1;                        -- -> instead of .
            end if;
            Next_Token;   -- consume field name
            Expect (TK_ASSIGN);
            N_Right (N) := Parse_Expression_AST;
            Expect (TK_SEMI);
            return N;
         end if;

         if Tok = TK_DOT then
            -- Package-qualified call → S_PKG subtree node.
            Next_Token;
            Sub_Len := Tok_Len;
            for I in 1 .. Tok_Len loop
               Sub (I) := Tok_Val (I);
            end loop;
            Next_Token;
            while Tok = TK_DOT loop
               Next_Token;
               Sub_Len := Tok_Len;
               for I in 1 .. Tok_Len loop
                  Sub (I) := Tok_Val (I);
               end loop;
               Next_Token;
            end loop;
            N := Build_Pkg_Stmt (Saved, Saved_Len, Sub, Sub_Len);
            Expect (TK_SEMI);
            return N;
         end if;
         Error ("expected := or ( after identifier");
         return 0;
      end if;
      Error ("unexpected token in statement");
      return 0;
   end Parse_Statement_AST;

   -- Build a chain of statement nodes (linked by N_Next) until a list
   -- terminator. No emission, no reset — walked later as one tree.
   function Parse_Statement_Chain return Integer is
      Head : Integer := 0;
      Prev : Integer := 0;
      S    : Integer;
   begin
      while Tok /= TK_END and Tok /= TK_ELSIF and
            Tok /= TK_ELSE and Tok /= TK_EOF and Tok /= TK_WHEN and
            Tok /= TK_EXCEPTION
      loop
         S := Parse_Statement_AST;
         if Head = 0 then
            Head := S;
         else
            N_Next (Prev) := S;
         end if;
         Prev := S;
      end loop;
      -- If this sequence is the protected part of a begin/end frame, the
      -- `exception` keyword follows; parse its handler arms and publish
      -- them in G_Pending_Handlers for the enclosing frame. Reset to 0
      -- first so a frame with no handlers reads 0 regardless of any nested
      -- block that set it earlier.
      G_Pending_Handlers := 0;
      if Tok = TK_EXCEPTION then
         Next_Token;
         G_Pending_Handlers := Parse_Handler_Arms;
      end if;
      return Head;
   end Parse_Statement_Chain;

   -- Parse the handler arms after `exception`:
   --   when E1 | E2 => stmts   when others => stmts   ...   (until `end`)
   -- Each arm is an S_WHEN node: N_Op=1 marks `when others`; otherwise
   -- N_First chains S_EXC_ID nodes (one per exception name, N_Aux1 = id);
   -- N_Arg2 is the handler body statement chain.
   function Parse_Handler_Arms return Integer is
      Head : Integer := 0;
      Prev : Integer := 0;
      Arm  : Integer;
   begin
      while Tok = TK_WHEN loop
         Next_Token;
         -- Optional occurrence parameter: `when E : others =>`. Only one
         -- exception is ever in flight, so the name is cosmetic — accept
         -- and discard it; Exception_Message/_Name read the globals.
         if Tok = TK_IDENT and then Colon_Follows_Ident then
            Next_Token;   -- the occurrence name
            Next_Token;   -- the ':'
         end if;
         Arm := New_Node (S_WHEN);
         if Tok = TK_IDENT and then Tok_Eq_CI ("others") then
            N_Op (Arm) := 1;
            Next_Token;
         else
            declare
               Prev_C : Integer := 0;
               Idx    : Integer;
               Id     : Integer;
               C      : Integer;
               Done   : Boolean := False;
            begin
               while not Done loop
                  Idx := Find_Sym (Tok_Val, Tok_Len);
                  if Idx > 0 and then Sym_Kind (Idx) = SK_EXCEPTION then
                     Id := Sym_Arr_Lo (Idx);
                  else
                     Id := 2;
                  end if;
                  C := New_Node (S_EXC_ID);
                  N_Aux1 (C) := Id;
                  if Prev_C = 0 then
                     N_First (Arm) := C;
                  else
                     N_Next (Prev_C) := C;
                  end if;
                  Prev_C := C;
                  Next_Token;
                  if Tok = TK_BAR then
                     Next_Token;
                  else
                     Done := True;
                  end if;
               end loop;
            end;
         end if;
         Expect (TK_ARROW);
         N_Arg2 (Arm) := Parse_Statement_Chain;   -- body, stops at when/end
         if Head = 0 then
            Head := Arm;
         else
            N_Next (Prev) := Arm;
         end if;
         Prev := Arm;
      end loop;
      return Head;
   end Parse_Handler_Arms;

   -- Emit the handler dispatch (inside the `else` of a setjmp wrapper):
   -- a chain of if / else-if on ada_cur_exc, with `when others` becoming a
   -- bare else. If no `others`, an unmatched exception re-propagates to
   -- the enclosing frame via ada_raise.
   procedure Emit_Handlers (Arms : Integer) is
      First      : Boolean := True;
      Has_Others : Boolean := False;
      Arm        : Integer;
      C          : Integer;
      First_C    : Boolean;
   begin
      Arm := Arms;
      while Arm /= 0 loop
         Emit_Indent;
         if N_Op (Arm) = 1 then
            Has_Others := True;
            if First then
               Emit_Ln ("if (1) {");
            else
               Emit_Ln ("else {");
            end if;
         else
            if First then
               Emit ("if (");
            else
               Emit ("else if (");
            end if;
            First_C := True;
            C := N_First (Arm);
            while C /= 0 loop
               if not First_C then
                  Emit (" || ");
               end if;
               Emit ("ada_cur_exc == ");
               Emit_Int (N_Aux1 (C));
               First_C := False;
               C := N_Next (C);
            end loop;
            Emit_Ln (") {");
         end if;
         Indent_Level := Indent_Level + 1;
         Emit_Statement_Chain (N_Arg2 (Arm));
         Indent_Level := Indent_Level - 1;
         Emit_Indent; Emit_Ln ("}");
         First := False;
         Arm := N_Next (Arm);
      end loop;
      if not Has_Others then
         Emit_Indent;
         Emit_Ln ("else { ada_raise(ada_cur_exc, ada_cur_exc_name); }");
      end if;
   end Emit_Handlers;

   -- Emit a begin/end frame that has exception handlers: push a handler,
   -- run the protected body under setjmp, and on a longjmp pop the handler
   -- and dispatch. The handler is also popped on normal fall-through.
   procedure Emit_Handled (Body_Head : Integer; Handlers : Integer) is
   begin
      Emit_Indent; Emit_Ln ("ada_handler _h;");
      Emit_Indent; Emit_Ln ("_h.prev = ada_handler_top; ada_handler_top = &_h;");
      Emit_Indent; Emit_Ln ("if (setjmp(_h.buf) == 0) {");
      Indent_Level := Indent_Level + 1;
      Emit_Statement_Chain (Body_Head);
      Emit_Indent; Emit_Ln ("ada_handler_top = _h.prev;");
      Indent_Level := Indent_Level - 1;
      Emit_Indent; Emit_Ln ("} else {");
      Indent_Level := Indent_Level + 1;
      Emit_Indent; Emit_Ln ("ada_handler_top = _h.prev;");
      Emit_Handlers (Handlers);
      Indent_Level := Indent_Level - 1;
      Emit_Indent; Emit_Ln ("}");
   end Emit_Handled;

   procedure Emit_Statement_Chain (Head : Integer) is
      N : Integer;
   begin
      N := Head;
      while N /= 0 loop
         Emit_Statement_AST (N);
         N := N_Next (N);
      end loop;
   end Emit_Statement_Chain;

   -- Parse one program-unit body: build its statement tree, walk it,
   -- then reset the shared node pool.
   procedure Parse_Statements is
      Head     : Integer;
      Handlers : Integer;
   begin
      Head := Parse_Statement_Chain;
      Handlers := G_Pending_Handlers;
      if Handlers /= 0 then
         Emit_Handled (Head, Handlers);
      else
         Emit_Statement_Chain (Head);
      end if;
      Reset_AST;
   end Parse_Statements;

   -- ---- Declaration-AST walker (variable-leaf nodes only) ----
   procedure Emit_Declaration_AST (N : Integer) is
      Kind : Integer;
      Is_Const : Integer;
   begin
      if N = 0 then return; end if;
      Kind := N_Kind (N);
      Is_Const := N_Op (N);

      if Kind = D_VAR_SIMPLE then
         Emit_Indent;
         if Is_Const = 1 then Emit ("const "); end if;
         Emit_C_Type (N_Int (N));
         Emit (" ");
         Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
         if N_Left (N) /= 0 then
            Emit (" = ");
            -- Wrap the initializer in a range check, but only inside a
            -- real C function — a main-level local is emitted as a C
            -- global, whose initializer must be constant (no call).
            if N_Aux1 (N) = 1 and then Indent_Level > 0 then
               Emit ("ada_range_check(");
               Emit_Expression_AST (N_Left (N));
               Emit (", "); Emit_Int (N_Aux2 (N));
               Emit (", "); Emit_Int (N_Right (N)); Emit (")");
            else
               Emit_Expression_AST (N_Left (N));
            end if;
         elsif N_Int (N) = TY_STRING then
            Emit (" = """"");
         else
            Emit (" = 0");
         end if;
         Emit_Ln (";");
      elsif Kind = D_VAR_NAMED_ARRAY then
         -- el type in N_Aux1, element count in N_Aux2 (resolved at build).
         Emit_Indent;
         Emit_C_Type (N_Aux1 (N));
         Emit (" ");
         Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
         Emit ("[");
         Emit_Int (N_Aux2 (N));
         Emit_Ln ("];");
      elsif Kind = D_VAR_ANON_ARRAY then
         -- el type in N_Aux1, outer count in N_Aux2, inner count in N_Int
         -- (0 = flat), all resolved at build.
         Emit_Indent;
         if Is_Const = 1 then Emit ("const "); end if;
         Emit_C_Type (N_Aux1 (N));
         Emit (" ");
         Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
         Emit ("[");
         Emit_Int (N_Aux2 (N));
         Emit ("]");
         if N_Int (N) /= 0 then
            Emit ("[");
            Emit_Int (N_Int (N));
            Emit ("]");
         end if;
         Emit_Ln (";");
      elsif Kind = D_VAR_STRING then
         Emit_Indent;
         Emit ("const char *");
         Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
         if N_Left (N) /= 0 then
            Emit (" = ");
            Emit_Expression_AST (N_Left (N));
         else
            Emit (" = """"");
         end if;
         Emit_Ln (";");
      elsif Kind = D_VAR_FILE then
         Emit_Indent;
         Emit ("FILE *");
         Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
         Emit_Ln (" = NULL;");
      elsif Kind = D_VAR_ACCESS then
         -- Elem *name / struct <rec> *name [= <new ...>]; (default NULL)
         Emit_Indent;
         if Is_Const = 1 then Emit ("const "); end if;
         if N_Aux1 (N) = TY_RECORD then
            Emit ("struct ");
            Emit_Pool_Lower (N_Arg2 (N), N_Int (N));   -- record type name
         else
            Emit_C_Type (N_Aux1 (N));
         end if;
         Emit (" *");
         Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
         if N_Left (N) /= 0 then
            Emit (" = ");
            Emit_Expression_AST (N_Left (N));
         else
            Emit (" = NULL");
         end if;
         Emit_Ln (";");
      elsif Kind = D_VAR_RECORD then
         -- struct <typename> name [= <other record>] (default {0}).
         Emit_Indent;
         if Is_Const = 1 then Emit ("const "); end if;
         Emit ("struct ");
         Emit_Name_Pool_Lower (N_Arg2 (N), N_Int (N));   -- record type name
         Emit (" ");
         Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
         if N_Left (N) /= 0 then
            Emit (" = ");
            Emit_Expression_AST (N_Left (N));
         else
            Emit (" = {0}");
         end if;
         Emit_Ln (";");
      elsif Kind = D_VAR_DOTTED then
         Emit_Indent;
         if Is_Const = 1 then Emit ("const "); end if;
         Emit ("int ");
         Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
         if N_Left (N) /= 0 then
            Emit (" = ");
            Emit_Expression_AST (N_Left (N));
         else
            Emit (" = 0");
         end if;
         Emit_Ln (";");
      end if;
   end Emit_Declaration_AST;

   -- ---- Parse one declaration ----
   -- Variables become AST nodes; type definitions and procedure/function
   -- declarations direct-emit and return 0. Returning 0 also signals
   -- "this isn't a declaration we recognise" so the wrapper stops.
   -- Parse one bound of a range constraint: an optionally-signed integer
   -- literal. (v1 restricts bounds to static literals.)
   function Parse_Range_Bound return Integer is
      Neg : Boolean := False;
      V   : Integer;
   begin
      if Tok = TK_MINUS then
         Neg := True;
         Next_Token;
      end if;
      V := Tok_Int;
      Next_Token;
      if Neg then
         return -V;
      else
         return V;
      end if;
   end Parse_Range_Bound;

   function Parse_Declaration_AST return Integer is
      Var_Name : Tok_Buffer;
      Var_Len  : Integer;
      Typ      : Integer;
      Is_Const : Boolean;
      N        : Integer;
   begin
      if Tok = TK_TYPE then
         Next_Token;
         Add_Sym (SK_TYPE, TY_ARRAY);
         Next_Token;
         -- Incomplete type declaration: `type Node;` — assume a record
         -- (its only use in the subset is a self-referencing record via
         -- an access type). No C is emitted: `struct node` is usable
         -- self-referentially in C without a forward declaration.
         if Tok = TK_SEMI then
            Sym_Type (Sym_Count) := TY_RECORD;
            Next_Token;
            return 0;
         end if;
         Expect (TK_IS);
         if Tok = TK_ARRAY then
            Next_Token;
            Expect (TK_LPAREN);
            if Tok = TK_INTEGER or Tok = TK_NATURAL or Tok = TK_POSITIVE
               or Tok = TK_CHARACTER or Tok = TK_BOOLEAN
            then
               -- Unconstrained: `array (Index range <>) of Elem`. hi=0
               -- marks "no fixed size"; only used as an access target.
               declare
                  El : Integer;
               begin
                  Next_Token;
                  Expect (TK_RANGE);
                  Expect (TK_BOX);
                  Expect (TK_RPAREN);
                  Expect (TK_OF);
                  El := Parse_Type_Ref;
                  Sym_Arr_Lo (Sym_Count) := 1;
                  Sym_Arr_Hi (Sym_Count) := 0;
                  Sym_Arr_El (Sym_Count) := El;
               end;
            else
               declare
                  Lo : Integer := 0;
                  Hi : Integer := 0;
                  El : Integer;
               begin
                  if Tok = TK_INT_LIT then Lo := Tok_Int; end if;
                  Next_Token;
                  Expect (TK_DOTDOT);
                  if Tok = TK_INT_LIT then Hi := Tok_Int; end if;
                  Next_Token;
                  if Tok = TK_COMMA then
                     Next_Token;
                     if Tok = TK_INT_LIT then Next_Token; end if;
                     Expect (TK_DOTDOT);
                     if Tok = TK_INT_LIT then Next_Token; end if;
                  end if;
                  Expect (TK_RPAREN);
                  Expect (TK_OF);
                  El := Parse_Type_Ref;
                  Sym_Arr_Lo (Sym_Count) := Lo;
                  Sym_Arr_Hi (Sym_Count) := Hi;
                  Sym_Arr_El (Sym_Count) := El;
               end;
            end if;
         elsif Tok = TK_ACCESS then
            -- `access <ArrayTypeName>`, `access <RecordTypeName>`, or
            -- `access <ScalarType>`. Array/scalar targets are modelled as
            -- a pointer to the element type; a record target keeps the
            -- record type's symbol index (+1, 0 = none) in
            -- Sym_Arr_Inner_Lo so declarations can emit `struct <name> *`.
            declare
               El  : Integer := TY_INTEGER;
               Rec : Integer := 0;
               Ti  : Integer;
            begin
               Next_Token;
               if Tok = TK_IDENT then
                  Ti := Find_Sym (Tok_Val, Tok_Len);
                  if Ti > 0 and then Sym_Kind (Ti) = SK_TYPE then
                     if Sym_Type (Ti) = TY_RECORD then
                        El := TY_RECORD;
                        Rec := Ti + 1;
                     else
                        El := Sym_Arr_El (Ti);
                     end if;
                  end if;
                  Next_Token;
               else
                  El := Parse_Type_Ref;
               end if;
               Sym_Type (Sym_Count) := TY_ACCESS;
               Sym_Arr_Lo (Sym_Count) := 1;
               Sym_Arr_Hi (Sym_Count) := 0;
               Sym_Arr_El (Sym_Count) := El;
               Sym_Arr_Inner_Lo (Sym_Count) := Rec;
            end;
         elsif Tok = TK_RECORD then
            -- `record F1 : T1; ... end record;` -> a C struct, emitted here.
            declare
               FTy : Integer;
               Fti : Integer;
            begin
               Sym_Type (Sym_Count) := TY_RECORD;
               Emit ("struct ");
               Emit_Name_Pool_Lower (Sym_Name_Off (Sym_Count), Sym_Name_Len (Sym_Count));
               Emit (" {");
               Next_Token;   -- consume 'record'
               while Tok /= TK_END and Tok /= TK_EOF loop
                  declare
                     FName : Tok_Buffer;
                     FNLen : Integer;
                  begin
                     FNLen := Tok_Len;
                     for I in 1 .. Tok_Len loop
                        FName (I) := Tok_Val (I);
                     end loop;
                     Next_Token;
                     Expect (TK_COLON);
                     -- Access-typed field -> a pointer member (this is what
                     -- makes self-referencing records like list nodes work).
                     Fti := -1;
                     if Tok = TK_IDENT then
                        Fti := Find_Sym (Tok_Val, Tok_Len);
                     end if;
                     if Fti > 0 and then Sym_Kind (Fti) = SK_TYPE
                        and then Sym_Type (Fti) = TY_ACCESS
                     then
                        Emit (" ");
                        if Sym_Arr_El (Fti) = TY_RECORD
                           and then Sym_Arr_Inner_Lo (Fti) /= 0
                        then
                           Emit ("struct ");
                           Emit_Name_Pool_Lower
                              (Sym_Name_Off (Sym_Arr_Inner_Lo (Fti) - 1),
                               Sym_Name_Len (Sym_Arr_Inner_Lo (Fti) - 1));
                        else
                           Emit_C_Type (Sym_Arr_El (Fti));
                        end if;
                        Emit (" *");
                        Emit_Lower (FName, FNLen);
                        Emit (";");
                        Next_Token;
                     else
                        FTy := Parse_Type_Ref;
                        Emit (" ");
                        Emit_C_Type (FTy);
                        Emit (" ");
                        Emit_Lower (FName, FNLen);
                        Emit (";");
                     end if;
                     Expect (TK_SEMI);
                  end;
               end loop;
               Emit_Ln (" };");
               Expect (TK_END);
               Expect (TK_RECORD);
            end;
         elsif Tok = TK_LPAREN then
            -- enumeration: `type T is (A, B, C);` -> a C enum whose
            -- constants are the lowercased literals (a=0, b=1, ...). Each
            -- literal is registered as a constant; the type is an int.
            declare
               First     : Boolean := True;
               Type_Idx  : Integer := Sym_Count;
               First_Lit : Integer := Sym_Count + 1;
               Nlits     : Integer;
            begin
               Sym_Type (Type_Idx) := TY_ENUM;
               Emit ("enum { ");
               Next_Token;   -- consume '('
               while Tok /= TK_RPAREN and Tok /= TK_EOF loop
                  if not First then Emit (", "); end if;
                  First := False;
                  Emit_Lower (Tok_Val, Tok_Len);     -- literal -> C constant
                  Add_Sym (SK_CONST, TY_ENUM);        -- register the literal
                  Next_Token;
                  if Tok = TK_COMMA then Next_Token; end if;
               end loop;
               Emit_Ln (" };");
               Expect (TK_RPAREN);
               Nlits := Sym_Count - Type_Idx;
               -- The type carries its position range [0, Nlits-1] so
               -- 'First / 'Last, enum iteration, and assignment checks work.
               Sym_Has_Range (Type_Idx) := 1;
               Sym_Range_Lo (Type_Idx) := 0;
               Sym_Range_Hi (Type_Idx) := Nlits - 1;
               -- T'Image support: <type>_image(v) returning the uppercased
               -- literal name. Only emit at file scope (a nested C function
               -- would be illegal; proc-local enum 'Image is deferred).
               if Indent_Level = 0 then
                  Emit ("static const char *");
                  Emit_Name_Pool_Lower (Sym_Name_Off (Type_Idx),
                                        Sym_Name_Len (Type_Idx));
                  Emit_Ln ("_image(int v) {");
                  Emit_Ln ("    switch (v) {");
                  for I in 0 .. Nlits - 1 loop
                     Emit ("    case "); Emit_Int (I); Emit (": return """);
                     Emit_Name_Pool_Upper (Sym_Name_Off (First_Lit + I),
                                           Sym_Name_Len (First_Lit + I));
                     Emit_Ln (""";");
                  end loop;
                  Emit_Ln ("    default: return ""?"";");
                  Emit_Ln ("    }");
                  Emit_Ln ("}");
               end if;
            end;
         elsif Tok = TK_RANGE then
            -- `type T is range L .. H;` -> an integer type carrying a
            -- range constraint (no C emission; the type is a plain int).
            declare
               Lo : Integer;
               Hi : Integer;
            begin
               Next_Token;
               Lo := Parse_Range_Bound;
               Expect (TK_DOTDOT);
               Hi := Parse_Range_Bound;
               Sym_Type (Sym_Count) := TY_INTEGER;
               Sym_Has_Range (Sym_Count) := 1;
               Sym_Range_Lo (Sym_Count) := Lo;
               Sym_Range_Hi (Sym_Count) := Hi;
            end;
         else
            while Tok /= TK_SEMI and Tok /= TK_EOF loop
               Next_Token;
            end loop;
         end if;
         Expect (TK_SEMI);
         return 0;
      end if;

      if Tok = TK_SUBTYPE then
         -- `subtype S is Base range L .. H;` -> a constrained integer
         -- subtype. Base is consumed (only integer subtypes are checked
         -- in v1); the bounds are stored for assignment/init checks.
         declare
            Lo : Integer;
            Hi : Integer;
         begin
            Next_Token;
            Add_Sym (SK_TYPE, TY_INTEGER);
            Next_Token;                  -- subtype name
            Expect (TK_IS);
            if Tok = TK_INTEGER then
               Next_Token;
            elsif Tok = TK_NATURAL then
               -- base Natural: inherit 0 .. Integer'Last (an explicit
               -- `range L .. H` below overrides it).
               Sym_Has_Range (Sym_Count) := 1;
               Sym_Range_Lo (Sym_Count) := 0;
               Sym_Range_Hi (Sym_Count) := 2147483647;
               Next_Token;
            elsif Tok = TK_POSITIVE then
               Sym_Has_Range (Sym_Count) := 1;
               Sym_Range_Lo (Sym_Count) := 1;
               Sym_Range_Hi (Sym_Count) := 2147483647;
               Next_Token;
            elsif Tok = TK_IDENT then
               Next_Token;               -- a base subtype name
            end if;
            if Tok = TK_RANGE then
               Next_Token;
               Lo := Parse_Range_Bound;
               Expect (TK_DOTDOT);
               Hi := Parse_Range_Bound;
               Sym_Has_Range (Sym_Count) := 1;
               Sym_Range_Lo (Sym_Count) := Lo;
               Sym_Range_Hi (Sym_Count) := Hi;
            end if;
            while Tok /= TK_SEMI and Tok /= TK_EOF loop
               Next_Token;
            end loop;
            Expect (TK_SEMI);
            return 0;
         end;
      end if;

      if Tok = TK_PACKAGE then
         -- package [body] P is <decls> end [P]; — a namespace whose
         -- subprograms become <pkg>_<op> C functions.
         declare
            Psym : Integer;
            Saved_Pkg : Integer;
         begin
            Next_Token;
            if Tok = TK_IDENT and then Tok_Eq_CI ("body") then Next_Token; end if;
            Add_Sym (SK_PACKAGE, 0);          -- name = the package name token
            Psym := Sym_Count;
            Next_Token;
            Expect (TK_IS);
            Saved_Pkg := Cur_Pkg;
            Cur_Pkg := Psym + 1;              -- +1 so index isn't the "none" sentinel
            Parse_Declarations;               -- subprograms tagged + mangled
            Cur_Pkg := Saved_Pkg;
            if Tok = TK_BEGIN then
               Error ("package initialization (begin) not supported");
            end if;
            Expect (TK_END);
            if Tok = TK_IDENT then Next_Token; end if;  -- optional repeated name
            Expect (TK_SEMI);
            return 0;
         end;
      end if;

      if Tok = TK_PROCEDURE then
            Next_Token;
            declare
               P_Name : Tok_Buffer;
               P_Len  : Integer;
               Is_Fwd : Boolean := False;
            begin
               P_Len := Tok_Len;
               for I in 1 .. Tok_Len loop
                  P_Name (I) := Tok_Val (I);
               end loop;
               Add_Sym (SK_PROC, 0);
               if Cur_Pkg /= 0 then Sym_Arr_Lo (Sym_Count) := Cur_Pkg; end if;
               Next_Token;
               -- Generic instantiation: the only supported generic is
               --   procedure Free is new Ada.Unchecked_Deallocation (T, PT);
               -- Tagged via Sym_Arr_Hi = 1; a call `Free (P);` then emits
               -- `free(p); p = NULL;`. No C is emitted here.
               if Tok = TK_IS and then New_Follows_Is then
                  while Tok /= TK_SEMI and Tok /= TK_EOF loop
                     Next_Token;
                  end loop;
                  Expect (TK_SEMI);
                  Sym_Arr_Hi (Sym_Count) := 1;   -- free-proc tag
                  return 0;
               end if;
               Emit ("void ");
               Emit_Sub_Name (P_Name, P_Len);
               Emit ("(");
               Push_Scope;
               if Tok = TK_LPAREN then
                  Next_Token;
                  declare
                     First : Boolean := True;
                     Parm : Tok_Buffer;
                     Parm_Len : Integer;
                     Arr_Idx : Integer;
                     Rec_Idx : Integer;
                  begin
                     while Tok /= TK_RPAREN and Tok /= TK_EOF loop
                        if not First then Emit (", "); end if;
                        First := False;
                        Parm_Len := Tok_Len;
                        for I in 1 .. Tok_Len loop
                           Parm (I) := Tok_Val (I);
                        end loop;
                        Add_Sym (SK_PARAM, TY_INTEGER);
                        Next_Token;
                        Expect (TK_COLON);
                        Arr_Idx := 0;
                        Rec_Idx := 0;
                        if Tok = TK_IDENT then
                           Arr_Idx := Find_Sym (Tok_Val, Tok_Len);
                           if Arr_Idx > 0 and then Sym_Kind (Arr_Idx) = SK_TYPE
                              and then Sym_Type (Arr_Idx) = TY_RECORD
                           then
                              Rec_Idx := Arr_Idx;
                              Arr_Idx := 0;
                           elsif Arr_Idx > 0 and then
                              (Sym_Kind (Arr_Idx) /= SK_TYPE or Sym_Type (Arr_Idx) /= TY_ARRAY)
                           then
                              Arr_Idx := 0;
                           end if;
                        end if;
                        if Arr_Idx > 0 then
                           Sym_Type (Sym_Count) := TY_ARRAY;
                           Sym_Arr_Lo (Sym_Count) := Sym_Arr_Lo (Arr_Idx);
                           Sym_Arr_Hi (Sym_Count) := Sym_Arr_Hi (Arr_Idx);
                           Sym_Arr_El (Sym_Count) := Sym_Arr_El (Arr_Idx);
                           Emit_C_Type (Sym_Arr_El (Arr_Idx));
                           Emit (" *");
                           Emit_Lower (Parm, Parm_Len);
                           Next_Token;
                        elsif Rec_Idx > 0 then
                           Sym_Type (Sym_Count) := TY_RECORD;
                           Emit ("struct ");
                           Emit_Name_Pool_Lower (Sym_Name_Off (Rec_Idx), Sym_Name_Len (Rec_Idx));
                           Emit (" ");
                           Emit_Lower (Parm, Parm_Len);
                           Next_Token;
                        else
                           Typ := Parse_Type_Ref;
                           Sym_Type (Sym_Count) := Typ;
                           if Typ = TY_STRING then
                              Sym_Arr_Lo (Sym_Count) := 1;
                           end if;
                           Emit_C_Type (Typ);
                           Emit (" ");
                           Emit_Lower (Parm, Parm_Len);
                        end if;
                        if Tok = TK_SEMI then Next_Token; end if;
                     end loop;
                     Expect (TK_RPAREN);
                  end;
               end if;
               if Tok = TK_SEMI then
                  Is_Fwd := True;
                  Emit_Ln (");");
                  Next_Token;
                  Pop_Scope;
               end if;
               if not Is_Fwd then
                  Emit_Ln (") {");
                  Expect (TK_IS);
                  Indent_Level := Indent_Level + 1;
                  Parse_Declarations;
                  Expect (TK_BEGIN);
                  Parse_Statements;
                  Indent_Level := Indent_Level - 1;
                  Emit_Ln ("}");
                  Emit_Ln ("");
                  Expect (TK_END);
                  if Tok = TK_IDENT then Next_Token; end if;
                  Expect (TK_SEMI);
                  Pop_Scope;
               end if;
            end;
         return 0;
         end if;

         if Tok = TK_FUNCTION then
            Next_Token;
            declare
               F_Name : Tok_Buffer;
               F_Len  : Integer;
               Ret    : Integer;
               P_Names : array (1 .. 20) of Tok_Buffer;
               P_Lens  : array (1 .. 20) of Integer;
               P_Types : array (1 .. 20) of Integer;
               P_El    : array (1 .. 20) of Integer;
               P_Rec   : array (1 .. 20) of Integer;  -- record type sym idx, else 0
               P_Count : Integer := 0;
               Is_Fwd  : Boolean := False;
               Arr_Idx : Integer;
               Rec_Idx : Integer;
            begin
               F_Len := Tok_Len;
               for I in 1 .. Tok_Len loop
                  F_Name (I) := Tok_Val (I);
               end loop;
               Add_Sym (SK_FUNC, TY_INTEGER);
               if Cur_Pkg /= 0 then Sym_Arr_Lo (Sym_Count) := Cur_Pkg; end if;
               Next_Token;
               Push_Scope;
               if Tok = TK_LPAREN then
                  Next_Token;
                  while Tok /= TK_RPAREN and Tok /= TK_EOF loop
                     P_Count := P_Count + 1;
                     P_Lens (P_Count) := Tok_Len;
                     for I in 1 .. Tok_Len loop
                        P_Names (P_Count) (I) := Tok_Val (I);
                     end loop;
                     Add_Sym (SK_PARAM, TY_INTEGER);
                     Next_Token;
                     Expect (TK_COLON);
                     Arr_Idx := 0;
                     Rec_Idx := 0;
                     P_Rec (P_Count) := 0;
                     if Tok = TK_IDENT then
                        Arr_Idx := Find_Sym (Tok_Val, Tok_Len);
                        if Arr_Idx > 0 and then Sym_Kind (Arr_Idx) = SK_TYPE
                           and then Sym_Type (Arr_Idx) = TY_RECORD
                        then
                           Rec_Idx := Arr_Idx;
                           Arr_Idx := 0;
                        elsif Arr_Idx > 0 and then
                           (Sym_Kind (Arr_Idx) /= SK_TYPE or Sym_Type (Arr_Idx) /= TY_ARRAY)
                        then
                           Arr_Idx := 0;
                        end if;
                     end if;
                     if Arr_Idx > 0 then
                        P_Types (P_Count) := TY_ARRAY;
                        P_El (P_Count) := Sym_Arr_El (Arr_Idx);
                        Sym_Type (Sym_Count) := TY_ARRAY;
                        Sym_Arr_Lo (Sym_Count) := Sym_Arr_Lo (Arr_Idx);
                        Sym_Arr_Hi (Sym_Count) := Sym_Arr_Hi (Arr_Idx);
                        Sym_Arr_El (Sym_Count) := Sym_Arr_El (Arr_Idx);
                        Next_Token;
                     elsif Rec_Idx > 0 then
                        P_Types (P_Count) := TY_RECORD;
                        P_El (P_Count) := 0;
                        P_Rec (P_Count) := Rec_Idx;
                        Sym_Type (Sym_Count) := TY_RECORD;
                        Next_Token;
                     else
                        P_Types (P_Count) := Parse_Type_Ref;
                        P_El (P_Count) := 0;
                        Sym_Type (Sym_Count) := P_Types (P_Count);
                        if P_Types (P_Count) = TY_STRING then
                           Sym_Arr_Lo (Sym_Count) := 1;
                        end if;
                     end if;
                     if Tok = TK_SEMI then Next_Token; end if;
                  end loop;
                  Expect (TK_RPAREN);
               end if;
               Expect (TK_RETURN);
               Ret := Parse_Type_Ref;
               Emit_C_Type (Ret);
               Emit (" ");
               Emit_Sub_Name (F_Name, F_Len);
               Emit ("(");
               for I in 1 .. P_Count loop
                  if I > 1 then Emit (", "); end if;
                  if P_Types (I) = TY_ARRAY then
                     Emit_C_Type (P_El (I));
                     Emit (" *");
                  elsif P_Types (I) = TY_RECORD then
                     Emit ("struct ");
                     Emit_Name_Pool_Lower (Sym_Name_Off (P_Rec (I)), Sym_Name_Len (P_Rec (I)));
                     Emit (" ");
                  else
                     Emit_C_Type (P_Types (I));
                     Emit (" ");
                  end if;
                  Emit_Lower (P_Names (I), P_Lens (I));
               end loop;
               if P_Count = 0 then Emit ("void"); end if;
               if Tok = TK_SEMI then
                  Is_Fwd := True;
                  Emit_Ln (");");
                  Next_Token;
                  Pop_Scope;
               end if;
               if not Is_Fwd then
                  Emit_Ln (") {");
                  Expect (TK_IS);
                  Indent_Level := Indent_Level + 1;
                  Parse_Declarations;
                  Expect (TK_BEGIN);
                  Parse_Statements;
                  Indent_Level := Indent_Level - 1;
                  Emit_Ln ("}");
                  Emit_Ln ("");
                  Expect (TK_END);
                  if Tok = TK_IDENT then Next_Token; end if;
                  Expect (TK_SEMI);
                  Pop_Scope;
               end if;
            end;
         return 0;
         end if;

         if Tok = TK_IDENT then
            Var_Len := Tok_Len;
            for I in 1 .. Tok_Len loop
               Var_Name (I) := Tok_Val (I);
            end loop;
            Next_Token;
            Expect (TK_COLON);
            Is_Const := False;
            if Tok = TK_CONSTANT then
               Is_Const := True;
               Next_Token;
            end if;

            -- Exception declaration: Name : exception;  -> register an
            -- SK_EXCEPTION symbol with a fresh id; emits no C (ids are
            -- compile-time constants used at raise/handler sites).
            if Tok = TK_EXCEPTION then
               Next_Token;
               Expect (TK_SEMI);
               Add_Sym_Named (Var_Name, Var_Len, SK_EXCEPTION, 0);
               Sym_Arr_Lo (Sym_Count) := Next_Exc_Id;
               Next_Exc_Id := Next_Exc_Id + 1;
               return 0;
            end if;

            -- Anonymous inline array: Name : array (lo..hi) of T;
            if Tok = TK_ARRAY then
               Next_Token;
               Expect (TK_LPAREN);
               declare
                  Lo : Integer := 0;
                  Hi : Integer := 0;
                  El_Type : Integer := TY_INTEGER;
                  Inner_Lo : Integer := 0;
                  Inner_Hi : Integer := 0;
                  Is_Nested : Boolean := False;
                  Tidx : Integer;
               begin
                  if Tok = TK_INT_LIT then Lo := Tok_Int; end if;
                  Next_Token;
                  Expect (TK_DOTDOT);
                  if Tok = TK_INT_LIT then Hi := Tok_Int; end if;
                  Next_Token;
                  Expect (TK_RPAREN);
                  Expect (TK_OF);
                  if Tok = TK_IDENT then
                     Tidx := Find_Sym (Tok_Val, Tok_Len);
                     if Tidx > 0 and then Sym_Kind (Tidx) = SK_TYPE and then Sym_Type (Tidx) = TY_ARRAY then
                        Is_Nested := True;
                        Inner_Lo := Sym_Arr_Lo (Tidx);
                        Inner_Hi := Sym_Arr_Hi (Tidx);
                        El_Type := Sym_Arr_El (Tidx);
                        Next_Token;
                     else
                        El_Type := Parse_Type_Ref;
                     end if;
                  else
                     El_Type := Parse_Type_Ref;
                  end if;
                  if Is_Const then
                     Add_Sym_Named (Var_Name, Var_Len, SK_CONST, TY_ARRAY);
                  else
                     Add_Sym_Named (Var_Name, Var_Len, SK_VAR, TY_ARRAY);
                  end if;
                  Sym_Arr_Lo (Sym_Count) := Lo;
                  Sym_Arr_Hi (Sym_Count) := Hi;
                  Sym_Arr_El (Sym_Count) := El_Type;
                  if Is_Nested then
                     Sym_Arr_Inner_Lo (Sym_Count) := Inner_Lo;
                     Sym_Arr_Inner_Hi (Sym_Count) := Inner_Hi;
                  end if;
                  N := New_Node (D_VAR_ANON_ARRAY);
                  N_Str_Off (N) := Pool_Str (Var_Name, Var_Len);
                  N_Str_Len (N) := Var_Len;
                  if Is_Const then N_Op (N) := 1; else N_Op (N) := 0; end if;
                  N_Aux1 (N) := El_Type;          -- resolved element type
                  N_Aux2 (N) := Hi - Lo + 1;      -- resolved outer count
                  if Is_Nested then               -- inner count, 0 if flat
                     N_Int (N) := Inner_Hi - Inner_Lo + 1;
                  else
                     N_Int (N) := 0;
                  end if;
                  if Tok = TK_ASSIGN then
                     Next_Token;
                     while Tok /= TK_SEMI and Tok /= TK_EOF loop
                        Next_Token;
                     end loop;
                  end if;
                  Expect (TK_SEMI);
                  return N;
               end;
            end if;

            -- Named array type variable
            if Tok = TK_IDENT then
               declare
                  Tidx : Integer;
               begin
                  Tidx := Find_Sym (Tok_Val, Tok_Len);
                  if Tidx > 0 and then Sym_Kind (Tidx) = SK_TYPE and then Sym_Type (Tidx) = TY_ARRAY then
                     if Is_Const then
                        Add_Sym_Named (Var_Name, Var_Len, SK_CONST, TY_ARRAY);
                     else
                        Add_Sym_Named (Var_Name, Var_Len, SK_VAR, TY_ARRAY);
                     end if;
                     Sym_Arr_Lo (Sym_Count) := Sym_Arr_Lo (Tidx);
                     Sym_Arr_Hi (Sym_Count) := Sym_Arr_Hi (Tidx);
                     Sym_Arr_El (Sym_Count) := Sym_Arr_El (Tidx);
                     N := New_Node (D_VAR_NAMED_ARRAY);
                     N_Str_Off (N) := Pool_Str (Var_Name, Var_Len);
                     N_Str_Len (N) := Var_Len;
                     if Is_Const then N_Op (N) := 1; else N_Op (N) := 0; end if;
                     N_Aux1 (N) := Sym_Arr_El (Tidx);  -- resolved element type
                     N_Aux2 (N) := Sym_Arr_Hi (Tidx) - Sym_Arr_Lo (Tidx) + 1;
                     Next_Token;
                     if Tok = TK_ASSIGN then
                        Next_Token;
                        while Tok /= TK_SEMI and Tok /= TK_EOF loop
                           Next_Token;
                        end loop;
                     end if;
                     Expect (TK_SEMI);
                     return N;
                  end if;
               end;
            end if;

            -- Access-typed variable: registered as an indexable pointer
            -- (TY_ARRAY, lo=1, no fixed size) so the array index / assign
            -- machinery applies; only the declaration differs.
            if Tok = TK_IDENT then
               declare
                  Tidx : Integer;
                  El   : Integer;
               begin
                  Tidx := Find_Sym (Tok_Val, Tok_Len);
                  if Tidx > 0 and then Sym_Kind (Tidx) = SK_TYPE and then Sym_Type (Tidx) = TY_ACCESS then
                     El := Sym_Arr_El (Tidx);
                     if El = TY_RECORD and then Sym_Arr_Inner_Lo (Tidx) /= 0 then
                        -- Access-to-record: `struct <rec> *name`. Registered
                        -- TY_ACCESS (not TY_ARRAY) so `.field` resolves to
                        -- `->` instead of the indexing machinery.
                        declare
                           Rec : Integer := Sym_Arr_Inner_Lo (Tidx);
                        begin
                           if Is_Const then
                              Add_Sym_Named (Var_Name, Var_Len, SK_CONST, TY_ACCESS);
                           else
                              Add_Sym_Named (Var_Name, Var_Len, SK_VAR, TY_ACCESS);
                           end if;
                           Sym_Arr_Lo (Sym_Count) := 1;
                           Sym_Arr_Hi (Sym_Count) := 0;
                           Sym_Arr_El (Sym_Count) := TY_RECORD;
                           Sym_Arr_Inner_Lo (Sym_Count) := Rec;
                           N := New_Node (D_VAR_ACCESS);
                           N_Str_Off (N) := Pool_Str (Var_Name, Var_Len);
                           N_Str_Len (N) := Var_Len;
                           if Is_Const then N_Op (N) := 1; else N_Op (N) := 0; end if;
                           N_Aux1 (N) := TY_RECORD;
                           N_Arg2 (N) := Pool_Name_Pool (Sym_Name_Off (Rec - 1),
                                                         Sym_Name_Len (Rec - 1));
                           N_Int (N) := Sym_Name_Len (Rec - 1);
                           Next_Token;
                           if Tok = TK_ASSIGN then
                              Next_Token;
                              N_Left (N) := Parse_Expression_AST;  -- e.g. new Node
                           end if;
                           Expect (TK_SEMI);
                           return N;
                        end;
                     end if;
                     if Is_Const then
                        Add_Sym_Named (Var_Name, Var_Len, SK_CONST, TY_ARRAY);
                     else
                        Add_Sym_Named (Var_Name, Var_Len, SK_VAR, TY_ARRAY);
                     end if;
                     Sym_Arr_Lo (Sym_Count) := 1;
                     Sym_Arr_Hi (Sym_Count) := 0;
                     Sym_Arr_El (Sym_Count) := El;
                     N := New_Node (D_VAR_ACCESS);
                     N_Str_Off (N) := Pool_Str (Var_Name, Var_Len);
                     N_Str_Len (N) := Var_Len;
                     if Is_Const then N_Op (N) := 1; else N_Op (N) := 0; end if;
                     N_Aux1 (N) := El;            -- element type for `Elem *`
                     Next_Token;
                     if Tok = TK_ASSIGN then
                        Next_Token;
                        N_Left (N) := Parse_Expression_AST;   -- e.g. new ...
                     end if;
                     Expect (TK_SEMI);
                     return N;
                  end if;
               end;
            end if;

            -- Record-typed variable: Name : Some_Record_Type;
            -- -> struct <typename> name = {0};  (registered TY_RECORD).
            if Tok = TK_IDENT then
               declare
                  Tidx : Integer;
               begin
                  Tidx := Find_Sym (Tok_Val, Tok_Len);
                  if Tidx > 0 and then Sym_Kind (Tidx) = SK_TYPE and then Sym_Type (Tidx) = TY_RECORD then
                     N := New_Node (D_VAR_RECORD);
                     -- record type name lives in the Name_Pool at Tidx.
                     N_Arg2 (N) := Sym_Name_Off (Tidx);
                     N_Int (N) := Sym_Name_Len (Tidx);
                     if Is_Const then
                        Add_Sym_Named (Var_Name, Var_Len, SK_CONST, TY_RECORD);
                     else
                        Add_Sym_Named (Var_Name, Var_Len, SK_VAR, TY_RECORD);
                     end if;
                     N_Str_Off (N) := Pool_Str (Var_Name, Var_Len);
                     N_Str_Len (N) := Var_Len;
                     if Is_Const then N_Op (N) := 1; else N_Op (N) := 0; end if;
                     Next_Token;
                     if Tok = TK_ASSIGN then     -- init from another record
                        Next_Token;
                        N_Left (N) := Parse_Expression_AST;
                     end if;
                     Expect (TK_SEMI);
                     return N;
                  end if;
               end;
            end if;

            -- String type variable
            if Tok = TK_STRING then
               Next_Token;
               if Is_Const then
                  Add_Sym_Named (Var_Name, Var_Len, SK_CONST, TY_STRING);
               else
                  Add_Sym_Named (Var_Name, Var_Len, SK_VAR, TY_STRING);
               end if;
               N := New_Node (D_VAR_STRING);
               N_Str_Off (N) := Pool_Str (Var_Name, Var_Len);
               N_Str_Len (N) := Var_Len;
               N_Int (N) := Sym_Count;
               if Is_Const then N_Op (N) := 1; else N_Op (N) := 0; end if;
               if Tok = TK_ASSIGN then
                  Next_Token;
                  N_Left (N) := Parse_Expression_AST;
               end if;
               Expect (TK_SEMI);
               return N;
            end if;

            -- Dotted-type variable (File_Type or other dotted name)
            if Tok = TK_IDENT then
               declare
                  Is_File_Type : Boolean := False;
                  First_Ident : Tok_Buffer;
                  First_Len : Integer;
                  Tidx : Integer;
                  Typ2 : Integer := TY_INTEGER;
               begin
                  First_Len := Tok_Len;
                  for I in 1 .. Tok_Len loop
                     First_Ident (I) := Tok_Val (I);
                  end loop;
                  Next_Token;
                  if Tok = TK_DOT then
                     while Tok = TK_DOT loop
                        Next_Token;
                        if Tok = TK_IDENT or Tok = TK_INTEGER or Tok = TK_CHARACTER then
                           if Tok_Eq_CI ("File_Type") then
                              Is_File_Type := True;
                           end if;
                           Next_Token;
                        end if;
                     end loop;
                     if Is_File_Type then
                        if Is_Const then
                           Add_Sym_Named (Var_Name, Var_Len, SK_CONST, TY_INTEGER);
                        else
                           Add_Sym_Named (Var_Name, Var_Len, SK_VAR, TY_INTEGER);
                        end if;
                        N := New_Node (D_VAR_FILE);
                        N_Str_Off (N) := Pool_Str (Var_Name, Var_Len);
                        N_Str_Len (N) := Var_Len;
                        if Tok = TK_ASSIGN then
                           Next_Token;
                           while Tok /= TK_SEMI and Tok /= TK_EOF loop
                              Next_Token;
                           end loop;
                        end if;
                        Expect (TK_SEMI);
                        return N;
                     end if;
                     -- Non-file dotted type: treat as int
                     if Is_Const then
                        Add_Sym_Named (Var_Name, Var_Len, SK_CONST, TY_INTEGER);
                     else
                        Add_Sym_Named (Var_Name, Var_Len, SK_VAR, TY_INTEGER);
                     end if;
                     N := New_Node (D_VAR_DOTTED);
                     N_Str_Off (N) := Pool_Str (Var_Name, Var_Len);
                     N_Str_Len (N) := Var_Len;
                     if Is_Const then N_Op (N) := 1; else N_Op (N) := 0; end if;
                     if Tok = TK_ASSIGN then
                        Next_Token;
                        N_Left (N) := Parse_Expression_AST;
                     end if;
                     Expect (TK_SEMI);
                     return N;
                  end if;
                  -- Not dotted: First_Ident is the type name
                  Tidx := Find_Sym (First_Ident, First_Len);
                  if Tidx > 0 and then Sym_Kind (Tidx) = SK_TYPE then
                     Typ2 := Sym_Type (Tidx);
                  end if;
                  if Is_Const then
                     Add_Sym_Named (Var_Name, Var_Len, SK_CONST, Typ2);
                  else
                     Add_Sym_Named (Var_Name, Var_Len, SK_VAR, Typ2);
                  end if;
                  -- A constrained integer subtype carries its range to the var.
                  if Tidx > 0 and then Sym_Has_Range (Tidx) = 1 then
                     Sym_Has_Range (Sym_Count) := 1;
                     Sym_Range_Lo (Sym_Count) := Sym_Range_Lo (Tidx);
                     Sym_Range_Hi (Sym_Count) := Sym_Range_Hi (Tidx);
                  end if;
                  N := New_Node (D_VAR_SIMPLE);
                  N_Str_Off (N) := Pool_Str (Var_Name, Var_Len);
                  N_Str_Len (N) := Var_Len;
                  N_Int (N) := Typ2;
                  if Is_Const then N_Op (N) := 1; else N_Op (N) := 0; end if;
                  N_Aux1 (N) := Sym_Has_Range (Sym_Count);
                  N_Aux2 (N) := Sym_Range_Lo (Sym_Count);
                  N_Right (N) := Sym_Range_Hi (Sym_Count);
                  if Tok = TK_ASSIGN then
                     Next_Token;
                     N_Left (N) := Parse_Expression_AST;
                  end if;
                  Expect (TK_SEMI);
                  return N;
               end;
            end if;

            -- Generic typed variable (Integer/Character/Boolean keyword),
            -- with an optional `range L .. H` constraint on Integer.
            -- Natural / Positive carry their implicit range (an explicit
            -- range wins).
            declare
               Base_Tok : Integer := Tok;
               Rlo   : Integer := 0;
               Rhi   : Integer := 0;
               Has_R : Boolean := False;
            begin
               Typ := Parse_Type_Ref;
               if Typ = TY_INTEGER and then Tok = TK_RANGE then
                  Next_Token;
                  Rlo := Parse_Range_Bound;
                  Expect (TK_DOTDOT);
                  Rhi := Parse_Range_Bound;
                  Has_R := True;
               elsif Base_Tok = TK_NATURAL then
                  Has_R := True; Rlo := 0; Rhi := 2147483647;
               elsif Base_Tok = TK_POSITIVE then
                  Has_R := True; Rlo := 1; Rhi := 2147483647;
               end if;
               if Is_Const then
                  Add_Sym_Named (Var_Name, Var_Len, SK_CONST, Typ);
               else
                  Add_Sym_Named (Var_Name, Var_Len, SK_VAR, Typ);
               end if;
               if Has_R then
                  Sym_Has_Range (Sym_Count) := 1;
                  Sym_Range_Lo (Sym_Count) := Rlo;
                  Sym_Range_Hi (Sym_Count) := Rhi;
               end if;
               N := New_Node (D_VAR_SIMPLE);
               N_Str_Off (N) := Pool_Str (Var_Name, Var_Len);
               N_Str_Len (N) := Var_Len;
               N_Int (N) := Typ;
               if Is_Const then N_Op (N) := 1; else N_Op (N) := 0; end if;
               N_Aux1 (N) := Sym_Has_Range (Sym_Count);
               N_Aux2 (N) := Sym_Range_Lo (Sym_Count);
               N_Right (N) := Sym_Range_Hi (Sym_Count);
               if Tok = TK_ASSIGN then
                  Next_Token;
                  N_Left (N) := Parse_Expression_AST;
               end if;
               Expect (TK_SEMI);
               return N;
            end;
         end if;

         -- Not a declaration we recognise — signal "stop".
         return 0;
   end Parse_Declaration_AST;

   -- Public wrapper: loop, building one declaration at a time, walking
   -- variable-leaf nodes, resetting the pool. Type definitions and
   -- procedure / function declarations direct-emit during parse.
   procedure Parse_Declarations is
      N : Integer;
   begin
      while Tok = TK_TYPE or Tok = TK_SUBTYPE or Tok = TK_PROCEDURE
            or Tok = TK_FUNCTION or Tok = TK_IDENT or Tok = TK_PACKAGE
      loop
         N := Parse_Declaration_AST;
         if N /= 0 then
            Emit_Declaration_AST (N);
         end if;
         Reset_AST;
      end loop;
   end Parse_Declarations;

   -- Build a chain of variable-declaration nodes for a `declare` block.
   -- No reset — the chain is part of the enclosing unit's tree. Type
   -- definitions (no node) still register their symbol as a side effect.
   function Parse_Var_Decl_Chain return Integer is
      Head : Integer := 0;
      Prev : Integer := 0;
      D    : Integer;
   begin
      while Tok = TK_TYPE or Tok = TK_SUBTYPE or Tok = TK_PROCEDURE
            or Tok = TK_FUNCTION or Tok = TK_IDENT or Tok = TK_PACKAGE
      loop
         D := Parse_Declaration_AST;
         if D /= 0 then
            if Head = 0 then
               Head := D;
            else
               N_Next (Prev) := D;
            end if;
            Prev := D;
         end if;
      end loop;
      return Head;
   end Parse_Var_Decl_Chain;

   procedure Emit_Declaration_Chain (Head : Integer) is
      N : Integer;
   begin
      N := Head;
      while N /= 0 loop
         Emit_Declaration_AST (N);
         N := N_Next (N);
      end loop;
   end Emit_Declaration_Chain;

   procedure Parse_Context is
   begin
      while Tok = TK_WITH or Tok = TK_USE loop
         declare
            Is_With : Boolean := (Tok = TK_WITH);
            Nm : Tok_Buffer;
            NL : Integer;
         begin
            Next_Token;
            if Is_With and then Tok = TK_IDENT then
               NL := Tok_Len;
               for I in 1 .. Tok_Len loop
                  Nm (I) := Tok_Val (I);
               end loop;
               Next_Token;
               -- Simple `with Name;` -> user package; dotted `with Ada.X;`
               -- is a builtin and is ignored.
               if Tok /= TK_DOT and then With_Count < 32 then
                  With_Count := With_Count + 1;
                  for I in 1 .. NL loop
                     With_Buf (With_Count) (I) := Nm (I);
                  end loop;
                  With_NLen (With_Count) := NL;
               end if;
            end if;
            if not Is_With and then Tok = TK_IDENT and then Tok_Eq_CI ("Ada") then
               -- `use Ada.Text_IO;` makes the Text_IO builtins visible bare.
               Next_Token;
               if Tok = TK_DOT then
                  Next_Token;
                  if Tok = TK_IDENT and then Tok_Eq_CI ("Text_IO") then
                     Use_Text_IO := True;
                  end if;
               end if;
            end if;
            while Tok /= TK_SEMI and Tok /= TK_EOF loop
               Next_Token;
            end loop;
            if Tok = TK_SEMI then Next_Token; end if;
         end;
      end loop;
   end Parse_Context;

   procedure Emit_Int_To_Str is
   begin
      Emit_Ln ("static char *int_to_str(int n) {");
      Emit_Ln ("    static char buf[20];");
      Emit_Ln ("    sprintf(buf, ""%d"", n);");
      Emit_Ln ("    return buf;");
      Emit_Ln ("}");
      Emit_Ln ("");
   end Emit_Int_To_Str;

   -- A library-level package unit (separate compilation):
   --   spec  package P is <specs> end P;  -> a .h of prototypes
   --   body  package body P is <bodies> end P; -> a .c of definitions
   procedure Parse_Package_Unit is
      PName : Tok_Buffer;
      PLen  : Integer;
      Psym  : Integer;
      Is_Body : Boolean := False;
   begin
      Next_Token;   -- consume 'package'
      if Tok = TK_IDENT and then Tok_Eq_CI ("body") then
         Is_Body := True;
         Next_Token;
      end if;
      PLen := Tok_Len;
      for I in 1 .. Tok_Len loop
         PName (I) := Tok_Val (I);
      end loop;
      Add_Sym (SK_PACKAGE, 0);
      Psym := Sym_Count;
      Next_Token;
      Expect (TK_IS);
      Cur_Pkg := Psym + 1;

      if Is_Body then
         Emit_Ln ("#include <stdio.h>");
         Emit_Ln ("#include <stdlib.h>");
         Emit_Ln ("#include <string.h>");
         Emit ("#include """); Emit_Lower (PName, PLen); Emit_Ln (".h""");
         Emit_With_Includes;
         Emit_Ln ("");
         Emit_Int_To_Str;
         Push_Scope;
         Parse_Declarations;
         Pop_Scope;
      else
         Emit ("#ifndef "); Emit_Upper (PName, PLen); Emit_Ln ("_H");
         Emit ("#define "); Emit_Upper (PName, PLen); Emit_Ln ("_H");
         Emit_Ln ("#include ""ada_runtime.h""");
         Emit_With_Includes;
         Emit_Ln ("");
         Push_Scope;
         Parse_Declarations;
         Pop_Scope;
         Emit_Ln ("#endif");
      end if;

      Cur_Pkg := 0;
      if Tok = TK_BEGIN then
         Error ("package initialization (begin) not supported");
      end if;
      Expect (TK_END);
      if Tok = TK_IDENT then Next_Token; end if;
      Expect (TK_SEMI);
   end Parse_Package_Unit;

   procedure Parse_Program is
   begin
      Parse_Context;

      if Tok = TK_PACKAGE then
         Parse_Package_Unit;
         return;
      end if;

      Expect (TK_PROCEDURE);
      Next_Token;
      Expect (TK_IS);

      Emit_Ln ("#include <stdio.h>");
      Emit_Ln ("#include <stdlib.h>");
      Emit_Ln ("#include <string.h>");
      Emit_Ln ("#include ""ada_runtime.h""");
      Emit_With_Includes;
      Emit_Ln ("");
      Emit_Int_To_Str;

      Push_Scope;
      Parse_Declarations;

      Emit_Ln ("int main(int argc, char **argv) {");
      Indent_Level := Indent_Level + 1;
      Expect (TK_BEGIN);
      In_Main_Proc := 1;
      Parse_Statements;
      In_Main_Proc := 0;
      Emit_Indent;
      Emit_Ln ("return 0;");
      Indent_Level := Indent_Level - 1;
      Emit_Ln ("}");

      Expect (TK_END);
      if Tok = TK_IDENT then Next_Token; end if;
      Expect (TK_SEMI);
      Pop_Scope;
   end Parse_Program;

begin
   if Ada.Command_Line.Argument_Count < 2 then
      Ada.Text_IO.Put_Line ("Usage: adacomp <input.adb> <output.c>");
      return;
   end if;

   Src_Name := Ada.Command_Line.Argument (1);
   Read_Source (Ada.Command_Line.Argument (1));
   Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File,
                        Ada.Command_Line.Argument (2));

   Seed_Predefined_Exceptions;
   Next_Token;
   Parse_Program;

   Ada.Text_IO.Close (Out_File);
   Ada.Text_IO.Put_Line ("Compilation successful.");
end Adacomp;
