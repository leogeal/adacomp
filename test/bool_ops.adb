-- bool_ops.adb - boolean operators including short-circuits
with Ada.Text_IO;

procedure Bool_Ops is

   procedure Show (B : Boolean) is
   begin
      if B then
         Ada.Text_IO.Put_Line ("T");
      else
         Ada.Text_IO.Put_Line ("F");
      end if;
   end Show;

begin
   Show (True and True);
   Show (True and False);
   Show (True or False);
   Show (False or False);
   Show (True and then True);
   Show (False or else True);
   Show (not True);
   Show (not False);
end Bool_Ops;
