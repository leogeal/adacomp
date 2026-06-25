with Ada.Text_IO;

procedure Sub_Test is
   subtype Small is Integer range 1 .. 10;
   type Level is range 0 .. 100;

   X : Small := 5;
   Y : Integer range 0 .. 100 := 50;
   Z : Level;

   procedure Show (N : Integer) is
   begin
      Ada.Text_IO.Put_Line (Integer'Image (N));
   end Show;

begin
   Show (X);          --  5
   X := 10;
   Show (X);          --  10
   Y := Y + 25;
   Show (Y);          --  75
   Z := 100;
   Show (Z);          --  100

   begin
      X := 11;        --  out of 1 .. 10 -> Constraint_Error
      Show (X);
   exception
      when Constraint_Error =>
         Ada.Text_IO.Put_Line ("x out of range");
   end;

   begin
      Z := 200;       --  out of 0 .. 100
   exception
      when Constraint_Error =>
         Ada.Text_IO.Put_Line ("z out of range");
   end;

   Show (X);          --  still 10 (the bad store never happened)
end Sub_Test;
