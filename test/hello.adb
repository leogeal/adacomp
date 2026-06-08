-- hello.adb - Simple test program
with Ada.Text_IO;

procedure Hello is
   X : Integer := 42;
   I : Integer := 0;
begin
   Ada.Text_IO.Put_Line ("Hello from Ada!");
   Ada.Text_IO.Put_Line ("The answer is:");
   while I < 5 loop
      X := X + I;
      I := I + 1;
   end loop;
   Ada.Text_IO.Put_Line ("Done.");
end Hello;
