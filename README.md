# Visual Studio Team Services scripts
This repository contains misc Visual Studio Team Services (VSTS) powershell scripts and custom tasks. When moving from on-premise builds to cloud hosted builds, there were some features that was missing compared to XAML builds.
Hopefully these scripts can be used to fill that gap until Microsoft officially bakes-in those features

## VSTSCheckIn.ps1
Use this script as a custom build task as the build/ publish has finised. Previously with XAML builds, the build agent checks-in "drops" after each build. This script figures out what "drop" needs to be checked-in, so that other CI processes can pick up the drop and do what they need with it (eg Octopus Deploy to release to servers/DBs).
