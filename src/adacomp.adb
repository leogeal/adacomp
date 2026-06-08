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

   -- Source buffer
   type Source_Buf is array (1 .. 200000) of Character;
   Src      : Source_Buf;
   Src_Len  : Integer := 0;
   Src_Pos  : Integer := 1;
   Line_Num : Integer := 1;

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

   -- Type kinds
   TY_INTEGER   : constant Integer := 1;
   TY_CHARACTER : constant Integer := 2;
   TY_BOOLEAN   : constant Integer := 3;
   TY_ARRAY     : constant Integer := 4;
   TY_STRING    : constant Integer := 5;

   -- Symbol table (flat arrays)
   type Int_Store is array (1 .. 2000) of Integer;
   -- Symbol names stored as offset+length into a name pool
   type Name_Pool_Buf is array (1 .. 64000) of Character;
   Name_Pool         : Name_Pool_Buf;
   Name_Pool_Len     : Integer := 0;
   Sym_Name_Off      : Int_Store;
   Sym_Name_Len      : Int_Store;
   Sym_Kind          : Int_Store;
   Sym_Type          : Int_Store;
   Sym_Arr_Lo        : Int_Store;
   Sym_Arr_Hi        : Int_Store;
   Sym_Arr_El        : Int_Store;
   Sym_Arr_Inner_Lo  : Int_Store;
   Sym_Arr_Inner_Hi  : Int_Store;
   Sym_Count         : Integer := 0;

   -- Scope stack
   type Scope_Buf is array (1 .. 64) of Integer;
   Scope_Saved : Scope_Buf;
   Scope_Depth : Integer := 0;

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

   -- Node storage as parallel arrays
   type Node_Store is array (1 .. 10000) of Integer;
   N_Kind    : Node_Store;
   N_Op      : Node_Store;
   N_Int     : Node_Store;  -- literal value, sym index, or sub-name length for DOTTED
   N_Str_Off : Node_Store;  -- offset into NPool
   N_Str_Len : Node_Store;
   N_Left    : Node_Store;  -- primary operand
   N_Right   : Node_Store;  -- BINARY rhs / INDEX rhs
   N_Arg2    : Node_Store;  -- INDEX2 second index / DOTTED sub-name offset
   N_First   : Node_Store;  -- arg list head for CALL / DOTTED
   N_Next    : Node_Store;  -- sibling pointer in arg lists
   N_Line    : Node_Store;
   N_Count   : Integer := 1;  -- index 0 reserved; allocations start at 1

   -- Character pool for AST names and string literals
   type NPool_Buf is array (1 .. 200000) of Character;
   NPool     : NPool_Buf;
   NPool_Len : Integer := 0;

   -- Helper: lowercase character
   function To_Lower (C : Character) return Character is
   begin
      if C >= 'A' and C <= 'Z' then
         return Character'Val (Character'Pos (C) + 32);
      end if;
      return C;
   end To_Lower;

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

   procedure Error (Msg : String) is
   begin
      Ada.Text_IO.Put ("Error at line ");
      Ada.Text_IO.Put (Integer'Image (Line_Num));
      Ada.Text_IO.Put (": ");
      Ada.Text_IO.Put_Line (Msg);
      raise Program_Error;
   end Error;

   procedure Read_Source (Name : String) is
      F  : Ada.Text_IO.File_Type;
      Ch : Character;
   begin
      Ada.Text_IO.Open (F, Ada.Text_IO.In_File, Name);
      Src_Len := 0;
      while not Ada.Text_IO.End_Of_File (F) loop
         Ada.Text_IO.Get (F, Ch);
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
      if Tok_Eq_CI ("array") then return TK_ARRAY; end if;
      if Tok_Eq_CI ("of") then return TK_OF; end if;
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
      if Tok_Eq_CI ("Integer") then return TK_INTEGER; end if;
      if Tok_Eq_CI ("Natural") then return TK_INTEGER; end if;
      if Tok_Eq_CI ("Positive") then return TK_INTEGER; end if;
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
         elsif C = '=' then Tok := TK_EQ;
         elsif C = '&' then Tok := TK_AMP;
         elsif C = ''' then Tok := TK_TICK;
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

   procedure Add_Sym (Kind : Integer; Typ : Integer) is
   begin
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
   end Add_Sym;

   procedure Add_Sym_Named (Buf : Tok_Buffer; BLen : Integer; Kind : Integer; Typ : Integer) is
   begin
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
   end Add_Sym_Named;

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
      N_Count := 1;
      NPool_Len := 0;
   end Reset_AST;

   function New_Node (Kind : Integer) return Integer is
      N : Integer;
   begin
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
      N_Line (N) := Line_Num;
      return N;
   end New_Node;

   function Pool_Str (Buf : Tok_Buffer; Len : Integer) return Integer is
      Off : Integer;
   begin
      Off := NPool_Len + 1;
      for I in 1 .. Len loop
         NPool_Len := NPool_Len + 1;
         NPool (NPool_Len) := Buf (I);
      end loop;
      return Off;
   end Pool_Str;

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

   -- Forward declarations
   procedure Parse_Expression;
   procedure Parse_Statements;
   procedure Parse_Declarations;
   function  Parse_Expression_AST return Integer;
   function  Parse_Comparison_AST return Integer;
   function  Parse_Term_AST return Integer;
   function  Parse_Factor_AST return Integer;
   function  Parse_Primary_AST return Integer;
   procedure Emit_Expression_AST (N : Integer);

   -- Parse type reference
   function Parse_Type_Ref return Integer is
   begin
      if Tok = TK_INTEGER then
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
      if Tok = TK_LPAREN then
         -- Parens contribute no node; the inner expression carries through.
         Next_Token;
         N := Parse_Expression_AST;
         Expect (TK_RPAREN);
         return N;
      end if;
      if Tok = TK_INTEGER or Tok = TK_CHARACTER or Tok = TK_BOOLEAN then
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
            -- Variable-prefix attribute: S'Length, S'First, S'Last
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
               N_Str_Off (N) := Pool_Str (Saved, Saved_Len);
               N_Str_Len (N) := Saved_Len;
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
            -- Array indexing, possibly chained for 2D
            Next_Token;
            N := New_Node (A_INDEX);
            N_Str_Off (N) := Pool_Str (Saved, Saved_Len);
            N_Str_Len (N) := Saved_Len;
            N_Int (N) := Sym_Idx;
            N_Right (N) := Parse_Expression_AST;
            Expect (TK_RPAREN);
            if Tok = TK_LPAREN and then Sym_Idx > 0
               and then Sym_Arr_Inner_Hi (Sym_Idx) /= 0
            then
               Next_Token;
               N_Kind (N) := A_INDEX2;
               N_Arg2 (N) := Parse_Expression_AST;
               Expect (TK_RPAREN);
            end if;
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

         -- Simple variable, or parameterless function call.
         N := New_Node (A_IDENT);
         N_Str_Off (N) := Pool_Str (Saved, Saved_Len);
         N_Str_Len (N) := Saved_Len;
         N_Int (N) := Sym_Idx;
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

   procedure Emit_Expression_AST (N : Integer) is
      Kind : Integer;
      C : Character;
      Sym_Idx : Integer;
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
         Sym_Idx := N_Int (N);
         if Sym_Idx > 0 and then Sym_Kind (Sym_Idx) = SK_FUNC then
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
         Emit_Expression_AST (N_Right (N));
         Sym_Idx := N_Int (N);
         if Sym_Idx > 0 then
            Emit (" - ");
            Emit_Int (Sym_Arr_Lo (Sym_Idx));
         else
            Emit (" - 1");
         end if;
         Emit ("]");
      elsif Kind = A_INDEX2 then
         Sym_Idx := N_Int (N);
         Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
         Emit ("[");
         Emit_Expression_AST (N_Right (N));
         Emit (" - "); Emit_Int (Sym_Arr_Lo (Sym_Idx));
         Emit ("][");
         Emit_Expression_AST (N_Arg2 (N));
         Emit (" - "); Emit_Int (Sym_Arr_Inner_Lo (Sym_Idx));
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
            Emit ("int_to_str(");
            Emit_Expression_AST (N_Left (N));
            Emit (")");
         elsif N_Op (N) = ATTR_POS then
            Emit ("((int)(");
            Emit_Expression_AST (N_Left (N));
            Emit ("))");
         elsif N_Op (N) = ATTR_VAL then
            Emit ("((char)(");
            Emit_Expression_AST (N_Left (N));
            Emit ("))");
         end if;
      elsif Kind = A_ATTR_VAR then
         if N_Op (N) = ATTR_LENGTH or N_Op (N) = ATTR_LAST then
            Emit ("(int)strlen(");
            Emit_Pool_Lower (N_Str_Off (N), N_Str_Len (N));
            Emit (")");
         elsif N_Op (N) = ATTR_FIRST then
            Emit ("1");
         end if;
      elsif Kind = A_DOTTED then
         Sub_Off := N_Arg2 (N);
         Sub_Len := N_Int (N);
         if NPool_Eq_CI (Sub_Off, Sub_Len, "Argument_Count") then
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

   procedure Parse_Statement is
      Saved : Tok_Buffer;
      Saved_Len : Integer;
      Sym_Idx : Integer;
      Sub : Tok_Buffer;
      Sub_Len : Integer;
   begin
      if Tok = TK_NULL then
         Emit_Indent; Emit_Ln ("/* null */;");
         Next_Token; Expect (TK_SEMI);

      elsif Tok = TK_RETURN then
         Emit_Indent; Emit ("return");
         Next_Token;
         if Tok /= TK_SEMI then
            Emit (" "); Parse_Expression;
         elsif In_Main_Proc = 1 then
            Emit (" 0");
         end if;
         Emit_Ln (";"); Expect (TK_SEMI);

      elsif Tok = TK_RAISE then
         Next_Token;
         Emit_Indent;
         Emit ("{ fprintf(stderr, ""Exception raised at line %d\n"", ");
         Emit_Int (Line_Num);
         Emit_Ln ("); exit(1); }");
         while Tok /= TK_SEMI and Tok /= TK_EOF loop
            Next_Token;
         end loop;
         Expect (TK_SEMI);

      elsif Tok = TK_EXIT then
         Next_Token;
         if Tok = TK_WHEN then
            Emit_Indent; Emit ("if (");
            Next_Token; Parse_Expression;
            Emit_Ln (") break;");
         else
            Emit_Indent; Emit_Ln ("break;");
         end if;
         Expect (TK_SEMI);

      elsif Tok = TK_IF then
         Emit_Indent; Emit ("if (");
         Next_Token; Parse_Expression;
         Emit_Ln (") {"); Expect (TK_THEN);
         Indent_Level := Indent_Level + 1;
         Parse_Statements;
         Indent_Level := Indent_Level - 1;
         while Tok = TK_ELSIF loop
            Emit_Indent; Emit ("} else if (");
            Next_Token; Parse_Expression;
            Emit_Ln (") {"); Expect (TK_THEN);
            Indent_Level := Indent_Level + 1;
            Parse_Statements;
            Indent_Level := Indent_Level - 1;
         end loop;
         if Tok = TK_ELSE then
            Emit_Indent; Emit_Ln ("} else {");
            Next_Token;
            Indent_Level := Indent_Level + 1;
            Parse_Statements;
            Indent_Level := Indent_Level - 1;
         end if;
         Emit_Indent; Emit_Ln ("}");
         Expect (TK_END); Expect (TK_IF); Expect (TK_SEMI);

      elsif Tok = TK_WHILE then
         Emit_Indent; Emit ("while (");
         Next_Token; Parse_Expression;
         Emit_Ln (") {"); Expect (TK_LOOP);
         Indent_Level := Indent_Level + 1;
         Parse_Statements;
         Indent_Level := Indent_Level - 1;
         Emit_Indent; Emit_Ln ("}");
         Expect (TK_END); Expect (TK_LOOP); Expect (TK_SEMI);

      elsif Tok = TK_LOOP then
         Emit_Indent; Emit_Ln ("while (1) {");
         Next_Token;
         Indent_Level := Indent_Level + 1;
         Parse_Statements;
         Indent_Level := Indent_Level - 1;
         Emit_Indent; Emit_Ln ("}");
         Expect (TK_END); Expect (TK_LOOP); Expect (TK_SEMI);

      elsif Tok = TK_FOR then
         Next_Token;
         Saved_Len := Tok_Len;
         for I in 1 .. Tok_Len loop
            Saved (I) := Tok_Val (I);
         end loop;
         Next_Token;
         Expect (TK_IN);
         declare
            Is_Reverse : Boolean := False;
         begin
            if Tok = TK_REVERSE then
               Is_Reverse := True;
               Next_Token;
            end if;
            Emit_Indent;
            if Is_Reverse then
               -- Wrap in a block so __lo/__hi temps scope-shadow when nested.
               Emit ("{ int __lo = ");
               Parse_Expression;
               Expect (TK_DOTDOT);
               Emit ("; int __hi = ");
               Parse_Expression;
               Emit ("; for (int ");
               Emit_Lower (Saved, Saved_Len);
               Emit (" = __hi; ");
               Emit_Lower (Saved, Saved_Len);
               Emit (" >= __lo; ");
               Emit_Lower (Saved, Saved_Len);
               Emit_Ln ("--) {");
            else
               Emit ("for (int ");
               Emit_Lower (Saved, Saved_Len);
               Emit (" = ");
               Parse_Expression;
               Expect (TK_DOTDOT);
               Emit ("; ");
               Emit_Lower (Saved, Saved_Len);
               Emit (" <= ");
               Parse_Expression;
               Emit ("; ");
               Emit_Lower (Saved, Saved_Len);
               Emit_Ln ("++) {");
            end if;
            Expect (TK_LOOP);
            Indent_Level := Indent_Level + 1;
            Parse_Statements;
            Indent_Level := Indent_Level - 1;
            Emit_Indent;
            if Is_Reverse then
               Emit_Ln ("} }");
            else
               Emit_Ln ("}");
            end if;
            Expect (TK_END); Expect (TK_LOOP); Expect (TK_SEMI);
         end;

      elsif Tok = TK_DECLARE then
         Next_Token;
         Emit_Indent; Emit_Ln ("{");
         Indent_Level := Indent_Level + 1;
         Parse_Declarations;
         Expect (TK_BEGIN);
         Parse_Statements;
         Indent_Level := Indent_Level - 1;
         Emit_Indent; Emit_Ln ("}");
         Expect (TK_END); Expect (TK_SEMI);

      elsif Tok = TK_BEGIN then
         Next_Token;
         Emit_Indent; Emit_Ln ("{");
         Indent_Level := Indent_Level + 1;
         Parse_Statements;
         Indent_Level := Indent_Level - 1;
         Emit_Indent; Emit_Ln ("}");
         Expect (TK_END); Expect (TK_SEMI);

      elsif Tok = TK_IDENT then
         Saved_Len := Tok_Len;
         for I in 1 .. Tok_Len loop
            Saved (I) := Tok_Val (I);
         end loop;
         Sym_Idx := Find_Sym (Tok_Val, Tok_Len);
         Next_Token;

         if Tok = TK_ASSIGN then
            Emit_Indent;
            Emit_Lower (Saved, Saved_Len);
            Emit (" = "); Next_Token;
            Parse_Expression;
            Emit_Ln (";"); Expect (TK_SEMI);

         elsif Tok = TK_LPAREN then
            Next_Token;
            if Sym_Idx > 0 and then (Sym_Kind (Sym_Idx) = SK_PROC or Sym_Kind (Sym_Idx) = SK_FUNC) then
               Emit_Indent;
               Emit_Lower (Saved, Saved_Len);
               Emit ("(");
               if Tok /= TK_RPAREN then
                  Parse_Expression;
                  while Tok = TK_COMMA loop
                     Emit (", "); Next_Token;
                     Parse_Expression;
                  end loop;
               end if;
               Emit_Ln (");");
               Expect (TK_RPAREN); Expect (TK_SEMI);
            elsif Sym_Idx > 0
                  and then (Sym_Kind (Sym_Idx) = SK_VAR or Sym_Kind (Sym_Idx) = SK_PARAM)
                  and then Sym_Type (Sym_Idx) = TY_ARRAY
            then
               Emit_Indent;
               Emit_Lower (Saved, Saved_Len);
               Emit ("[");
               Parse_Expression;
               Emit (" - ");
               Emit_Int (Sym_Arr_Lo (Sym_Idx));
               Emit ("]");
               Expect (TK_RPAREN);
               if Tok = TK_LPAREN and Sym_Arr_Inner_Hi (Sym_Idx) /= 0 then
                  Next_Token;
                  Emit ("[");
                  Parse_Expression;
                  Emit (" - ");
                  Emit_Int (Sym_Arr_Inner_Lo (Sym_Idx));
                  Emit ("]");
                  Expect (TK_RPAREN);
               end if;
               Expect (TK_ASSIGN);
               Emit (" = ");
               Parse_Expression;
               Emit_Ln (";"); Expect (TK_SEMI);
            else
               -- Treat as call
               Emit_Indent;
               Emit_Lower (Saved, Saved_Len);
               Emit ("(");
               if Tok /= TK_RPAREN then
                  Parse_Expression;
                  while Tok = TK_COMMA loop
                     Emit (", "); Next_Token;
                     Parse_Expression;
                  end loop;
               end if;
               Emit_Ln (");");
               Expect (TK_RPAREN); Expect (TK_SEMI);
            end if;

         elsif Tok = TK_DOT then
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
            Emit_Indent;
            if Name_Eq (Sub, Sub_Len, "Put_Line") then
               Expect (TK_LPAREN);
               if Has_Arg_Separator_Ahead then
                  Emit ("ada_fput_line(");
                  Parse_Expression;
                  Expect (TK_COMMA); Emit (", ");
                  Parse_Expression;
               else
                  Emit ("ada_put_line(");
                  Parse_Expression;
               end if;
               Emit_Ln (");"); Expect (TK_RPAREN);
            elsif Name_Eq (Sub, Sub_Len, "Put") then
               Expect (TK_LPAREN);
               if Has_Arg_Separator_Ahead then
                  if Second_Arg_Is_Char then
                     Emit ("ada_fput_char(");
                  else
                     Emit ("ada_fput_str(");
                  end if;
                  Parse_Expression;
                  Expect (TK_COMMA); Emit (", ");
                  Parse_Expression;
               else
                  Emit ("ada_put_str(");
                  Parse_Expression;
               end if;
               Emit_Ln (");"); Expect (TK_RPAREN);
            elsif Name_Eq (Sub, Sub_Len, "New_Line") then
               if Tok = TK_LPAREN then
                  Expect (TK_LPAREN);
                  if Tok /= TK_RPAREN then
                     Emit ("ada_fput_newline(");
                     Parse_Expression;
                     Emit_Ln (");");
                  else
                     Emit_Ln ("ada_new_line();");
                  end if;
                  Expect (TK_RPAREN);
               else
                  Emit_Ln ("ada_new_line();");
               end if;
            elsif Name_Eq (Sub, Sub_Len, "Open") then
               Expect (TK_LPAREN);
               Parse_Expression;
               Expect (TK_COMMA);
               while Tok /= TK_COMMA and Tok /= TK_RPAREN and Tok /= TK_EOF loop
                  Next_Token;
                  if Tok = TK_DOT then Next_Token; Next_Token; end if;
               end loop;
               if Tok = TK_COMMA then Next_Token; end if;
               Emit (" = fopen(");
               Parse_Expression;
               Emit (", ""r""");
               Emit_Ln (");"); Expect (TK_RPAREN);
            elsif Name_Eq (Sub, Sub_Len, "Create") then
               Expect (TK_LPAREN);
               Parse_Expression;
               Expect (TK_COMMA);
               while Tok /= TK_COMMA and Tok /= TK_RPAREN and Tok /= TK_EOF loop
                  Next_Token;
                  if Tok = TK_DOT then Next_Token; Next_Token; end if;
               end loop;
               if Tok = TK_COMMA then Next_Token; end if;
               Emit (" = fopen(");
               Parse_Expression;
               Emit (", ""w""");
               Emit_Ln (");"); Expect (TK_RPAREN);
            elsif Name_Eq (Sub, Sub_Len, "Close") then
               Emit ("fclose(");
               Expect (TK_LPAREN); Parse_Expression;
               Emit_Ln (");"); Expect (TK_RPAREN);
            elsif Name_Eq (Sub, Sub_Len, "Get_Line") then
               Emit ("ada_get_line(");
               Expect (TK_LPAREN); Parse_Expression;
               Emit_Ln (");"); Expect (TK_RPAREN);
            elsif Name_Eq (Sub, Sub_Len, "Get") then
               Expect (TK_LPAREN);
               Emit ("{int __gc = fgetc(");
               Parse_Expression;
               Emit ("); if (__gc != EOF) ");
               Expect (TK_COMMA);
               Parse_Expression;
               Emit_Ln (" = (char)__gc;}");
               Expect (TK_RPAREN);
            else
               Emit_Lower (Saved, Saved_Len);
               Emit ("_");
               Emit_Lower (Sub, Sub_Len);
               if Tok = TK_LPAREN then
                  Emit ("("); Next_Token;
                  if Tok /= TK_RPAREN then
                     Parse_Expression;
                     while Tok = TK_COMMA loop
                        Emit (", "); Next_Token;
                        Parse_Expression;
                     end loop;
                  end if;
                  Emit_Ln (");"); Expect (TK_RPAREN);
               else
                  Emit_Ln ("();");
               end if;
            end if;
            Expect (TK_SEMI);

         elsif Tok = TK_SEMI then
            Emit_Indent;
            Emit_Lower (Saved, Saved_Len);
            Emit_Ln ("();");
            Next_Token;

         else
            Error ("expected := or ( after identifier");
         end if;

      else
         Error ("unexpected token in statement");
      end if;
   end Parse_Statement;

   procedure Parse_Statements is
   begin
      while Tok /= TK_END and Tok /= TK_ELSIF and
            Tok /= TK_ELSE and Tok /= TK_EOF and Tok /= TK_WHEN
      loop
         if Tok = TK_IDENT and then Tok_Eq_CI ("exception") then
            Next_Token;
            while Tok /= TK_END and Tok /= TK_EOF loop
               Next_Token;
            end loop;
            return;
         end if;
         Parse_Statement;
      end loop;
   end Parse_Statements;

   procedure Parse_Declarations is
      Var_Name : Tok_Buffer;
      Var_Len  : Integer;
      Typ      : Integer;
      Is_Const : Boolean;
      Handled  : Boolean;
   begin
      while Tok /= TK_BEGIN and Tok /= TK_EOF loop
         if Tok = TK_TYPE then
            Next_Token;
            Add_Sym (SK_TYPE, TY_ARRAY);
            Next_Token;
            Expect (TK_IS);
            if Tok = TK_ARRAY then
               Next_Token;
               Expect (TK_LPAREN);
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
            else
               while Tok /= TK_SEMI and Tok /= TK_EOF loop
                  Next_Token;
               end loop;
            end if;
            Expect (TK_SEMI);

         elsif Tok = TK_PROCEDURE then
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
               Next_Token;
               Emit ("void ");
               Emit_Lower (P_Name, P_Len);
               Emit ("(");
               Push_Scope;
               if Tok = TK_LPAREN then
                  Next_Token;
                  declare
                     First : Boolean := True;
                     Parm : Tok_Buffer;
                     Parm_Len : Integer;
                     Arr_Idx : Integer;
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
                        if Tok = TK_IDENT then
                           Arr_Idx := Find_Sym (Tok_Val, Tok_Len);
                           if Arr_Idx > 0 and then
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

         elsif Tok = TK_FUNCTION then
            Next_Token;
            declare
               F_Name : Tok_Buffer;
               F_Len  : Integer;
               Ret    : Integer;
               P_Names : array (1 .. 20) of Tok_Buffer;
               P_Lens  : array (1 .. 20) of Integer;
               P_Types : array (1 .. 20) of Integer;
               P_El    : array (1 .. 20) of Integer;
               P_Count : Integer := 0;
               Is_Fwd  : Boolean := False;
               Arr_Idx : Integer;
            begin
               F_Len := Tok_Len;
               for I in 1 .. Tok_Len loop
                  F_Name (I) := Tok_Val (I);
               end loop;
               Add_Sym (SK_FUNC, TY_INTEGER);
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
                     if Tok = TK_IDENT then
                        Arr_Idx := Find_Sym (Tok_Val, Tok_Len);
                        if Arr_Idx > 0 and then
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
               Emit_Lower (F_Name, F_Len);
               Emit ("(");
               for I in 1 .. P_Count loop
                  if I > 1 then Emit (", "); end if;
                  if P_Types (I) = TY_ARRAY then
                     Emit_C_Type (P_El (I));
                     Emit (" *");
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

         elsif Tok = TK_IDENT then
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
            Handled := False;

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
                  Emit_Indent;
                  if Is_Const then Emit ("const "); end if;
                  Emit_C_Type (El_Type);
                  Emit (" ");
                  Emit_Lower (Var_Name, Var_Len);
                  Emit ("[");
                  Emit_Int (Hi - Lo + 1);
                  Emit ("]");
                  if Is_Nested then
                     Emit ("[");
                     Emit_Int (Inner_Hi - Inner_Lo + 1);
                     Emit ("]");
                  end if;
                  if Tok = TK_ASSIGN then
                     Next_Token;
                     Emit (" = {0}");
                     while Tok /= TK_SEMI and Tok /= TK_EOF loop
                        Next_Token;
                     end loop;
                  end if;
                  Emit_Ln (";");
                  Expect (TK_SEMI);
                  Handled := True;
               end;
            end if;

            -- Named array type variable
            if not Handled and Tok = TK_IDENT then
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
                     Emit_Indent;
                     Emit_C_Type (Sym_Arr_El (Tidx));
                     Emit (" ");
                     Emit_Lower (Var_Name, Var_Len);
                     Emit ("[");
                     Emit_Int (Sym_Arr_Hi (Tidx) - Sym_Arr_Lo (Tidx) + 1);
                     Emit ("]");
                     Next_Token;
                     if Tok = TK_ASSIGN then
                        Next_Token;
                        Emit (" = {0}");
                        while Tok /= TK_SEMI and Tok /= TK_EOF loop
                           Next_Token;
                        end loop;
                     end if;
                     Emit_Ln (";");
                     Expect (TK_SEMI);
                     Handled := True;
                  end if;
               end;
            end if;

            -- String type variable
            if not Handled and Tok = TK_STRING then
               Next_Token;
               if Is_Const then
                  Add_Sym_Named (Var_Name, Var_Len, SK_CONST, TY_STRING);
               else
                  Add_Sym_Named (Var_Name, Var_Len, SK_VAR, TY_STRING);
               end if;
               Emit_Indent;
               Emit ("const char *");
               Emit_Lower (Var_Name, Var_Len);
               if Tok = TK_ASSIGN then
                  Emit (" = "); Next_Token;
                  Parse_Expression;
               else
                  Emit (" = """"");
               end if;
               Emit_Ln (";");
               Expect (TK_SEMI);
               Handled := True;
            end if;

            -- Dotted type (e.g. Ada.Text_IO.File_Type) or other ident-typed
            if not Handled and Tok = TK_IDENT then
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
                        Emit_Indent;
                        Emit ("FILE *");
                        Emit_Lower (Var_Name, Var_Len);
                        Emit (" = NULL");
                        Emit_Ln (";");
                        if Tok = TK_ASSIGN then
                           Next_Token;
                           while Tok /= TK_SEMI and Tok /= TK_EOF loop
                              Next_Token;
                           end loop;
                        end if;
                        Expect (TK_SEMI);
                        Handled := True;
                     else
                        -- Non-file dotted type: treat as int
                        if Is_Const then
                           Add_Sym_Named (Var_Name, Var_Len, SK_CONST, TY_INTEGER);
                        else
                           Add_Sym_Named (Var_Name, Var_Len, SK_VAR, TY_INTEGER);
                        end if;
                        Emit_Indent;
                        if Is_Const then Emit ("const "); end if;
                        Emit ("int ");
                        Emit_Lower (Var_Name, Var_Len);
                        if Tok = TK_ASSIGN then
                           Emit (" = "); Next_Token;
                           Parse_Expression;
                        else
                           Emit (" = 0");
                        end if;
                        Emit_Ln (";");
                        Expect (TK_SEMI);
                        Handled := True;
                     end if;
                  else
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
                     Emit_Indent;
                     if Is_Const then Emit ("const "); end if;
                     Emit_C_Type (Typ2);
                     Emit (" ");
                     Emit_Lower (Var_Name, Var_Len);
                     if Tok = TK_ASSIGN then
                        Emit (" = "); Next_Token;
                        Parse_Expression;
                     else
                        Emit (" = 0");
                     end if;
                     Emit_Ln (";");
                     Expect (TK_SEMI);
                     Handled := True;
                  end if;
               end;
            end if;

            -- Generic typed variable (Integer, Character, Boolean, etc.)
            if not Handled then
               Typ := Parse_Type_Ref;
               if Is_Const then
                  Add_Sym_Named (Var_Name, Var_Len, SK_CONST, Typ);
               else
                  Add_Sym_Named (Var_Name, Var_Len, SK_VAR, Typ);
               end if;
               Emit_Indent;
               if Is_Const then Emit ("const "); end if;
               Emit_C_Type (Typ);
               Emit (" ");
               Emit_Lower (Var_Name, Var_Len);
               if Tok = TK_ASSIGN then
                  Emit (" = "); Next_Token;
                  Parse_Expression;
               elsif Typ = TY_STRING then
                  Emit (" = """"");
               else
                  Emit (" = 0");
               end if;
               Emit_Ln (";");
               Expect (TK_SEMI);
            end if;

         else
            return;
         end if;
      end loop;
   end Parse_Declarations;

   procedure Parse_Context is
   begin
      while Tok = TK_WITH or Tok = TK_USE loop
         Next_Token;
         while Tok /= TK_SEMI and Tok /= TK_EOF loop
            Next_Token;
         end loop;
         if Tok = TK_SEMI then Next_Token; end if;
      end loop;
   end Parse_Context;

   procedure Parse_Program is
   begin
      Parse_Context;
      Expect (TK_PROCEDURE);
      Next_Token;
      Expect (TK_IS);

      Emit_Ln ("#include <stdio.h>");
      Emit_Ln ("#include <stdlib.h>");
      Emit_Ln ("#include <string.h>");
      Emit_Ln ("#include ""ada_runtime.h""");
      Emit_Ln ("");
      Emit_Ln ("static char *int_to_str(int n) {");
      Emit_Ln ("    static char buf[20];");
      Emit_Ln ("    sprintf(buf, ""%d"", n);");
      Emit_Ln ("    return buf;");
      Emit_Ln ("}");
      Emit_Ln ("");

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

   Read_Source (Ada.Command_Line.Argument (1));
   Ada.Text_IO.Create (Out_File, Ada.Text_IO.Out_File,
                        Ada.Command_Line.Argument (2));

   Next_Token;
   Parse_Program;

   Ada.Text_IO.Close (Out_File);
   Ada.Text_IO.Put_Line ("Compilation successful.");
end Adacomp;
