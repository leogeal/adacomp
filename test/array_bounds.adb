with Ada.Text_IO;

procedure Arr_Test is
   type Vec is array (1 .. 5) of Integer;
   A : Vec;
   R : Integer := 0;
begin
   for I in 1 .. 5 loop
      A (I) := I * I;
   end loop;
   for I in 1 .. 5 loop
      Ada.Text_IO.Put_Line (Integer'Image (A (I)));
   end loop;

   begin
      A (6) := 99;          --  write past 1 .. 5 -> Constraint_Error
   exception
      when Constraint_Error =>
         Ada.Text_IO.Put_Line ("write out of bounds");
   end;

   begin
      R := A (0);           --  read before 1 .. 5 -> Constraint_Error
   exception
      when Constraint_Error =>
         Ada.Text_IO.Put_Line ("read out of bounds");
   end;

   Ada.Text_IO.Put_Line (Integer'Image (A (3)));   --  still 9
   Ada.Text_IO.Put_Line (Integer'Image (R));       --  still 0
end Arr_Test;
