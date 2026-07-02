with Ada.Text_IO;

procedure Enum_Attr is
   type Color is (Red, Green, Blue);
   C : Color;
begin
   Ada.Text_IO.Put_Line (Integer'Image (Color'First));   --  0
   Ada.Text_IO.Put_Line (Integer'Image (Color'Last));    --  2

   for X in Color loop
      Ada.Text_IO.Put_Line (Color'Image (X));            --  RED GREEN BLUE
   end loop;

   C := Green;
   Ada.Text_IO.Put_Line (Integer'Image (Color'Pos (C))); --  1
   C := Color'Val (2);
   Ada.Text_IO.Put_Line (Color'Image (C));               --  BLUE

   for X in reverse Color loop
      Ada.Text_IO.Put_Line (Color'Image (X));            --  BLUE GREEN RED
   end loop;
end Enum_Attr;
