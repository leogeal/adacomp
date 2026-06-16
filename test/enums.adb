with Ada.Text_IO;
procedure Enums is
   type Color is (Red, Green, Blue);
   type Day is (Mon, Tue, Wed, Thu, Fri);
   C : Color;
   D : Day;
   N : Integer;
begin
   C := Green;
   D := Fri;
   if C = Green then
      Ada.Text_IO.Put_Line ("green");
   end if;
   if D = Fri then
      Ada.Text_IO.Put_Line ("friday");
   end if;
   N := 0;
   if C = Red then N := 1; elsif C = Green then N := 2; else N := 3; end if;
   Ada.Text_IO.Put_Line (Integer'Image (N));
end Enums;
