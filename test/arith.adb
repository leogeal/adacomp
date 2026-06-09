-- arith.adb - integer arithmetic plus Integer'Image
with Ada.Text_IO;

procedure Arith is
   X : Integer := 0;
begin
   X := 1 + 2;
   Ada.Text_IO.Put_Line (Integer'Image (X));
   X := X * 5;
   Ada.Text_IO.Put_Line (Integer'Image (X));
   X := X - 7;
   Ada.Text_IO.Put_Line (Integer'Image (X));
   X := X / 2;
   Ada.Text_IO.Put_Line (Integer'Image (X));
end Arith;
