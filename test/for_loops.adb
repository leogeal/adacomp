-- for_loops.adb - for forward and for reverse
with Ada.Text_IO;

procedure For_Loops is
begin
   for I in 1 .. 3 loop
      Ada.Text_IO.Put_Line (Integer'Image (I));
   end loop;
   for I in reverse 1 .. 3 loop
      Ada.Text_IO.Put_Line (Integer'Image (I));
   end loop;
end For_Loops;
