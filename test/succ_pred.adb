with Ada.Text_IO;

procedure Succ_Pred is
   type Color is (Red, Green, Blue);
   C : Color := Green;
   N : Integer := 10;
begin
   C := Color'Succ (C);
   Ada.Text_IO.Put_Line (Color'Image (C));          --  BLUE
   C := Color'Pred (C);
   C := Color'Pred (C);
   Ada.Text_IO.Put_Line (Color'Image (C));          --  RED

   N := Integer'Succ (N);
   Ada.Text_IO.Put_Line (Integer'Image (N));        --  11
   N := Integer'Pred (N);
   Ada.Text_IO.Put_Line (Integer'Image (N));        --  10

   begin
      C := Color'Pred (C);        --  before RED -> Constraint_Error
   exception
      when Constraint_Error =>
         Ada.Text_IO.Put_Line ("pred out of range");
   end;

   C := Blue;
   begin
      C := Color'Succ (C);        --  past BLUE -> Constraint_Error
   exception
      when Constraint_Error =>
         Ada.Text_IO.Put_Line ("succ out of range");
   end;

   Ada.Text_IO.Put_Line (Color'Image (C));          --  still BLUE
end Succ_Pred;
