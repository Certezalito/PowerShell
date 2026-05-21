### Revised Recommendations for Intel GPU-P

  #### 1. Disable High-Fidelity Color Mode (AVC 4:4:4) - (Fixes 0x112f Error)

  • Recommendation: Disable this setting. Your Intel driver is crashing when
  RDP requests this profile. Disabling it will force RDP to use standard
  4:2:0 color, which is lighter on the encoder and far more stable on Intel
  hardware.
  • How to set (Choose one):
      • Group Policy:  Computer Configuration  >  Administrative Templates  >
      Windows Components  >  Remote Desktop Services  >  Remote Desktop
      Session Host  >  Remote Session Environment  -> Disable the policy
      "Prioritize H.264/AVC 444 Graphics mode for Remote Desktop connections".
      • Registry Edit: Delete the  AVC444ModePreferred  value, or set it to
      0  at  HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services .


  #### 2. Hardware Encoding

  • Recommendation: Enable. Even though 4:4:4 failed, you still want Intel
  Quick Sync to handle the standard encoding rather than your CPU.
  • How to set (Choose one):
      • Group Policy:  Computer Configuration  >  Administrative Templates  >
      Windows Components  >  Remote Desktop Services  >  Remote Desktop
      Session Host  >  Remote Session Environment  -> Enable the policy
      "Configure H.264/AVC hardware encoding for Remote Desktop connections"
      (Set to Always attempt).
      • Registry Edit: Set  AVCHardwareEncodePreferred  to  1  at
      HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services .


  #### 3. Hardware Graphics Adapter

  • Recommendation: Enable. Ensures RDP uses the Intel GPU instead of a basic
  display driver.
  • How to set (Choose one):
      • Group Policy:  Computer Configuration  >  Administrative Templates  >
      Windows Components  >  Remote Desktop Services  >  Remote Desktop
      Session Host  >  Remote Session Environment  -> Enable the policy "Use
      hardware graphics adapters for all Remote Desktop Services sessions".
      • Registry Edit: Set  bEnumerateHWBeforeSW  to  1  at
      HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services .


  #### 4. Remove Artificial RDP Input Delay

  • Recommendation: 0. Removes the 50ms batching delay for instant input
  response.
  • How to set:
      • Registry Edit ONLY (No Group Policy exists): Set  InteractiveDelay
      to  0  at  HKLM\SYSTEM\CurrentControlSet\Control\Terminal
      Server\WinStations\RDP-Tcp .


  #### 5. Transport Protocol (UDP)

  • Recommendation: Both UDP and TCP. UDP is essential for low latency.
  • How to set (Choose one):
      • Group Policy:  Computer Configuration  >  Administrative Templates  >
      Windows Components  >  Remote Desktop Services  >  Remote Desktop
      Session Host  >  Connections  -> Enable the policy "Select RDP
      transport protocols" (Set to Use both UDP and TCP).
      • Registry Edit: Set  SelectTransport  to  2  at
      HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services .


  #### 6. Multimedia System Responsiveness

  • Recommendation: 0. Stops Windows from throttling RDP when media is
  playing.
  • How to set:
      • Registry Edit ONLY (No Group Policy exists): Set
      SystemResponsiveness  to  0  at  HKLM\SOFTWARE\Microsoft\Windows
      NT\CurrentVersion\Multimedia\SystemProfile .
