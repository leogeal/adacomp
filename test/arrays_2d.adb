-- arrays_2d.adb - nested array (array-of-named-array)
with Ada.Text_IO;

procedure Arrays_2D is
   type Row is array (1 .. 3) of Integer;
   M : array (1 .. 2) of Row;
begin
   for I in 1 .. 2 loop
      for J in 1 .. 3 loop
         M (I) (J) := I * 10 + J;
      end loop;
   end loop;
   for I in 1 .. 2 loop
      for J in 1 .. 3 loop
         Ada.Text_IO.Put_Line (Integer'Image (M (I) (J)));
      end loop;
   end loop;
end Arrays_2D;
