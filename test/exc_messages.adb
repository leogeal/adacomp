with Ada.Text_IO;
with Ada.Exceptions;

procedure Exc_Msg is
   Config_Error : exception;
begin
   --  Message attached at the raise site, read in the handler.
   begin
      raise Config_Error with "bad line 5";
   exception
      when E : Config_Error =>
         Ada.Text_IO.Put_Line (Ada.Exceptions.Exception_Message (E));
         Ada.Text_IO.Put_Line (Ada.Exceptions.Exception_Name (E));
   end;

   --  Bare re-raise preserves the occurrence, message included.
   begin
      begin
         raise Config_Error with "inner";
      exception
         when others =>
            raise;
      end;
   exception
      when E : others =>
         Ada.Text_IO.Put_Line (Ada.Exceptions.Exception_Message (E));
   end;

   --  A plain raise carries an empty message.
   begin
      raise Config_Error;
   exception
      when E : others =>
         Ada.Text_IO.Put_Line ("plain");
         Ada.Text_IO.Put_Line (Ada.Exceptions.Exception_Message (E));
   end;
end Exc_Msg;
