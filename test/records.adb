with Ada.Text_IO;
procedure Records is
   type Point is record
      X : Integer;
      Y : Integer;
   end record;
   function Sum (P : Point) return Integer is
   begin
      return P.X + P.Y;
   end Sum;
   A : Point;
   B : Point;
begin
   A.X := 3;
   A.Y := 4;
   B := A;
   B.Y := 10;
   Ada.Text_IO.Put_Line (Integer'Image (A.X));
   Ada.Text_IO.Put_Line (Integer'Image (A.Y));
   Ada.Text_IO.Put_Line (Integer'Image (B.X));
   Ada.Text_IO.Put_Line (Integer'Image (B.Y));
   Ada.Text_IO.Put_Line (Integer'Image (Sum (A)));
end Records;
