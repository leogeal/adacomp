with Ada.Text_IO; use Ada.Text_IO;

procedure Use_TIO is
   N : Integer := 7;
   C : Character := 'x';
begin
   Put_Line ("hello");
   Put ("n =");
   Put_Line (Integer'Image (N));
   Put (C);
   New_Line;
   --  The dotted form still works alongside the bare form.
   Ada.Text_IO.Put_Line ("dotted");
end Use_TIO;
