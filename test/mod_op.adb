-- mod_op.adb - mod operator
with Ada.Text_IO;

procedure Mod_Op is
begin
   Ada.Text_IO.Put_Line (Integer'Image (10 mod 3));
   Ada.Text_IO.Put_Line (Integer'Image (10 mod 5));
   Ada.Text_IO.Put_Line (Integer'Image (7 mod 4));
end Mod_Op;
