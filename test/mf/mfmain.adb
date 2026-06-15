-- mfmain.adb - main unit; `with Mathpkg` -> #include "mathpkg.h", linked
with Mathpkg;
with Ada.Text_IO;
procedure Mfmain is
begin
   Ada.Text_IO.Put_Line (Integer'Image (Mathpkg.Cube (3)));
   Ada.Text_IO.Put_Line (Integer'Image (Mathpkg.Square (5)));
end Mfmain;
