-- mathpkg.adb - package body (separate compilation) -> mathpkg.c
package body Mathpkg is
   function Square (N : Integer) return Integer is
   begin
      return N * N;
   end Square;
   function Cube (N : Integer) return Integer is
   begin
      return N * Square (N);   -- intra-package call
   end Cube;
end Mathpkg;
