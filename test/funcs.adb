-- funcs.adb - functions with parameters, parameterless function call
with Ada.Text_IO;

procedure Funcs is

   function Add (A : Integer; B : Integer) return Integer is
   begin
      return A + B;
   end Add;

   function Zero return Integer is
   begin
      return 0;
   end Zero;

   X : Integer;
begin
   X := Add (3, 4);
   Ada.Text_IO.Put_Line (Integer'Image (X));
   X := Zero;
   Ada.Text_IO.Put_Line (Integer'Image (X));
   X := Add (Add (1, 2), Add (3, 4));
   Ada.Text_IO.Put_Line (Integer'Image (X));
end Funcs;
