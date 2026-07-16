with Ada.Text_IO;

procedure Nat_Pos is
   subtype Small_Count is Natural;

   N : Natural := 0;
   P : Positive := 1;
   S : Small_Count := 5;
begin
   N := N + 10;
   Ada.Text_IO.Put_Line (Integer'Image (N));       --  10
   P := P * 3;
   Ada.Text_IO.Put_Line (Integer'Image (P));       --  3
   Ada.Text_IO.Put_Line (Natural'Image (S));       --  5

   begin
      N := -1;               --  below 0 -> Constraint_Error
   exception
      when Constraint_Error =>
         Ada.Text_IO.Put_Line ("natural underflow");
   end;

   begin
      P := 0;                --  below 1 -> Constraint_Error
   exception
      when Constraint_Error =>
         Ada.Text_IO.Put_Line ("positive underflow");
   end;

   Ada.Text_IO.Put_Line (Integer'Image (N));       --  still 10
   Ada.Text_IO.Put_Line (Integer'Image (P));       --  still 3
end Nat_Pos;
