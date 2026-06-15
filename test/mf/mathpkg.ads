-- mathpkg.ads - package spec (separate compilation) -> mathpkg.h
package Mathpkg is
   function Square (N : Integer) return Integer;
   function Cube (N : Integer) return Integer;
end Mathpkg;
