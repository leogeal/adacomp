-- nested.adb - deep compound nesting: for > if/elsif/else > declare,
-- with arrays and a reverse loop, exercising the Pass B.2 statement tree.
with Ada.Text_IO;

procedure Nested is
   type Vec is array (1 .. 5) of Integer;
   A : Vec;
   Total : Integer := 0;
begin
   for I in 1 .. 5 loop
      if I mod 2 = 0 then
         A (I) := I * 100;
      elsif I = 1 then
         A (I) := 1;
      else
         declare
            Tmp : Integer := I * 10;
         begin
            A (I) := Tmp + 7;
         end;
      end if;
   end loop;

   for I in reverse 1 .. 5 loop
      Total := Total + A (I);
      Ada.Text_IO.Put_Line (Integer'Image (A (I)));
   end loop;
   Ada.Text_IO.Put_Line (Integer'Image (Total));
end Nested;
