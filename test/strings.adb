-- strings.adb - String parameters with 'Length and 'First
with Ada.Text_IO;

procedure Strings is

   procedure Show (S : String) is
   begin
      Ada.Text_IO.Put_Line (Integer'Image (S'Length));
      Ada.Text_IO.Put_Line (Integer'Image (S'First));
   end Show;

begin
   Show ("hello");
   Show ("ab");
   Show ("");
end Strings;
