with Ada.Text_IO;
procedure Pkgtest is
   package Math is
      function Square (N : Integer) return Integer;
      function Cube (N : Integer) return Integer;
   end Math;
   package body Math is
      function Square (N : Integer) return Integer is
      begin
         return N * N;
      end Square;
      function Cube (N : Integer) return Integer is
      begin
         return N * Square (N);
      end Cube;
   end Math;
   R : Integer;
begin
   R := Math.Cube (3);
   Ada.Text_IO.Put_Line (Integer'Image (R));
   Ada.Text_IO.Put_Line (Integer'Image (Math.Square (5)));
end Pkgtest;
