-- access_types.adb - growable buffer via an access-to-unconstrained-array
-- type, exercising `new`, pointer reassignment, and indexing through access.
with Ada.Text_IO;

procedure Access_Types is
   type Int_Vec is array (Integer range <>) of Integer;
   type Int_Vec_Ptr is access Int_Vec;

   Buf : Int_Vec_Ptr;
   Cap : Integer := 0;
   Len : Integer := 0;

   procedure Push (X : Integer) is
   begin
      if Len >= Cap then
         declare
            New_Cap : Integer := Cap * 2 + 4;
            New_Buf : Int_Vec_Ptr := new Int_Vec (1 .. New_Cap);
         begin
            for I in 1 .. Len loop
               New_Buf (I) := Buf (I);
            end loop;
            Buf := New_Buf;
            Cap := New_Cap;
         end;
      end if;
      Len := Len + 1;
      Buf (Len) := X;
   end Push;

begin
   for I in 1 .. 10 loop
      Push (I * I);
   end loop;
   for I in 1 .. Len loop
      Ada.Text_IO.Put_Line (Integer'Image (Buf (I)));
   end loop;
   Ada.Text_IO.Put_Line (Integer'Image (Cap));
end Access_Types;
