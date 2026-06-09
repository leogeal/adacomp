-- exit_when.adb - plain loop with exit and exit when
with Ada.Text_IO;

procedure Exit_When is
   X : Integer := 0;
begin
   loop
      X := X + 1;
      exit when X >= 5;
   end loop;
   Ada.Text_IO.Put_Line (Integer'Image (X));

   X := 0;
   loop
      X := X + 1;
      if X = 3 then
         exit;
      end if;
   end loop;
   Ada.Text_IO.Put_Line (Integer'Image (X));
end Exit_When;
