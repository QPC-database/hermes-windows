param(
    [string]$SourcesPath = "$PSScriptRoot\..",
    [string]$WorkSpacePath = "$SourcesPath\workspace",
    [string]$OutputPath = "$WorkSpacePath\out",
    
    [ValidateSet("x64", "x86", "arm", "arm64")]
    [String[]]$Platform = @("x64"),

    [ValidateSet("x64", "x86", "arm", "arm64")]
    [String]$ToolsPlatform = @("x86"), # Platform used for building tools when cross compiling
    
    [ValidateSet("debug", "release")]
    [String]$ToolsConfiguration = @("release"), # Platform used for building tools when cross compiling
    
    [ValidateSet("debug", "release")]
    [String[]]$Configuration = @("debug"),
    
    [ValidateSet("win32", "uwp")]
    [String[]]$AppPlatform = ("win32", "uwp"),
    
    [switch]$RunTests,
    [switch]$Incremental,
    [switch]$UseVS
)

function Find-Path($exename) {
    $v = (get-command $exename -ErrorAction SilentlyContinue)
    if ($v.Path) {
        return $v.Path
    }
    else {
        throw "Could not find $exename"
    }
}

function Find-VS-Path() {
    $vsWhere = (get-command "vswhere.exe" -ErrorAction SilentlyContinue)
    if ($vsWhere) {
        $vsWhere = $vsWhere.Path
    }
    else {
        $vsWhere = "${Env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" 
    }

    if (Test-Path $vsWhere) {
        $versionJson = & $vsWhere -format json 
        $versionJson = & $vsWhere -format json -version 16
        $versionJson = $versionJson | ConvertFrom-Json 
    } else {
        $versionJson = @()
    }

    if ($versionJson.Length -gt 1) { Write-Warning 'More than one VS install detected, picking the first one'; $versionJson = $versionJson[0]; }

    if ($versionJson.installationPath) {
        $vcVarsPath = "$($versionJson.installationPath)\VC\Auxiliary\Build\vcvarsall.bat"
        if (Test-Path $vcVarsPath) {
            return $vcVarsPath
        } else {
            throw "Could not find vcvarsall.bat at expected Visual Studio installation path"
            throw "Could not find vcvarsall.bat at expected Visual Studio installation path: $vcVarsPath"
        }
    } else {
        throw "Could not find Visual Studio installation path"
    }
}

function Get-VCVarsParam($plat = "x64", $arch = "win32") {
    $args_ = switch ($plat)
    {
        "x64" {"x64"}
        "x86" {"x64_x86"}
        "arm" {"x64_arm"}
        "arm64" {"x64_arm64"}
        default { "x64" }
    }

    if ($arch -eq "uwp") {
        $args_ = "$args_ uwp"
    }

    return $args_
}

function Get-CMakeConfiguration($config) {
    $val = switch ($config)
    {
        "debug" {"Debug"}
        "release" {"MinSizeRel"}
        default {"Debug"}
    }

    return $val
}

function Invoke-Environment($Command, $arg) {
    $Command = "`"" + $Command + "`" " + $arg
    Write-Host "Running command [ $Command ]"
    cmd /c "$Command && set" | . { process {
        if ($_ -match '^([^=]+)=(.*)') {
            [System.Environment]::SetEnvironmentVariable($matches[1], $matches[2])
        }
    }}
}

function get-CommonArgs($Platform, $Configuration, $AppPlatform, [ref]$genArgs) {
    if($UseVS.IsPresent) {
        $genArgs.Value += '-G "Visual Studio 16 2019"'
        $cmakePlatform = $Platform;
        if ($cmakePlatform -eq 'x86') {
            $cmakePlatform = 'Win32';
        }
        $genArgs.Value += ('-A {0}' -f $cmakePlatform)
    } else {
        $genArgs.Value += '-G Ninja'
    }

    $genArgs.Value += ('-DPYTHON_EXECUTABLE={0}' -f $PYTHON_PATH)
    $genArgs.Value += ('-DCMAKE_BUILD_TYPE={0}' -f (Get-CMakeConfiguration $Configuration))

    $genArgs.Value += '-DHERMESVM_PLATFORM_LOGGING=On'
}

function Invoke-BuildImpl($SourcesPath, $buildPath, $genArgs, $targets, $incrementalBuild, $Platform, $Configuration, $AppPlatform) {

    Write-Host "Invoke-BuildImpl called with SourcesPath: " $SourcesPath", buildPath: " $buildPath  ", genArgs: " $genArgs ", targets: " $targets ", incrementalBuild: " $incrementalBuild", Platform: " $Platform ", Configuration: " $Configuration ", AppPlatform: " $AppPlatform

    if (!$incrementalBuild -and (Test-Path -Path $buildPath)) {
        Remove-Item $buildPath -Recurse -ErrorAction Ignore
    }
    
    New-Item -ItemType "directory" -Path $buildPath -ErrorAction Ignore | Out-Null
    Push-Location $buildPath

    $genCall = ('cmake {0}' -f ($genArgs -Join ' ')) + " $SourcesPath";
    Write-Host $genCall | Out-Null
    $ninjaCmd = "ninja"

    foreach ( $target in $targets )
    {
        $ninjaCmd = $ninjaCmd + " " + $target
    }

    Write-Output $ninjaCmd | Out-Null

    # See https://developercommunity.visualstudio.com/content/problem/257260/vcvarsallbat-reports-the-input-line-is-too-long-if.html
    $Bug257260 = $false

    if ($Bug257260) {
        Invoke-Environment $VCVARS_PATH (Get-VCVarsParam $Platform $AppPlatform)
        Invoke-Expression $genCall
        
        if($UseVS.IsPresent) {

        } else {
            ninja $ninjaCmd
        }

    } else {
        $Cmd = "`"$VCVARS_PATH`" $(Get-VCVarsParam $Platform $AppPlatform) && $genCall 2>&1 && ${ninjaCmd}"
        Write-Output "Command: $Cmd" | Out-Null
        cmd /c $Cmd
    }

    Pop-Location
}

function Invoke-Compiler-Build($SourcesPath, $buildPath, $Platform, $Configuration, $AppPlatform, $RNDIR, $FOLLYDIR, $BOOSTDIR, $incrementalBuild) {
    $genArgs = @();
    get-CommonArgs $Platform $Configuration $AppPlatform ([ref]$genArgs)

    $genArgs += "-DREACT_NATIVE_SOURCE=$RNDIR"
    $genArgs += "-DFOLLY_SOURCE=$FOLLYDIR"
    $genArgs += "-DBOOST_SOURCE=$BOOSTDIR"

    Invoke-BuildImpl $SourcesPath $buildPath $genArgs @('hermes','hermesc') $$incrementalBuild $Platform $Configuration $AppPlatform
    Pop-Location
}

function Invoke-Dll-Build($SourcesPath, $buildPath, $compilerAndToolsBuildPath, $Platform, $Configuration, $AppPlatform, $RNDIR, $FOLLYDIR, $BOOSTDIR, $incrementalBuild, $WithHermesDebugger) {
    $genArgs = @();
    get-CommonArgs $Platform $Configuration $AppPlatform ([ref]$genArgs)

    $targets = @('libhermes');

    if($WithHermesDebugger) {
        $genArgs += '-DHERMES_ENABLE_DEBUGGER=ON'

        $genArgs += "-DREACT_NATIVE_SOURCE=$RNDIR"
        $genArgs += "-DFOLLY_SOURCE=$FOLLYDIR"
        $genArgs += "-DBOOST_SOURCE=$BOOSTDIR"

        $targets += 'hermesinspector'
    } else {
        $genArgs += '-DHERMES_ENABLE_DEBUGGER=OFF'
    }

    if ($AppPlatform -eq "uwp") {
        $genArgs += '-DCMAKE_CXX_STANDARD=17'
        $genArgs += '-DCMAKE_SYSTEM_NAME=WindowsStore'
        $genArgs += '-DCMAKE_SYSTEM_VERSION="10.0.15063"'
        $genArgs += "-DIMPORT_HERMESC=$compilerAndToolsBuildPath\ImportHermesc.cmake"
    }

    Invoke-BuildImpl $SourcesPath $buildPath $genArgs $targets $incrementalBuild $Platform $Configuration $AppPlatform
}

function Invoke-Test-Build($SourcesPath, $buildPath, $compilerAndToolsBuildPath, $Platform, $Configuration, $AppPlatform,  $incrementalBuild) {
    $genArgs = @();
    get-CommonArgs([ref]$genArgs)

    $genArgs += '-DHERMES_ENABLE_DEBUGGER=On'

    if ($AppPlatform -eq "uwp") {
        $genArgs += '-DCMAKE_CXX_STANDARD=17'
        $genArgs += '-DCMAKE_SYSTEM_NAME=WindowsStore'
        $genArgs += '-DCMAKE_SYSTEM_VERSION="10.0.15063"'
        $genArgs += "-DIMPORT_HERMESC=$compilerAndToolsBuildPath\ImportHermesc.cmake"
    }

    Invoke-BuildImpl($SourcesPath, $buildPath, $genArgs, @('check-hermes')) $incrementalBuild $Platform $Configuration $AppPlatform
}

function Invoke-Build($SourcesPath, $WorkSpacePath, $OutputPath, $Platform, $Configuration, $AppPlatform, $RNDIR, $FOLLYDIR, $BOOSTDIR) {

    Write-Host "Invoke-Build called with SourcesPath: " $SourcesPath", WorkSpacePath: " $WorkSpacePath  ", OutputPath: " $OutputPath ", Platform: " $Platform ", Configuration: " $Configuration ", AppPlatform: " $AppPlatform ", RNDIR: " $RNDIR ", FOLLYDIR: " $FOLLYDIR ", BOOSTDIR: " $BOOSTDIR
    $Triplet = "$AppPlatform-$Platform-$Configuration"
    $compilerAndToolsBuildPath = Join-Path $WorkSpacePath "build\tools"
    $compilerPath = Join-Path $compilerAndToolsBuildPath "bin\hermesc.exe"
    
    # Build compiler if it doesn't exist (To be precise, we need it only for when building for uwp i.e. cross compilation !). 
    if (!(Test-Path -Path $compilerPath)) {
        Invoke-Compiler-Build $SourcesPath $compilerAndToolsBuildPath $toolsPlatform $toolsConfiguration "win32" $RNDIR $FOLLYDIR $BOOSTDIR $True
    }
    
    $buildPath = Join-Path $WorkSpacePath "build\$Triplet"
    $buildPathWithDebugger = Join-Path $buildPath "withdebugger"
    
    if ($Configuration -eq "release") {
        $WithHermesDebugger = $False
        Invoke-Dll-Build $SourcesPath $buildPath $compilerAndToolsBuildPath $Platform $Configuration $AppPlatform $RNDIR $FOLLYDIR $BOOSTDIR $Incremental.IsPresent $WithHermesDebugger

        $WithHermesDebugger = $True
        Invoke-Dll-Build $SourcesPath $buildPathWithDebugger $compilerAndToolsBuildPath $Platform $Configuration $AppPlatform $RNDIR $FOLLYDIR $BOOSTDIR $Incremental.IsPresent $WithHermesDebugger
    } else {
        $WithHermesDebugger = $True
        Invoke-Dll-Build $SourcesPath $buildPath $compilerAndToolsBuildPath $Platform $Configuration $AppPlatform $RNDIR $FOLLYDIR $BOOSTDIR $Incremental.IsPresent $WithHermesDebugger
    }
    

    if ($RunTests.IsPresent) {
        Invoke-Test-Build($SourcesPath, $buildPath, $Platform, $Configuration, $AppPlatform);
    }
    
    $finalOutputPath = "$OutputPath\lib\$AppPlatform\$Configuration\$Platform";
    if (!(Test-Path -Path $finalOutputPath)) {
        New-Item -ItemType "directory" -Path $finalOutputPath | Out-Null
    }

    Copy-Item "$buildPath\API\hermes\hermes.dll" -Destination $finalOutputPath -force | Out-Null
    Copy-Item "$buildPath\API\hermes\hermes.lib" -Destination $finalOutputPath -force | Out-Null

    if (!($Configuration -eq "release")) {
        Copy-Item "$buildPath\API\inspector\hermesinspector.dll" -Destination $finalOutputPath -force | Out-Null
        Copy-Item "$buildPath\API\inspector\hermesinspector.lib" -Destination $finalOutputPath -force | Out-Null
    }

    if ($Configuration -eq "release") {

        $finalOutputPathWithDebugger = Join-Path $finalOutputPath "withdebugger"
        if (!(Test-Path -Path $finalOutputPathWithDebugger)) {
            New-Item -ItemType "directory" -Path $finalOutputPathWithDebugger | Out-Null
        }

        Copy-Item "$buildPathWithDebugger\API\hermes\hermes.dll" -Destination $finalOutputPathWithDebugger -force | Out-Null
        Copy-Item "$buildPathWithDebugger\API\hermes\hermes.lib" -Destination $finalOutputPathWithDebugger -force | Out-Null

        Copy-Item "$buildPathWithDebugger\API\inspector\hermesinspector.dll" -Destination $finalOutputPathWithDebugger -force | Out-Null
        Copy-Item "$buildPathWithDebugger\API\inspector\hermesinspector.lib" -Destination $finalOutputPathWithDebugger -force | Out-Null
    }

    $toolsPath = "$OutputPath\tools\$toolsConfiguration\$toolsPlatform"
    if (!(Test-Path -Path $toolsPath)) {
        New-Item -ItemType "directory" -Path $toolsPath | Out-Null
    }

    Copy-Item "$compilerAndToolsBuildPath\bin\hermes.exe" -Destination $toolsPath

    Pop-Location
}

$StartTime = (Get-Date)

$VCVARS_PATH = Find-VS-Path
$PYTHON_PATH = Find-Path "python.exe"
$CMAKE_PATH = Find-Path "cmake.exe"
$CMAKE_PATH = Find-Path "git.exe"

if (!(Test-Path -Path $WorkSpacePath)) {
    New-Item -ItemType "directory" -Path $WorkSpacePath | Out-Null
}

Push-Location $WorkSpacePath

$BOOST_DIR = Invoke-Expression "$PSScriptRoot\prepare_boost.ps1".Replace("\", "/")
$FOLLY_DIR = Invoke-Expression "$PSScriptRoot\prepare_folly.ps1".Replace("\", "/")
$RN_DIR = Invoke-Expression "$PSScriptRoot\prepare_reactnative.ps1".Replace("\", "/")

$FOLLY_DIR = $FOLLY_DIR.Replace("\", "/")
$BOOST_DIR = $BOOST_DIR.Replace("\", "/")
$RN_DIR = $RN_DIR.Replace("\", "/")

Write-Output "FOLLY_DIR: $FOLLY_DIR"
Write-Output "BOOST_DIR: $BOOST_DIR"
Write-Output "RN_DIR: $RN_DIR"

# first copy the headers into the output
if (!(Test-Path -Path "$OutputPath\build\native\include\hermes")) {
    New-Item -ItemType "directory" -Path "$OutputPath\build\native\include\hermes" | Out-Null
}

if (!(Test-Path -Path "$OutputPath\build\native\include\hermesinspector")) {
    New-Item -ItemType "directory" -Path "$OutputPath\build\native\include\hermesinspector" | Out-Null
}

if (!(Test-Path -Path "$OutputPath\build\native\include\jsi")) {
    New-Item -ItemType "directory" -Path "$OutputPath\build\native\include\jsi" | Out-Null
}

Write-Output "$RN_DIR\ReactCommon\hermes\**\*.h"

Copy-Item "$SourcesPath\API\jsi\jsi\*" -Destination "$OutputPath\build\native\include\jsi" -force -Recurse
Copy-Item "$SourcesPath\API\hermes\hermes.h" -Destination "$OutputPath\build\native\include\hermes" -force
Copy-Item "$SourcesPath\API\hermes\DebuggerAPI.h" -Destination "$OutputPath\build\native\include\hermes" -force
Copy-Item "$SourcesPath\public\hermes\*" -Destination "$OutputPath\build\native\include\hermes" -force -Recurse
Copy-Item "$RN_DIR\ReactCommon\jsinspector\*.h" -Destination "$OutputPath\build\native\include\hermesinspector" -force -Recurse
Copy-Item "$RN_DIR\ReactCommon\hermes\**\*.h" -Destination "$OutputPath\build\native\include\hermesinspector" -force -Recurse

if (!(Test-Path -Path "$OutputPath\build\native\include\hermesinspector\jsinspector")) {
    New-Item -ItemType "directory" -Path "$OutputPath\build\native\include\hermesinspector\jsinspector" | Out-Null
}
Copy-Item "$RN_DIR\ReactCommon\jsinspector\*.h" -Destination "$OutputPath\build\native\include\hermesinspector\jsinspector" -force -Recurse


if (!(Test-Path -Path "$OutputPath\build\native\include\hermesinspector\hermes\inspector")) {
    New-Item -ItemType "directory" -Path "$OutputPath\build\native\include\hermesinspector\hermes\inspector" | Out-Null
}
Copy-Item "$RN_DIR\ReactCommon\hermes\inspector\*.h" -Destination "$OutputPath\build\native\include\hermesinspector\hermes\inspector" -force -Recurse

if (!(Test-Path -Path "$OutputPath\build\native\include\hermesinspector\hermes\inspector\chrome")) {
    New-Item -ItemType "directory" -Path "$OutputPath\build\native\include\hermesinspector\hermes\inspector\chrome" | Out-Null
}
Copy-Item "$RN_DIR\ReactCommon\hermes\inspector\chrome\*.h" -Destination "$OutputPath\build\native\include\hermesinspector\hermes\inspector\chrome" -force -Recurse

# run the actual builds

foreach ($Plat in $Platform) {
    foreach ($Config in $Configuration) {
        foreach ($AppPlat in $AppPlatform) {
            Invoke-Build -SourcesPath $SourcesPath -WorkSpacePath $WorkSpacePath -OutputPath $OutputPath -Platform $Plat -Configuration $Config -AppPlatform $AppPlat -RNDIR $RN_DIR -FOLLYDIR $FOLLY_DIR -BOOSTDIR $BOOST_DIR
        }
    }
}

# copy misc files for NuGet to pick up
if (!(Test-Path -Path "$OutputPath\license")) {
    New-Item -ItemType "directory" -Path "$OutputPath\license" | Out-Null
}

Copy-Item "$SourcesPath\LICENSE" -Destination "$OutputPath\license\" -force 
Copy-Item "$SourcesPath\.ado\ReactNative.Hermes.Windows.targets" -Destination "$OutputPath\build\native\" -force

# process version information

$gitRevision = ((git rev-parse --short HEAD) | Out-String).Trim()

$npmPackage = (Get-Content (Join-Path $SourcesPath "npm\package.json") | Out-String | ConvertFrom-Json).version

(Get-Content "$SourcesPath\.ado\ReactNative.Hermes.Windows.nuspec") -replace ('VERSION_DETAILS', "Hermes version: $npmPackage; Git revision: $gitRevision") | Set-Content "$OutputPath\ReactNative.Hermes.Windows.nuspec"

$npmPackage | Set-Content "$OutputPath\version"

$elapsedTime = $(get-date) - $StartTime

$totalTime = "{0:HH:mm:ss}" -f ([datetime]$elapsedTime.Ticks)

Pop-Location

Write-Host "Build took $totalTime to run"