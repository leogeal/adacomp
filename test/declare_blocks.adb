-- declare_blocks.adb - declare block with local variables and shadowing
with Ada.Text_IO;

procedure Declare_Blocks is
   X : Integer := 1;
begin
   declare
      Y : Integer := 10;
   begin
      X := X + Y;
   end;
   Ada.Text_IO.Put_Line (Integer'Image (X));

   declare
      Y : Integer := 100;
   begin
      X := X + Y;
   end;
   Ada.Text_IO.Put_Line (Integer'Image (X));
end Declare_Blocks;
