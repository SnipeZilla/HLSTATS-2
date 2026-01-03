SETLOCAL ENABLEEXTENSIONS
CD "%~dp0"
:LBL1
START /WAIT "HLSTATS" /ABOVENORMAL "C:\Strawberry\perl\bin\perl.exe" "%~dp0hlstats.pl"
GOTO LBL1

