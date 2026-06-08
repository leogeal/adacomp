-- factorial.adb - Test with functions and control flow
with Ada.Text_IO;

procedure Factorial is

   function Fact (N : Integer) return Integer is
   begin
      if N <= 1 then
         return 1;
      else
         return N * Fact (N - 1);
      end if;
   end Fact;

   Result : Integer := 0;

begin
   for I in 1 .. 10 loop
      Result := Fact (I);
      Ada.Text_IO.Put_Line ("Factorial computed.");
   end loop;
end Factorial;
