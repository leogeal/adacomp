with Ada.Text_IO;

procedure Exc_Test is
   My_Error : exception;

   procedure Risky (N : Integer) is
   begin
      if N = 1 then
         raise My_Error;
      elsif N = 2 then
         raise Constraint_Error;
      else
         Ada.Text_IO.Put_Line ("ok");
      end if;
   exception
      when My_Error =>
         Ada.Text_IO.Put_Line ("caught my_error in risky");
   end Risky;

   procedure Reraise_Demo is
   begin
      raise My_Error;
   exception
      when others =>
         Ada.Text_IO.Put_Line ("logged, re-raising");
         raise;
   end Reraise_Demo;

begin
   Risky (3);
   Risky (1);

   --  Risky's handler only covers My_Error, so Constraint_Error
   --  re-propagates out of Risky to this frame.
   begin
      Risky (2);
   exception
      when Constraint_Error =>
         Ada.Text_IO.Put_Line ("caught constraint_error");
   end;

   --  Alternatives in one arm: when A | B =>
   begin
      raise Program_Error;
   exception
      when Constraint_Error | Program_Error =>
         Ada.Text_IO.Put_Line ("caught alt");
   end;

   --  Bare `raise;` re-raises to the enclosing handler.
   begin
      Reraise_Demo;
   exception
      when My_Error =>
         Ada.Text_IO.Put_Line ("outer caught reraised");
   end;

   --  when others catches anything.
   begin
      raise My_Error;
   exception
      when others =>
         Ada.Text_IO.Put_Line ("caught others");
   end;
end Exc_Test;
