with Ada.Text_IO;

procedure Case_Range is
   procedure Classify (N : Integer) is
   begin
      case N is
         when 1 .. 5 =>
            Ada.Text_IO.Put_Line ("low");
         when 6 | 8 | 10 =>
            Ada.Text_IO.Put_Line ("even-ish");
         when 7 | 9 =>
            Ada.Text_IO.Put_Line ("odd-ish");
         when 11 .. 20 | 30 .. 40 =>
            Ada.Text_IO.Put_Line ("teens or thirties");
         when others =>
            Ada.Text_IO.Put_Line ("other");
      end case;
   end Classify;
begin
   Classify (3);
   Classify (8);
   Classify (9);
   Classify (15);
   Classify (35);
   Classify (99);
end Case_Range;
