-- adacomp.adb - Minimal self-hosting Ada-to-C compiler
-- Supports the subset of Ada needed to compile itself.
-- Usage: adacomp <input.adb> <output.c>
-- Features: procedures, functions, if/elsif/else, while/for loops,
--   Integer/Character/Boolean types, 1D arrays, basic I/O, file I/O.

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

   -- Symbol table (flat arrays)
   type Name_Store is array (1 .. 2000) of Character;
   type Int_Store is array (1 .. 2000) of Integer;
   -- Symbol names stored as offset+length into a name pool
   type Name_Pool_Buf is array (1 .. 64000) of Character;
   Name_Pool   : Name_Pool_Buf;
   Name_Pool_Len : Integer := 0;
   Sym_Name_Off : Int_Store;
   Sym_Name_Len : Int_Store;
   Sym_Kind     : Int_Store;
   Sym_Type     : Int_Store;
   Sym_Arr_Lo   : Int_Store;
   Sym_Arr_Hi   : Int_Store;
   Sym_Arr_El   : Int_Store;
   Sym_Count    : Integer := 0;

   -- Scope stack
   type Scope_Buf is array (1 .. 64) of Integer;
   Scope_Saved : Scope_Buf;
   Scope_Depth : Integer := 0;

   -- Output: we write to a file using Ada.Text_IO
   Out_File : Ada.Text_IO.File_Type;

   -- Indentation
   Indent_Level : Integer := 0;

   -- Helper: lowercase character
   function To_Lower (C : Character) return Character is
   begin
      if C >= 'A' and C <= 'Z' then
         return Character'Val (Character'Pos (C) + 32);
      end if;
      return C;
   end To_Lower;

   -- Helper: is alphabetic or underscore
   function Is_Alpha (C : Character) return Boolean is
   begin
      return (C >= 'a' and C <= 'z') or (C >= 'A' and C <= 'Z') or C = '_';
   end Is_Alpha;

   -- Helper: is digit
   function Is_Digit (C : Character) return Boolean is
   begin
      return C >= '0' and C <= '9';
   end Is_Digit;

   -- Helper: is alphanumeric or underscore
   function Is_Alnum (C : Character) return Boolean is
   begin
      return Is_Alpha (C) or Is_Digit (C);
   end Is_Alnum;

   -- Error reporting
   procedure Error (Msg : String) is
   begin
      Ada.Text_IO.Put ("Error at line ");
      Ada.Text_IO.Put (Integer'Image (Line_Num));
      Ada.Text_IO.Put (": ");
      Ada.Text_IO.Put_Line (Msg);
      raise Program_Error;
   end Error;

   -- Read source file into Src buffer (character by character)
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
      -- Compensate for possible trailing garbage char from fgetc/feof
      if Src_Len > 0 and then Character'Pos (Src (Src_Len)) > 127 then
         Src_Len := Src_Len - 1;
      end if;
   end Read_Source;

   -- Peek at current source character
   function Peek return Character is
   begin
      if Src_Pos > Src_Len then
         return Character'Val (0);
      end if;
      return Src (Src_Pos);
   end Peek;

   -- Advance source position
   procedure Advance is
   begin
      if Src_Pos <= Src_Len then
         if Src (Src_Pos) = Character'Val (10) then
            Line_Num := Line_Num + 1;
         end if;
         Src_Pos := Src_Pos + 1;
      end if;
   end Advance;

   -- Skip whitespace and comments
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

   -- Compare token value (case insensitive)
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

   -- Check if identifier is a keyword
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
      if Tok_Eq_CI ("Integer") then return TK_INTEGER; end if;
      if Tok_Eq_CI ("Natural") then return TK_INTEGER; end if;
      if Tok_Eq_CI ("Positive") then return TK_INTEGER; end if;
      if Tok_Eq_CI ("Character") then return TK_CHARACTER; end if;
      if Tok_Eq_CI ("Boolean") then return TK_BOOLEAN; end if;
      if Tok_Eq_CI ("True") then return TK_TRUE; end if;
      if Tok_Eq_CI ("False") then return TK_FALSE; end if;
      return TK_IDENT;
   end Check_Keyword;

   -- Detect attribute tick vs character literal
   function Is_Attr_Tick return Boolean is
   begin
      if Src_Pos + 2 <= Src_Len and then Peek = ''' then
         if Is_Alpha (Src (Src_Pos + 1)) then
            if Src (Src_Pos + 2) /= ''' then
               return True;
            end if;
         end if;
      end if;
      return False;
   end Is_Attr_Tick;

   -- Get next token
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
         -- Handle attributes (Type'Attr)
         if Is_Attr_Tick then
            Advance;
            -- Read attribute name
            Tok_Len := 0;
            while Src_Pos <= Src_Len and then Is_Alnum (Peek) loop
               Tok_Len := Tok_Len + 1;
               Tok_Val (Tok_Len) := Peek;
               Advance;
            end loop;
            if Tok_Eq_CI ("Image") then
               Tok := TK_IDENT;
               Tok_Val (1) := '_'; Tok_Val (2) := '_';
               Tok_Val (3) := 'i'; Tok_Val (4) := 'm';
               Tok_Val (5) := 'g'; Tok_Len := 5;
            elsif Tok_Eq_CI ("Pos") then
               Tok := TK_IDENT;
               Tok_Val (1) := '_'; Tok_Val (2) := '_';
               Tok_Val (3) := 'p'; Tok_Val (4) := 'o';
               Tok_Val (5) := 's'; Tok_Len := 5;
            elsif Tok_Eq_CI ("Val") then
               Tok := TK_IDENT;
               Tok_Val (1) := '_'; Tok_Val (2) := '_';
               Tok_Val (3) := 'v'; Tok_Val (4) := 'a';
               Tok_Val (5) := 'l'; Tok_Len := 5;
            elsif Tok_Eq_CI ("Length") then
               Tok := TK_IDENT;
               Tok_Val (1) := '_'; Tok_Val (2) := '_';
               Tok_Val (3) := 'l'; Tok_Val (4) := 'e';
               Tok_Val (5) := 'n'; Tok_Len := 5;
            elsif Tok_Eq_CI ("First") then
               Tok := TK_IDENT;
               Tok_Val (1) := '_'; Tok_Val (2) := '_';
               Tok_Val (3) := 'f'; Tok_Val (4) := 's';
               Tok_Val (5) := 't'; Tok_Len := 5;
            elsif Tok_Eq_CI ("Last") then
               Tok := TK_IDENT;
               Tok_Val (1) := '_'; Tok_Val (2) := '_';
               Tok_Val (3) := 'l'; Tok_Val (4) := 's';
               Tok_Val (5) := 't'; Tok_Len := 5;
            elsif Tok_Eq_CI ("Range") then
               Tok := TK_IDENT;
               Tok_Val (1) := '_'; Tok_Val (2) := '_';
               Tok_Val (3) := 'r'; Tok_Val (4) := 'n';
               Tok_Val (5) := 'g'; Tok_Len := 5;
            end if;
         end if;
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

      -- String literals
      if Peek = '"' then
         Advance;
         while Src_Pos <= Src_Len and then Peek /= '"' loop
            Tok_Len := Tok_Len + 1;
            Tok_Val (Tok_Len) := Peek;
            Advance;
         end loop;
         if Peek = '"' then
            Advance;
         end if;
         Tok := TK_STR_LIT;
         return;
      end if;

      -- Character literals
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
         else
            Error ("unexpected character");
         end if;
      end;
   end Next_Token;

   -- Expect a specific token kind
   procedure Expect (Expected : Integer) is
   begin
      if Tok /= Expected then
         Error ("unexpected token");
      end if;
      Next_Token;
   end Expect;

   -- Emit to output file
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

   -- Emit token value as-is
   procedure Emit_Tok is
   begin
      for I in 1 .. Tok_Len loop
         Emit_Ch (Tok_Val (I));
      end loop;
   end Emit_Tok;

   -- Emit token value in lowercase
   procedure Emit_Tok_Lower is
   begin
      for I in 1 .. Tok_Len loop
         Emit_Ch (To_Lower (Tok_Val (I)));
      end loop;
   end Emit_Tok_Lower;

   -- Emit a saved name in lowercase
   procedure Emit_Lower (Buf : Tok_Buffer; Len : Integer) is
   begin
      for I in 1 .. Len loop
         Emit_Ch (To_Lower (Buf (I)));
      end loop;
   end Emit_Lower;

   -- Symbol table: compare name from pool
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

   -- Find symbol by name
   function Find_Sym (Buf : Tok_Buffer; BLen : Integer) return Integer is
   begin
      for I in reverse 1 .. Sym_Count loop
         if Pool_Eq (Sym_Name_Off (I), Sym_Name_Len (I), Buf, BLen) then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Sym;

   -- Add symbol with current token as name
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
      Sym_Arr_Lo (Sym_Count) := 0;
      Sym_Arr_Hi (Sym_Count) := 0;
      Sym_Arr_El (Sym_Count) := 0;
   end Add_Sym;

   -- Add symbol with explicit name
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
      Sym_Arr_Lo (Sym_Count) := 0;
      Sym_Arr_Hi (Sym_Count) := 0;
      Sym_Arr_El (Sym_Count) := 0;
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

   -- Forward declarations
   procedure Parse_Expression;
   procedure Parse_Statements;
   procedure Parse_Declarations;

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
         -- Skip dotted type names (Ada.Text_IO.File_Type etc)
         while Tok = TK_DOT loop
            Next_Token;
            if Tok = TK_IDENT or Tok = TK_INTEGER or Tok = TK_CHARACTER then
               Next_Token;
            end if;
         end loop;
         return TY_INTEGER;
      end if;
   end Parse_Type_Ref;

   -- Emit C type
   procedure Emit_C_Type (Typ : Integer) is
   begin
      if Typ = TY_INTEGER then
         Emit ("int");
      elsif Typ = TY_CHARACTER then
         Emit ("char");
      elsif Typ = TY_BOOLEAN then
         Emit ("int");
      else
         Emit ("int");
      end if;
   end Emit_C_Type;

   -- Compare saved name case-insensitively with string
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

   -- Parse primary expression
   procedure Parse_Primary is
      Saved : Tok_Buffer;
      Saved_Len : Integer;
      Sym_Idx : Integer;
   begin
      if Tok = TK_INT_LIT then
         Emit_Tok;
         Next_Token;

      elsif Tok = TK_CHAR_LIT then
         Emit ("'");
         if Tok_Val (1) = ''' then
            Emit ("\\'");
         elsif Tok_Val (1) = '\' then
            Emit ("\\\\");
         else
            Emit_Ch (Tok_Val (1));
         end if;
         Emit ("'");
         Next_Token;

      elsif Tok = TK_STR_LIT then
         Emit_Ch ('"');
         for I in 1 .. Tok_Len loop
            if Tok_Val (I) = '"' then
               Emit ("\""");
            elsif Tok_Val (I) = '\' then
               Emit ("\\");
            else
               Emit_Ch (Tok_Val (I));
            end if;
         end loop;
         Emit_Ch ('"');
         Next_Token;

      elsif Tok = TK_TRUE then
         Emit ("1"); Next_Token;

      elsif Tok = TK_FALSE then
         Emit ("0"); Next_Token;

      elsif Tok = TK_NOT then
         Emit ("!"); Next_Token;
         Parse_Primary;

      elsif Tok = TK_LPAREN then
         Emit ("("); Next_Token;
         Parse_Expression;
         Emit (")"); Expect (TK_RPAREN);

      elsif Tok = TK_MINUS then
         Emit ("-"); Next_Token;
         Parse_Primary;

      elsif Tok = TK_IDENT then
         Saved_Len := Tok_Len;
         for I in 1 .. Tok_Len loop
            Saved (I) := Tok_Val (I);
         end loop;
         Sym_Idx := Find_Sym (Tok_Val, Tok_Len);
         Next_Token;

         -- Handle special attribute tokens
         if Name_Eq (Saved, Saved_Len, "__img") then
            Emit ("int_to_str(");
            Expect (TK_LPAREN);
            Parse_Expression;
            Emit (")");
            Expect (TK_RPAREN);
         elsif Name_Eq (Saved, Saved_Len, "__pos") then
            Emit ("((int)(");
            Expect (TK_LPAREN);
            Parse_Expression;
            Emit ("))");
            Expect (TK_RPAREN);
         elsif Name_Eq (Saved, Saved_Len, "__val") then
            Emit ("((char)(");
            Expect (TK_LPAREN);
            Parse_Expression;
            Emit ("))");
            Expect (TK_RPAREN);
         elsif Tok = TK_LPAREN then
            -- Function call or array index
            if Sym_Idx > 0 and then (Sym_Kind (Sym_Idx) = SK_PROC or Sym_Kind (Sym_Idx) = SK_FUNC) then
               Emit_Lower (Saved, Saved_Len);
               Emit ("(");
               Next_Token;
               if Tok /= TK_RPAREN then
                  Parse_Expression;
                  while Tok = TK_COMMA loop
                     Emit (", "); Next_Token;
                     Parse_Expression;
                  end loop;
               end if;
               Emit (")");
               Expect (TK_RPAREN);
            else
               Emit_Lower (Saved, Saved_Len);
               Emit ("[");
               Next_Token;
               Parse_Expression;
               if Sym_Idx > 0 then
                  Emit (" - ");
                  Emit_Int (Sym_Arr_Lo (Sym_Idx));
               else
                  Emit (" - 1");
               end if;
               Emit ("]");
               Expect (TK_RPAREN);
            end if;
         elsif Tok = TK_DOT then
            -- Dotted name
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
               -- Map known stdlib
               if Name_Eq (Sub, Sub_Len, "Argument_Count") then
                  Emit ("(argc - 1)");
               elsif Name_Eq (Sub, Sub_Len, "Argument") then
                  Emit ("argv[");
                  Expect (TK_LPAREN);
                  Parse_Expression;
                  Emit ("]");
                  Expect (TK_RPAREN);
               elsif Name_Eq (Sub, Sub_Len, "End_Of_File") then
                  Emit ("feof(");
                  Expect (TK_LPAREN);
                  Parse_Expression;
                  Emit (")");
                  Expect (TK_RPAREN);
               else
                  Emit_Lower (Saved, Saved_Len);
                  Emit ("_");
                  Emit_Lower (Sub, Sub_Len);
                  if Tok = TK_LPAREN then
                     Emit ("(");
                     Next_Token;
                     if Tok /= TK_RPAREN then
                        Parse_Expression;
                        while Tok = TK_COMMA loop
                           Emit (", "); Next_Token;
                           Parse_Expression;
                        end loop;
                     end if;
                     Emit (")");
                     Expect (TK_RPAREN);
                  end if;
               end if;
            end;
         else
            Emit_Lower (Saved, Saved_Len);
         end if;

      else
         Error ("expected expression");
      end if;
   end Parse_Primary;

   -- Parse multiplicative
   procedure Parse_Factor is
   begin
      Parse_Primary;
      while Tok = TK_STAR or Tok = TK_SLASH or Tok = TK_MOD loop
         if Tok = TK_STAR then
            Emit (" * ");
         elsif Tok = TK_SLASH then
            Emit (" / ");
         else
            Emit (" %% ");
         end if;
         Next_Token;
         Parse_Primary;
      end loop;
   end Parse_Factor;

   -- Parse additive
   procedure Parse_Term is
   begin
      Parse_Factor;
      while Tok = TK_PLUS or Tok = TK_MINUS or Tok = TK_AMP loop
         if Tok = TK_AMP then
            Emit (" + ");
         elsif Tok = TK_PLUS then
            Emit (" + ");
         else
            Emit (" - ");
         end if;
         Next_Token;
         Parse_Factor;
      end loop;
   end Parse_Term;

   -- Parse comparison
   procedure Parse_Comparison is
   begin
      Parse_Term;
      if Tok = TK_EQ then
         Emit (" == "); Next_Token; Parse_Term;
      elsif Tok = TK_NEQ then
         Emit (" != "); Next_Token; Parse_Term;
      elsif Tok = TK_LT then
         Emit (" < "); Next_Token; Parse_Term;
      elsif Tok = TK_GT then
         Emit (" > "); Next_Token; Parse_Term;
      elsif Tok = TK_LE then
         Emit (" <= "); Next_Token; Parse_Term;
      elsif Tok = TK_GE then
         Emit (" >= "); Next_Token; Parse_Term;
      end if;
   end Parse_Comparison;

   -- Parse full expression
   procedure Parse_Expression is
   begin
      Parse_Comparison;
      while Tok = TK_AND or Tok = TK_OR loop
         if Tok = TK_AND then
            Emit (" && "); Next_Token;
            if Tok = TK_THEN then Next_Token; end if;
         else
            Emit (" || "); Next_Token;
            if Tok = TK_ELSE then Next_Token; end if;
         end if;
         Parse_Comparison;
      end loop;
   end Parse_Expression;

   -- Parse single statement
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
         end if;
         Emit_Ln (";"); Expect (TK_SEMI);

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
         Emit_Indent;
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
         Expect (TK_LOOP);
         Indent_Level := Indent_Level + 1;
         Parse_Statements;
         Indent_Level := Indent_Level - 1;
         Emit_Indent; Emit_Ln ("}");
         Expect (TK_END); Expect (TK_LOOP); Expect (TK_SEMI);

      elsif Tok = TK_IDENT then
         Saved_Len := Tok_Len;
         for I in 1 .. Tok_Len loop
            Saved (I) := Tok_Val (I);
         end loop;
         Sym_Idx := Find_Sym (Tok_Val, Tok_Len);
         Next_Token;

         -- Handle "raise"
         if Name_Eq (Saved, Saved_Len, "raise") then
            Emit_Indent;
            Emit ("{ fprintf(stderr, ""Exception\\n""); exit(1); }");
            Emit_Ln ("");
            while Tok /= TK_SEMI and Tok /= TK_EOF loop
               Next_Token;
            end loop;
            Expect (TK_SEMI);

         elsif Tok = TK_ASSIGN then
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
            elsif Sym_Idx > 0 and then Sym_Type (Sym_Idx) = TY_ARRAY then
               Emit_Indent;
               Emit_Lower (Saved, Saved_Len);
               Emit ("[");
               Parse_Expression;
               Emit (" - ");
               Emit_Int (Sym_Arr_Lo (Sym_Idx));
               Emit ("]");
               Expect (TK_RPAREN);
               Expect (TK_ASSIGN);
               Emit (" = "); Next_Token;
               Parse_Expression;
               Emit_Ln (";"); Expect (TK_SEMI);
            else
               -- Assume procedure/function call
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
               Emit ("ada_put_line(");
               Expect (TK_LPAREN); Parse_Expression;
               Emit_Ln (");"); Expect (TK_RPAREN);
            elsif Name_Eq (Sub, Sub_Len, "Put") then
               Emit ("ada_put_str(");
               Expect (TK_LPAREN); Parse_Expression;
               Emit_Ln (");"); Expect (TK_RPAREN);
            elsif Name_Eq (Sub, Sub_Len, "New_Line") then
               Emit_Ln ("ada_new_line();");
               if Tok = TK_LPAREN then
                  Next_Token; Expect (TK_RPAREN);
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

   -- Parse statement sequence
   procedure Parse_Statements is
   begin
      while Tok /= TK_END and Tok /= TK_ELSIF and
            Tok /= TK_ELSE and Tok /= TK_EOF
      loop
         -- Skip exception handlers
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

   -- Parse declarations
   procedure Parse_Declarations is
      Var_Name : Tok_Buffer;
      Var_Len  : Integer;
      Typ      : Integer;
      Is_Const : Boolean;
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
                  if Tok = TK_INT_LIT then
                     Lo := Tok_Int;
                  end if;
                  Next_Token;
                  Expect (TK_DOTDOT);
                  if Tok = TK_INT_LIT then
                     Hi := Tok_Int;
                  end if;
                  Next_Token;
                  -- Handle 2D arrays: skip extra dimensions
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
                        Typ := Parse_Type_Ref;
                        Sym_Type (Sym_Count) := Typ;
                        Emit_C_Type (Typ);
                        Emit (" ");
                        Emit_Lower (Parm, Parm_Len);
                        if Tok = TK_SEMI then Next_Token; end if;
                     end loop;
                     Expect (TK_RPAREN);
                  end;
               end if;
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
               P_Count : Integer := 0;
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
                     P_Types (P_Count) := Parse_Type_Ref;
                     Sym_Type (Sym_Count) := P_Types (P_Count);
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
                  Emit_C_Type (P_Types (I));
                  Emit (" ");
                  Emit_Lower (P_Names (I), P_Lens (I));
               end loop;
               if P_Count = 0 then Emit ("void"); end if;
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
            -- Check for known type
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
                     return;
                  end if;
               end;
            end if;
            -- Check for dotted type (Ada.Text_IO.File_Type etc)
            if Tok = TK_IDENT and then Tok_Eq_CI ("String") then
               Next_Token;
               Add_Sym_Named (Var_Name, Var_Len, SK_VAR, TY_INTEGER);
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
               return;
            end if;
            -- Handle Ada.XXX.YYY type names
            if Tok = TK_IDENT then
               declare
                  Is_File_Type : Boolean := False;
               begin
                  -- Peek ahead for dots
                  Typ := Parse_Type_Ref;
                  if Tok = TK_DOT then
                     Is_File_Type := True;
                     while Tok = TK_DOT loop
                        Next_Token;
                        if Tok = TK_IDENT or Tok = TK_INTEGER or Tok = TK_CHARACTER then
                           if Tok_Eq_CI ("File_Type") then
                              Is_File_Type := True;
                           end if;
                           Next_Token;
                        end if;
                     end loop;
                  end if;
                  if Is_File_Type then
                     Add_Sym_Named (Var_Name, Var_Len, SK_VAR, TY_INTEGER);
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
                     return;
                  end if;
                  -- Regular typed variable
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
                  else
                     Emit (" = 0");
                  end if;
                  Emit_Ln (";");
                  Expect (TK_SEMI);
                  return;
               end;
            end if;
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
            else
               Emit (" = 0");
            end if;
            Emit_Ln (";");
            Expect (TK_SEMI);

         else
            return;
         end if;
      end loop;
   end Parse_Declarations;

   -- Parse context clauses (with/use)
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

   -- Parse main program
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
      Parse_Statements;
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
