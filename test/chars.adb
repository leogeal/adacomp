-- chars.adb - Character'Pos / Character'Val round-trip
with Ada.Text_IO;

procedure Chars is
   C : Character;
begin
   C := 'A';
   Ada.Text_IO.Put_Line (Integer'Image (Character'Pos (C)));
   C := Character'Val (97);
   Ada.Text_IO.Put_Line (Integer'Image (Character'Pos (C)));
   C := Character'Val (Character'Pos ('Z'));
   Ada.Text_IO.Put_Line (Integer'Image (Character'Pos (C)));
end Chars;
