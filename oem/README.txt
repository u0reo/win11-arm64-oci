Windows 11 ARM64 clean-install OEM media
=========================================

This directory is copied to C:\OEM during Windows Setup.

Logs after first boot:
  C:\OEM\specialize.log
  C:\OEM\firstlogon.log
  C:\OEM\boot.log
  C:\OEM\done.txt

Accounts:
  User           / <WIN_PASSWORD>       (local Administrators)
  Administrator  / <WIN_PASSWORD>       (enabled)

The password is not stored here.  It is rendered into autounattend.xml and
the OEM PowerShell scripts from the WIN_PASSWORD environment variable (or
from GitHub Secrets), and it is embedded in the finished image in clear
text.

Services:
  RDP  3389/tcp  (NLA disabled for lab compatibility)
  WinRM 5985/tcp (Basic + unencrypted enabled for lab compatibility)

Serial:
  COM1 115200    EMS/SAC always enabled (bcdedit /ems in specialize.ps1).
                 The OCI serial console shows "SAC>"; type "cmd" for an
                 administrative command prompt.  The boot menu is shown for
                 --boot-menu SECONDS (default 1 s, 0 = off).

A scheduled task named "OEM Bootstrap" runs C:\OEM\bootstrap.cmd as SYSTEM
at every start.  It is idempotent and is the fallback if RDP/WinRM were not
configured during OOBE.

The static fallback in net.cfg is only applied when DHCP fails.  On QEMU
user-net the guest keeps 10.0.2.15.  On OCI the normal DHCP address is kept;
if DHCP fails the fallback is 10.0.0.192/24, gw 10.0.0.1.
