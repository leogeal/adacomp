with Ada.Text_IO;

procedure Const_Bound is
   Max   : constant Integer := 10;
   Low   : constant Integer := -5;

   subtype Small is Integer range 1 .. Max;
   subtype Signed is Integer range Low .. Max;
   type Buf is array (1 .. Max) of Integer;

   S : Small := 1;
   G : Signed := -5;
   B : Buf;
   Anon : Integer range Low .. Max := 0;
begin
   S := Max;
   Ada.Text_IO.Put_Line (Integer'Image (S));       --  10
   G := G + 2;
   Ada.Text_IO.Put_Line (Integer'Image (G));       --  -3
   Anon := Low;
   Ada.Text_IO.Put_Line (Integer'Image (Anon));  --  -5

   for I in 1 .. Max loop
      B (I) := I;
   end loop;
   Ada.Text_IO.Put_Line (Integer'Image (B (Max))); --  10

   begin
      S := Max + 1;         --  above Max -> Constraint_Error
   exception
      when Constraint_Error =>
         Ada.Text_IO.Put_Line ("above max");
   end;

   begin
      G := Low - 1;         --  below Low -> Constraint_Error
   exception
      when Constraint_Error =>
         Ada.Text_IO.Put_Line ("below low");
   end;

   Ada.Text_IO.Put_Line (Integer'Image (S));       --  still 10
end Const_Bound;
