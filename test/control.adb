-- control.adb - if/elsif/else, while loop
with Ada.Text_IO;

procedure Control is
   X : Integer := 10;
begin
   if X > 5 then
      Ada.Text_IO.Put_Line ("big");
   elsif X > 0 then
      Ada.Text_IO.Put_Line ("small");
   else
      Ada.Text_IO.Put_Line ("zero or neg");
   end if;

   X := -3;
   if X > 5 then
      Ada.Text_IO.Put_Line ("big");
   elsif X > 0 then
      Ada.Text_IO.Put_Line ("small");
   else
      Ada.Text_IO.Put_Line ("zero or neg");
   end if;

   X := 0;
   while X < 3 loop
      Ada.Text_IO.Put_Line (Integer'Image (X));
      X := X + 1;
   end loop;
end Control;
