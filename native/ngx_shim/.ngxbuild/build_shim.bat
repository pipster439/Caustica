@echo off
call "C://Program Files//Microsoft Visual Studio//18//Community//VC//Auxiliary//Build//vcvars64.bat" >nul 2>&1
if errorlevel 1 exit /b 1
cd /d "%~dp0.."
cl /std:c++17 /O2 /MD /W3 /I"C://VulkanSDK//1.4.357.0//Include" /I"G://DLSS//DLSS-310.7.0//include" /c ngx_shim.cpp /Fo.ngxbuild\ngx_shim.obj
if errorlevel 1 exit /b 1
link /DLL /NOLOGO /OUT:.ngxbuild\ngxshim.dll .ngxbuild\ngx_shim.obj "G://DLSS//DLSS-310.7.0//lib//Windows_x86_64//x64//nvsdk_ngx_d.lib"
