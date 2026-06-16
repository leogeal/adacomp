with Ada.Text_IO;
procedure Casetest is
   type Day is (Mon, Tue, Wed, Thu, Fri, Sat, Sun);
   procedure Describe (D : Day) is
   begin
      case D is
         when Mon | Tue | Wed | Thu | Fri =>
            Ada.Text_IO.Put_Line ("weekday");
         when Sat | Sun =>
            Ada.Text_IO.Put_Line ("weekend");
      end case;
   end Describe;

   N : Integer := 3;
begin
   Describe (Mon);
   Describe (Sat);
   case N is
      when 1 => Ada.Text_IO.Put_Line ("one");
      when 2 | 3 => Ada.Text_IO.Put_Line ("two or three");
      when others => Ada.Text_IO.Put_Line ("many");
   end case;
end Casetest;
