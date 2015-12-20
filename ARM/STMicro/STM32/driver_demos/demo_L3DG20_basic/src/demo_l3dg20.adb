------------------------------------------------------------------------------
--                                                                          --
--                    Copyright (C) 2015, AdaCore                           --
--                                                                          --
--  Redistribution and use in source and binary forms, with or without      --
--  modification, are permitted provided that the following conditions are  --
--  met:                                                                    --
--     1. Redistributions of source code must retain the above copyright    --
--        notice, this list of conditions and the following disclaimer.     --
--     2. Redistributions in binary form must reproduce the above copyright --
--        notice, this list of conditions and the following disclaimer in   --
--        the documentation and/or other materials provided with the        --
--        distribution.                                                     --
--     3. Neither the name of STMicroelectronics nor the names of its       --
--        contributors may be used to endorse or promote products derived   --
--        from this software without specific prior written permission.     --
--                                                                          --
--   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS    --
--   "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT      --
--   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR  --
--   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT   --
--   HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, --
--   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT       --
--   LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,  --
--   DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY  --
--   THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT    --
--   (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE  --
--   OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.   --
--                                                                          --
------------------------------------------------------------------------------

--  This program demonstrates the on-board gyro provided by the L3DG20 chip
--  on the STM32F429 Discovery boards. The pitch, roll, and yaw values are
--  continuously displayed on the LCD, as are the adjusted raw values. Move
--  the board to see them change. The values will be positive or negative,
--  depending on the direction of movement. Note that the values are not
--  constant, even when the board is not moving, due to noise.

--  NB: You may need to reset the board after downloading.

with Last_Chance_Handler;      pragma Unreferenced (Last_Chance_Handler);
with Interfaces;   use Interfaces;

with STM32.Device; use STM32.Device;
with STM32.Board;  use STM32.Board;

with STM32.L3DG20; use STM32.L3DG20;

with Bitmapped_Drawing;
with BMP_Fonts;           use BMP_Fonts;
with STM32.LCD;           use STM32.LCD;
with STM32.DMA2D.Polling; use STM32.DMA2D;
with STM32;               use STM32;
with STM32.GPIO;          use STM32.GPIO;

procedure Demo_L3DG20 is

   Axes   : L3DG20.Angle_Rates;
   Stable : L3DG20.Angle_Rates;

   Sensitivity : Float;

   Scaled_X  : Float;
   Scaled_Y  : Float;
   Scaled_Z  : Float;

   --  these constants are used for displaying values on the LCD

   Selected_Font : constant BMP_Font := Font12x12;
   Line_Height   : constant Positive := Char_Height (Selected_Font) + 4;

   --  the locations on the screen for the stable offsets
   Line1_Stable : constant Natural := 0;
   Line2_Stable : constant Natural := Line1_Stable + Line_Height;
   Line3_Stable : constant Natural := Line2_Stable + Line_Height;

   --  the locations on the screen for values after the offset is removed
   Line1_Adjusted : constant Natural := 55; -- leaves room for printing stable values
   Line2_Adjusted : constant Natural := Line1_Adjusted + Line_Height;
   Line3_Adjusted : constant Natural := Line2_Adjusted + Line_Height;

   --  the column number for displaying adjusted values dynamically, based on
   --  the length of the longest static label
   Col_Adjusted : constant Natural := String'("Adjusted X:")'Length * Char_Width (Selected_Font);

   --  the locations on the screen for the final scaled values
   Line1_Final : constant Natural := 110; -- leaves room for printing adjusted values
   Line2_Final : constant Natural := Line1_Final + Line_Height;
   Line3_Final : constant Natural := Line2_Final + Line_Height;

   --  the column number for displaying the final values dynamically, based on
   --  the length of the longest static label
   Final_Column : constant Natural := String'("X:")'Length * Char_Width (Selected_Font);

   procedure Get_Gyro_Offsets
     (Offsets      : out Angle_Rates;
      Sample_Count : in Long_Integer);
   --  computes the averages for the gyro values returned when the board is
   --  motionless

   procedure Configure_Gyro;
   --  configures the on-board gyro chip

   --------------------
   -- Configure_Gyro --
   --------------------

   procedure Configure_Gyro is
   begin
      -- For the page numbers shown below, the required values are specified in
      -- the STM32F429 Discovery kit User Manual (UM1670) on those pages.
      Initialize_Gyro_Hardware
        (Gyro,
         L3GD20_SPI  => SPI_5'Access,
         SPI_GPIO_AF => GPIO_AF_SPI5,
         SCK_Pin     => SPI5_SCK,       -- required, pg 23
         MISO_Pin    => SPI5_MISO,      -- required, pg 23
         MOSI_Pin    => SPI5_MOSI,      -- required, pg 23
         CS_Pin      => NCS_MEMS_SPI,
         Int1_Pin    => MEMS_INT1,
         Int2_Pin    => MEMS_INT2);

      Configure
        (Gyro,
         Power_Mode       => L3GD20_Mode_Active,
         Output_Data_Rate => L3GD20_Output_Data_Rate_95Hz,
         Axes_Enable      => L3GD20_Axes_Enable,
         Bandwidth        => L3GD20_Bandwidth_1,
         BlockData_Update => L3GD20_BlockDataUpdate_Continous,
         Endianness       => L3GD20_BLE_LSB,
         Full_Scale       => L3GD20_Fullscale_250);

      Configure_High_Pass_Filter
        (Gyro,
         Mode_Selection   => L3GD20_HPM_Normal_Mode_Reset,
         Cutoff_Frequency => L3GD20_HPFCF_0);

      Enable_High_Pass_Filter (Gyro);

      --  We cannot check it before configuring the device above.
      if L3DG20.Device_Id (Gyro) /= L3DG20.I_Am_L3GD20 then
         raise Program_Error with "No L3DG20 found";
      end if;
   end Configure_Gyro;

   -----------------
   -- LCD_Drawing --
   -----------------

   package LCD_Drawing renames Bitmapped_Drawing;

   -----------
   -- Print --
   -----------

   procedure Print (Location : LCD_Drawing.Display_Point;  Msg : String) is
      --  a convenience routine for writing to the LCD
   begin
      LCD_Drawing.Draw_String
        (LCD_Drawing.Screen_Buffer,
         Location,
         Msg,
         Selected_Font,
         Foreground => Bitmapped_Drawing.White,  -- arbitrary
         Background => Bitmapped_Drawing.Black); -- arbitrary
   end Print;

   ----------------------
   -- Get_Gyro_Offsets --
   ----------------------

   procedure Get_Gyro_Offsets
     (Offsets      : out Angle_Rates;
      Sample_Count : in Long_Integer)
   is
      Sample  : Angle_Rates;
      Total_X : Long_Integer := 0;
      Total_Y : Long_Integer := 0;
      Total_Z : Long_Integer := 0;
   begin
      for K in 1 .. Sample_Count loop
         Get_Raw_Angle_Rates (Gyro, Sample);
         Total_X := Total_X + Long_Integer (Sample.X);
         Total_Y := Total_Y + Long_Integer (Sample.Y);
         Total_Z := Total_Z + Long_Integer (Sample.Z);
      end loop;
      Offsets.X := Angle_Rate (Total_X / Sample_Count);
      Offsets.Y := Angle_Rate (Total_Y / Sample_Count);
      Offsets.Z := Angle_Rate (Total_Z / Sample_Count);
   end Get_Gyro_Offsets;

begin
   STM32.LCD.Initialize (STM32.LCD.Pixel_Fmt_ARGB1555);
   STM32.DMA2D.Polling.Initialize;

   STM32.LCD.Set_Orientation (STM32.LCD.Portrait);

   STM32.DMA2D.DMA2D_Fill (LCD_Drawing.Screen_Buffer, 0);

   Configure_Gyro;

   Sensitivity := Selected_Sensitivity (Gyro);

   Get_Gyro_Offsets (Stable, Sample_Count => 100);  -- arbitrary count

   --  print the constant offsets computed when the device is motionless
   Print ((0, Line1_Stable), "Stable X:" & Stable.X'Img);
   Print ((0, Line2_Stable), "Stable Y:" & Stable.Y'Img);
   Print ((0, Line3_Stable), "Stable Z:" & Stable.Z'Img);

   --  print the static labels for the values after the offset is removed
   Print ((0, Line1_Adjusted), "Adjusted X:");
   Print ((0, Line2_Adjusted), "Adjusted Y:");
   Print ((0, Line3_Adjusted), "Adjusted Z:");

   --  print the static labels for the final scaled values
   Print ((0, Line1_Final), "X:");
   Print ((0, Line2_Final), "Y:");
   Print ((0, Line3_Final), "Z:");

   loop
      Get_Raw_Angle_Rates (Gyro, Axes);

      --  remove the computed stable offsets from the raw values
      Axes.X := Axes.X - Stable.X;
      Axes.Y := Axes.Y - Stable.Y;
      Axes.Z := Axes.Z - Stable.Z;

      --  print the values after the stable offset is removed
      Print ((Col_Adjusted, Line1_Adjusted), Axes.X'Img & "   ");
      Print ((Col_Adjusted, Line2_Adjusted), Axes.Y'Img & "   ");
      Print ((Col_Adjusted, Line3_Adjusted), Axes.Z'Img & "   ");

      --  scale the adjusted values
      Scaled_X := Float (Axes.X) * Sensitivity;
      Scaled_Y := Float (Axes.Y) * Sensitivity;
      Scaled_Z := Float (Axes.Z) * Sensitivity;

      --  print the final values
      Print ((Final_Column, Line1_Final), Scaled_X'Img & "  ");
      Print ((Final_Column, Line2_Final), Scaled_Y'Img & "  ");
      Print ((Final_Column, Line3_Final), Scaled_Z'Img & "  ");
   end loop;
end Demo_L3DG20;
