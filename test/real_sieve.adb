with Ada.Text_IO, Ada.Command_Line;

procedure Eratos is

   Last: constant Positive := 50;  -- ADAPTED: was Positive'Value(Ada.Command_Line.Argument(1)); dynamic bounds are out of subset
   Prime: array(1 .. Last) of Boolean := (1 => False, others => True);
   Base: Positive := 2;
   Cnt: Positive;
begin
   while Base * Base <= Last loop
      if Prime(Base) then
         Cnt := Base + Base;
         while Cnt <= Last loop
            Prime(Cnt) := False;
            Cnt := Cnt + Base;
         end loop;
      end if;
      Base := Base + 1;
   end loop;
   Ada.Text_IO.Put("Primes less or equal" & Positive'Image(Last) &" are:");
   for Number in Prime'Range loop
      if Prime(Number) then
         Ada.Text_IO.Put(Positive'Image(Number));
      end if;
   end loop;
end Eratos;
