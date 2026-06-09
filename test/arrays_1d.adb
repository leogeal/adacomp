-- arrays_1d.adb - named 1D array type, indexing, assignment
with Ada.Text_IO;

procedure Arrays_1D is
   type Buf is array (1 .. 5) of Integer;
   A : Buf;
begin
   for I in 1 .. 5 loop
      A (I) := I * 10;
   end loop;
   for I in 1 .. 5 loop
      Ada.Text_IO.Put_Line (Integer'Image (A (I)));
   end loop;
end Arrays_1D;
