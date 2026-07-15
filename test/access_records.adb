with Ada.Text_IO;
with Ada.Unchecked_Deallocation;

procedure Acc2_Test is
   type Node;
   type Node_Ptr is access Node;
   type Node is record
      Value : Integer;
      Next  : Node_Ptr;
   end record;

   procedure Free is new Ada.Unchecked_Deallocation (Node, Node_Ptr);

   type Int_Ptr is access Integer;
   procedure Free_Int is new Ada.Unchecked_Deallocation (Integer, Int_Ptr);

   Head : Node_Ptr;
   Cur  : Node_Ptr;
   Tmp  : Node_Ptr;
   IP   : Int_Ptr;
   Sum  : Integer := 0;
begin
   --  Build the list 3 -> 2 -> 1 by pushing onto the head.
   for I in 1 .. 3 loop
      Cur := new Node;
      Cur.Value := I;
      Cur.Next := Head;
      Head := Cur;
   end loop;

   --  Traverse and print.
   Cur := Head;
   while Cur /= null loop
      Ada.Text_IO.Put_Line (Integer'Image (Cur.Value));
      Sum := Sum + Cur.Value;
      Cur := Cur.Next;
   end loop;
   Ada.Text_IO.Put_Line (Integer'Image (Sum));

   --  Free the list.
   Cur := Head;
   while Cur /= null loop
      Tmp := Cur.Next;
      Free (Cur);
      Cur := Tmp;
   end loop;
   if Cur = null then
      Ada.Text_IO.Put_Line ("freed");
   end if;

   --  Scalar access with .all and deallocation.
   IP := new Integer;
   IP.all := 41;
   IP.all := IP.all + 1;
   Ada.Text_IO.Put_Line (Integer'Image (IP.all));
   Free_Int (IP);
   if IP = null then
      Ada.Text_IO.Put_Line ("int freed");
   end if;
end Acc2_Test;
