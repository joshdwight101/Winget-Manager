<#
.SYNOPSIS
Winget Manager - Full Lifecycle Enterprise Deployment Utility
.DESCRIPTION
A compiled C# WPF interface wrapped inside a single portable PowerShell script
providing comprehensive GUI control over the Windows Package Manager (Winget).
.VERSION
1.0.0
.AUTHOR
Joshua Dwight
.LINK
https://www.linkedin.com/in/joshua-dwight
.LICENSE
GPL-3.0 License
#>

[CmdletBinding()]
param(
    [switch]$DebugMode
)

# System Authorization and Integrity Check
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "Administrative privileges are recommended for global package execution. Relaunching in elevated context..."
    try {
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
        Exit
    } catch {
        Write-Warning "Failed to elevate. Running in current context. Machine-wide installations may fail."
    }
}

# Initializing Assembly Requirements
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# Configuring embedded app metadata and local paths
$Global:AppVersion = "1.0.0"
$Global:IsDebugMode = $DebugMode.IsPresent

$Global:AppDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent -Path $PSCommandPath }
if (-not $Global:AppDir) { $Global:AppDir = $env:CD }

$Global:SettingsFile = Join-Path $Global:AppDir "WingetManager_Settings.json"

function global:Write-DebugLog([string]$Message) {
    if ($Global:IsDebugMode) {
        $LogLine = "[DEBUG] [$(Get-Date -Format 'HH:mm:ss.fff')] $Message"
        Write-Host $LogLine -ForegroundColor Yellow
        Add-Content -Path "$Global:AppDir\WingetManager_Debug.log" -Value $LogLine -ErrorAction SilentlyContinue
    }
}

if ($Global:IsDebugMode) { Write-DebugLog "=== WINGET MANAGER STARTED IN DEBUG MODE ===" }

# Define Default Settings
$Global:LogSettings = @{
    LoggingEnabled  = $true
    LogPath         = $Global:AppDir
    LogFileName     = "Winget_Audit.log"
    MaxLogSizeMB    = 10
    MaxLogAgeDays   = 30
    AutoPrunePolicy = "Archive"
}

$Global:WingetSettings = @{
    Scope                 = "machine"
    AcceptAgreements      = $true
    Architecture          = ""
    DisableInteractivity  = $true
}

# Load Settings from JSON File
function global:Load-Settings {
    if (Test-Path $Global:SettingsFile) {
        try {
            $Loaded = Get-Content $Global:SettingsFile -Raw | ConvertFrom-Json
            if ($null -ne $Loaded.LogSettings) {
                $Global:LogSettings.LoggingEnabled = [bool]$Loaded.LogSettings.LoggingEnabled
                $Global:LogSettings.LogPath = $Loaded.LogSettings.LogPath
                $Global:LogSettings.LogFileName = $Loaded.LogSettings.LogFileName
                $Global:LogSettings.MaxLogSizeMB = [int]$Loaded.LogSettings.MaxLogSizeMB
                $Global:LogSettings.MaxLogAgeDays = [int]$Loaded.LogSettings.MaxLogAgeDays
                $Global:LogSettings.AutoPrunePolicy = $Loaded.LogSettings.AutoPrunePolicy
            }
            if ($null -ne $Loaded.WingetSettings) {
                $Global:WingetSettings.Scope = $Loaded.WingetSettings.Scope
                $Global:WingetSettings.AcceptAgreements = [bool]$Loaded.WingetSettings.AcceptAgreements
                $Global:WingetSettings.Architecture = $Loaded.WingetSettings.Architecture
                $Global:WingetSettings.DisableInteractivity = [bool]$Loaded.WingetSettings.DisableInteractivity
            }
            Write-DebugLog "Settings loaded from $Global:SettingsFile"
        } catch {
            Write-DebugLog "Failed to load settings: $_"
        }
    }
}

function global:Save-Settings {
    $SaveData = @{
        LogSettings = $Global:LogSettings
        WingetSettings = $Global:WingetSettings
    }
    try {
        $SaveData | ConvertTo-Json -Depth 5 | Set-Content $Global:SettingsFile
        Write-DebugLog "Settings saved to $Global:SettingsFile"
    } catch {
        Write-DebugLog "Failed to save settings: $_"
    }
}

Load-Settings

$Global:InstalledApps = New-Object System.Collections.ObjectModel.ObservableCollection[Object]
$Global:AvailableUpdates = New-Object System.Collections.ObjectModel.ObservableCollection[Object]
$Global:SearchResults = New-Object System.Collections.ObjectModel.ObservableCollection[Object]
$Global:UpgradeQueue = New-Object System.Collections.Generic.Queue[Object]

# Defining Enterprise Logging Engine
function global:Initialize-EnterpriseLogger {
    if (-not $Global:LogSettings.LoggingEnabled) { return }

    if (-not (Test-Path $Global:LogSettings.LogPath)) {
        try { New-Item -ItemType Directory -Force -Path $Global:LogSettings.LogPath | Out-Null } catch {}
    }

    $TargetFile = Join-Path $Global:LogSettings.LogPath $Global:LogSettings.LogFileName

    function Process-PruneAction($Path, $Action) {
        if ($Action -eq "Delete") {
            Remove-Item -Path $Path -Force -ErrorAction SilentlyContinue
        } elseif ($Action -eq "Archive") {
            $ArchiveName = "$Path.$((Get-Date).ToString('yyyyMMddHHmmss')).bak"
            Rename-Item -Path $Path -NewName $ArchiveName -Force -ErrorAction SilentlyContinue
        }
    }

    if (Test-Path $TargetFile) {
        $FileSizeMB = (Get-Item $TargetFile).Length / 1MB
        if ($FileSizeMB -gt $Global:LogSettings.MaxLogSizeMB) {
            Process-PruneAction -Path $TargetFile -Action $Global:LogSettings.AutoPrunePolicy
        }
    }

    Get-ChildItem -Path $Global:LogSettings.LogPath -Filter "*.bak" -ErrorAction SilentlyContinue | ForEach-Object {
        if ((New-TimeSpan -Start $_.LastWriteTime -End (Get-Date)).Days -gt $Global:LogSettings.MaxLogAgeDays) {
            Process-PruneAction -Path $_.FullName -Action "Delete"
        }
    }
}

function global:Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    if (-not $Global:LogSettings.LoggingEnabled) { return }

    $TargetFile = Join-Path $Global:LogSettings.LogPath $Global:LogSettings.LogFileName
    $Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $LogEntry = "[$Timestamp] [$Level] $Message"

    Add-Content -Path $TargetFile -Value $LogEntry -ErrorAction SilentlyContinue
}

# Defining robust Winget Execution Wrapper (Deadlock-Free)
function global:Invoke-WingetCommand {
    param(
        [string]$Command,
        [switch]$ReturnOutput = $true
    )

    $FullCommand = "winget $Command"
    Write-Log -Message "Executing: $FullCommand"
    Write-DebugLog "Invoke-WingetCommand: $FullCommand"

    $TempOut = [System.IO.Path]::GetTempFileName()
    $TempErr = [System.IO.Path]::GetTempFileName()

    Write-DebugLog "Temp files created: Out=$TempOut, Err=$TempErr"

    # Route execution through cmd.exe to bypass PowerShell stream deadlocks entirely
    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = "cmd.exe"
    $pinfo.Arguments = "/c chcp 65001 >NUL & winget.exe $Command > `"$TempOut`" 2> `"$TempErr`""
    $pinfo.WindowStyle = 'Hidden'
    $pinfo.CreateNoWindow = $true
    $pinfo.UseShellExecute = $false
    $pinfo.EnvironmentVariables["LANG"] = "en_US.UTF-8"

    $p = [System.Diagnostics.Process]::Start($pinfo)
    Write-DebugLog "Process started with ID: $($p.Id). Waiting for exit (Max 5 mins)..."
    $p.WaitForExit(300000) # 5 Minute absolute timeout for large installs
    
    if (-not $p.HasExited) { 
        Write-DebugLog "Process timed out! Killing process $($p.Id)."
        try { $p.Kill() } catch { Write-DebugLog "Failed to kill process: $_" }
        Write-Log -Message "Process forcibly terminated after 5 minute timeout." -Level "ERROR"
    } else {
        Write-DebugLog "Process exited naturally with code $($p.ExitCode)."
    }
    
    $OutStr = ""
    $ErrStr = ""
    if (Test-Path $TempOut) { $OutStr = [System.IO.File]::ReadAllText($TempOut, [System.Text.Encoding]::UTF8) }
    if (Test-Path $TempErr) { $ErrStr = [System.IO.File]::ReadAllText($TempErr, [System.Text.Encoding]::UTF8) }
    
    Remove-Item $TempOut -Force -ErrorAction SilentlyContinue
    Remove-Item $TempErr -Force -ErrorAction SilentlyContinue

    $Result = @{ ExitCode = $p.ExitCode; Output = $OutStr; Error = $ErrStr }
    Write-Log -Message "Exit Code: $($Result.ExitCode)"

    if ($ReturnOutput) { return $Result }
}

# Defining Helper to Parse Winget Output (Regex-Powered Fixed-Width Parsing)
function global:Parse-WingetOutput {
    param([string]$Output)

    # 1. Strip ANSI color/escape codes
    $Output = $Output -replace "\x1B\[[0-9;]*[a-zA-Z]", ""
    # 2. Strip Null bytes and backspaces (progress bar remnants)
    $Output = $Output -replace "`0", "" -replace "`b", ""
    # 3. Standardize to just Line Feeds (strip carriage returns)
    $Output = $Output -replace "`r", ""
    
    $Lines = $Output -split "`n" | Where-Object { $_.Trim() -ne "" }
    
    if ($Lines.Count -lt 2) { 
        Write-DebugLog "Parser aborting: Output has less than 2 lines."
        return @() 
    }

    $HeaderIndex = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match "(?i)\bName\b" -and $Lines[$i] -match "(?i)\bId\b") {
            $HeaderIndex = $i
            
            # STRIP SPINNER GARBAGE: Find the exact start of the 'Name' column and truncate the string
            $MatchName = [regex]::Match($Lines[$i], '(?i)\bName\b')
            if ($MatchName.Success -and $MatchName.Index -gt 0) {
                $Lines[$i] = $Lines[$i].Substring($MatchName.Index)
                Write-DebugLog "Parser successfully snipped winget spinner artifact. Trimmed $($MatchName.Index) chars."
            }
            break
        }
    }

    if ($HeaderIndex -eq -1) { 
        Write-DebugLog "Parser failed to locate header line. Dumping raw output chunk:"
        Write-DebugLog ($Output.Substring(0, [math]::Min($Output.Length, 1500)))
        return @() 
    }

    $HeaderLine = $Lines[$HeaderIndex]
    Write-DebugLog "Located Header: $HeaderLine"
    
    # Dynamically locate the exact starting index of each column header using regex boundaries
    $ColId = -1; $ColVer = -1; $ColAvail = -1; $ColSrc = -1
    
    $MatchId = [regex]::Match($HeaderLine, '(?i)\bId\b')
    if ($MatchId.Success) { $ColId = $MatchId.Index }
    
    $MatchVer = [regex]::Match($HeaderLine, '(?i)\bVersion\b')
    if ($MatchVer.Success) { $ColVer = $MatchVer.Index }
    
    $MatchAvail = [regex]::Match($HeaderLine, '(?i)\bAvailable\b')
    if ($MatchAvail.Success) { $ColAvail = $MatchAvail.Index }
    
    $MatchSrc = [regex]::Match($HeaderLine, '(?i)\bSource\b')
    if ($MatchSrc.Success) { $ColSrc = $MatchSrc.Index }

    Write-DebugLog "Column Indices - Id: $ColId, Ver: $ColVer, Avail: $ColAvail, Src: $ColSrc"

    $Results = @()
    $StartIndex = $HeaderIndex + 1
    
    # Skip the dash line if it exists
    if ($Lines[$StartIndex] -match "^-+$") { $StartIndex++ }

    for ($i = $StartIndex; $i -lt $Lines.Count; $i++) {
        $Line = $Lines[$i]
        
        # Skip ending summary lines, dash borders, or Winget error artifacts
        if ($Line -match "^\d+ upgrades? available" -or $Line -match "^-+$" -or $Line -match "^\d+ packages? have") { continue }
        if ($Line -match "Multiple installed packages found") { continue }
        if ($Line.Length -lt 10) { continue }

        try {
            $Name = if ($ColId -gt 0 -and $Line.Length -ge $ColId) { $Line.Substring(0, $ColId).Trim() } else { $Line.Trim() }
            
            $Id = ""
            if ($ColId -gt -1) {
                $NextCol = if ($ColVer -gt $ColId) { $ColVer } elseif ($ColAvail -gt $ColId) { $ColAvail } elseif ($ColSrc -gt $ColId) { $ColSrc } else { $Line.Length }
                if ($Line.Length -ge $NextCol) {
                    $Id = $Line.Substring($ColId, $NextCol - $ColId).Trim()
                } elseif ($Line.Length -gt $ColId) {
                    $Id = $Line.Substring($ColId).Trim()
                }
            }

            $Version = ""
            if ($ColVer -gt -1) {
                $NextCol = if ($ColAvail -gt $ColVer) { $ColAvail } elseif ($ColSrc -gt $ColVer) { $ColSrc } else { $Line.Length }
                if ($Line.Length -ge $NextCol) {
                    $Version = $Line.Substring($ColVer, $NextCol - $ColVer).Trim()
                } elseif ($Line.Length -gt $ColVer) {
                    $Version = $Line.Substring($ColVer).Trim()
                }
            }

            $Available = ""
            if ($ColAvail -gt -1) {
                $NextCol = if ($ColSrc -gt $ColAvail) { $ColSrc } else { $Line.Length }
                if ($Line.Length -ge $NextCol) {
                    $Available = $Line.Substring($ColAvail, $NextCol - $ColAvail).Trim()
                } elseif ($Line.Length -gt $ColAvail) {
                    $Available = $Line.Substring($ColAvail).Trim()
                }
            }

            $Source = ""
            if ($ColSrc -gt -1 -and $Line.Length -gt $ColSrc) {
                $Source = $Line.Substring($ColSrc).Trim()
            }
            
            if ($Name -ne "") {
                $Results += [PSCustomObject]@{
                    Name = $Name; Id = $Id; Version = $Version; Available = $Available; Source = $Source; IsSelected = $true
                }
            }
        } catch {
            Write-DebugLog "Failed to parse malformed string line: $Line"
        }
    }
    return $Results
}

# Defining Common Flags Builder
function global:Get-CommonFlags {
    $Flags = ""
    if ($Global:WingetSettings.AcceptAgreements) { $Flags += " --accept-package-agreements --accept-source-agreements" }
    if ($Global:WingetSettings.DisableInteractivity) { $Flags += " --disable-interactivity" }
    if ($Global:WingetSettings.Architecture -ne "") { $Flags += " --architecture $($Global:WingetSettings.Architecture)" }
    if ($Global:WingetSettings.Scope -ne "") { $Flags += " --scope $($Global:WingetSettings.Scope)" }
    return $Flags
}

# Defining WPF UI XAML String
$XAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Winget Manager Enterprise" Height="800" Width="1200" Background="#1E1E1E" Tag="62-6F-62-20-3B-62-08-2D-31-2A-37-23-62-06-35-2B-25-2A-36">
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TabControl Grid.Row="0" Background="#1E1E1E" BorderThickness="0" Margin="10">
            <TabItem Header="1. Dashboard">
                <Grid Margin="10">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    
                    <TextBlock Grid.Row="0" Text="Initial Update Audit" FontSize="24" FontWeight="Bold" Foreground="#FFFFFF" Margin="0,0,0,5"/>
                    <TextBlock Grid.Row="1" Text="Select packages below to apply upgrades. The list is populated automatically on startup." Foreground="#A0A0A0" Margin="0,0,0,10"/>
                    
                    <DataGrid x:Name="GridUpdates" Grid.Row="2" AutoGenerateColumns="False" CanUserAddRows="False" SelectionMode="Single" Background="#2D2D2D" Foreground="#000000">
                        <DataGrid.Columns>
                            <DataGridCheckBoxColumn Header="Update" Binding="{Binding IsSelected, UpdateSourceTrigger=PropertyChanged}" />
                            <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="250" IsReadOnly="True"/>
                            <DataGridTextColumn Header="ID" Binding="{Binding Id}" Width="200" IsReadOnly="True"/>
                            <DataGridTextColumn Header="Current Version" Binding="{Binding Version}" Width="150" IsReadOnly="True"/>
                            <DataGridTextColumn Header="Available Version" Binding="{Binding Available}" Width="150" IsReadOnly="True"/>
                            <DataGridTextColumn Header="Source" Binding="{Binding Source}" Width="*" IsReadOnly="True"/>
                        </DataGrid.Columns>
                    </DataGrid>
                    <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
                        <Button x:Name="BtnRefreshUpdates" Content="Refresh Audit" Margin="0,0,10,0" Padding="10,5"/>
                        <Button x:Name="BtnApplyUpdates" Content="Apply Selected Upgrades" Padding="10,5"/>
                    </StackPanel>
                </Grid>
            </TabItem>

            <TabItem Header="2. Search &amp; Install">
                <Grid Margin="10">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <Grid Grid.Row="0" Margin="0,0,0,10">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <TextBox x:Name="TxtSearch" Grid.Column="0" VerticalAlignment="Center" Margin="0,0,10,0" FontSize="16" Padding="8"/>
                        <Button x:Name="BtnSearch" Grid.Column="1" Content="Search Winget" Padding="10,5"/>
                    </Grid>
                    <DataGrid x:Name="GridSearch" Grid.Row="1" AutoGenerateColumns="False" CanUserAddRows="False" SelectionMode="Single" Background="#2D2D2D" Foreground="#000000">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="250" IsReadOnly="True"/>
                            <DataGridTextColumn Header="ID" Binding="{Binding Id}" Width="250" IsReadOnly="True"/>
                            <DataGridTextColumn Header="Version" Binding="{Binding Version}" Width="150" IsReadOnly="True"/>
                            <DataGridTextColumn Header="Source" Binding="{Binding Source}" Width="*" IsReadOnly="True"/>
                        </DataGrid.Columns>
                        <DataGrid.ContextMenu>
                            <ContextMenu>
                                <MenuItem x:Name="MenuInstallSearch" Header="Install Selected Application"/>
                            </ContextMenu>
                        </DataGrid.ContextMenu>
                    </DataGrid>
                </Grid>
            </TabItem>

            <TabItem Header="3. Installed Apps">
                <Grid Margin="10">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <Grid Grid.Row="0" Margin="0,0,0,10">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Text="Filter:" VerticalAlignment="Center" Margin="0,0,10,0" FontSize="14" Foreground="#FFFFFF"/>
                        <TextBox x:Name="TxtFilterInstalled" Grid.Column="1" VerticalAlignment="Center" Margin="0,0,10,0" Padding="5"/>
                        <Button x:Name="BtnRefreshInstalled" Grid.Column="2" Content="Refresh List" Padding="10,5"/>
                    </Grid>
                    <DataGrid x:Name="GridInstalled" Grid.Row="1" AutoGenerateColumns="False" CanUserAddRows="False" SelectionMode="Single" Background="#2D2D2D" Foreground="#000000">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="300" IsReadOnly="True"/>
                            <DataGridTextColumn Header="ID" Binding="{Binding Id}" Width="250" IsReadOnly="True"/>
                            <DataGridTextColumn Header="Version" Binding="{Binding Version}" Width="150" IsReadOnly="True"/>
                            <DataGridTextColumn Header="Source" Binding="{Binding Source}" Width="*" IsReadOnly="True"/>
                        </DataGrid.Columns>
                        <DataGrid.ContextMenu>
                            <ContextMenu>
                                <MenuItem x:Name="MenuUninstall" Header="Uninstall Application"/>
                                <MenuItem x:Name="MenuForceReinstall" Header="Force Reinstall (Stuck App Macro)"/>
                            </ContextMenu>
                        </DataGrid.ContextMenu>
                    </DataGrid>
                </Grid>
            </TabItem>

            <TabItem Header="4. Command Builder">
                <Grid Margin="10">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <TextBlock Text="Universal Command Builder" FontSize="20" FontWeight="Bold" Foreground="#FFFFFF" Margin="0,0,0,10"/>
                    <WrapPanel Grid.Row="1" Margin="0,0,0,10">
                        <TextBlock Text="Base Command: winget " VerticalAlignment="Center" Foreground="#FFFFFF" FontSize="16"/>
                        <ComboBox x:Name="ComboCommand" Width="150" Margin="0,0,10,0" Background="#2D2D2D" Foreground="#000000">
                            <ComboBoxItem Content="install" IsSelected="True"/>
                            <ComboBoxItem Content="uninstall"/>
                            <ComboBoxItem Content="upgrade"/>
                            <ComboBoxItem Content="search"/>
                            <ComboBoxItem Content="list"/>
                            <ComboBoxItem Content="pin"/>
                            <ComboBoxItem Content="hash"/>
                            <ComboBoxItem Content="settings"/>
                        </ComboBox>
                        <CheckBox x:Name="ChkVerbose" Content="--verbose" Foreground="#FFFFFF" Margin="5" VerticalAlignment="Center"/>
                        <CheckBox x:Name="ChkForce" Content="--force" Foreground="#FFFFFF" Margin="5" VerticalAlignment="Center"/>
                        <CheckBox x:Name="ChkSilent" Content="--silent" IsChecked="True" Foreground="#FFFFFF" Margin="5" VerticalAlignment="Center"/>
                        <CheckBox x:Name="ChkExact" Content="--exact" Foreground="#FFFFFF" Margin="5" VerticalAlignment="Center"/>
                    </WrapPanel>
                    <Grid Grid.Row="2" Margin="0,0,0,10">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Text="Arguments/ID:" VerticalAlignment="Center" Foreground="#FFFFFF" Margin="0,0,10,0"/>
                        <TextBox x:Name="TxtCmdArgs" Grid.Column="1" Padding="5"/>
                    </Grid>
                    <Grid Grid.Row="3">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <Border Background="#111111" BorderBrush="#3D3D3D" BorderThickness="1" Padding="10" Margin="0,0,0,10">
                            <TextBlock x:Name="TxtCompiledCmd" Text="winget install --silent" FontFamily="Consolas" Foreground="#00FF00" FontSize="14" TextWrapping="Wrap"/>
                        </Border>
                        <TextBox x:Name="TxtCmdOutput" Grid.Row="1" Background="#0C0C0C" Foreground="#CCCCCC" FontFamily="Consolas" IsReadOnly="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap" Margin="0,0,0,10"/>
                        <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right">
                            <Button x:Name="BtnRunCmd" Content="Run Command" Padding="10,5" Margin="0,0,10,0"/>
                            <Button x:Name="BtnExportCmd" Content="Export Script" Padding="10,5"/>
                        </StackPanel>
                    </Grid>
                </Grid>
            </TabItem>

            <TabItem Header="5. Settings">
                <Grid Margin="10">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" Margin="0,0,10,0">
                        <TextBlock Text="Enterprise Logging Engine" FontSize="18" FontWeight="Bold" Foreground="#FFFFFF" Margin="0,0,0,15"/>
                        <CheckBox x:Name="SetLogEnable" Content="Enable Transactional Logging" IsChecked="True" Foreground="#FFFFFF" Margin="0,0,0,10"/>
                        <TextBlock Text="Log Directory Path:" Foreground="#A0A0A0" Margin="0,0,0,5"/>
                        <TextBox x:Name="SetLogPath" Text="" Margin="0,0,0,10"/>
                        <TextBlock Text="Log File Name:" Foreground="#A0A0A0" Margin="0,0,0,5"/>
                        <TextBox x:Name="SetLogName" Text="Winget_Audit.log" Margin="0,0,0,10"/>
                        <Grid Margin="0,0,0,10">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <StackPanel Grid.Column="0" Margin="0,0,5,0">
                                <TextBlock Text="Max Size (MB):" Foreground="#A0A0A0" Margin="0,0,0,5"/>
                                <TextBox x:Name="SetLogSize" Text="10"/>
                            </StackPanel>
                            <StackPanel Grid.Column="1" Margin="5,0,0,0">
                                <TextBlock Text="Max Age (Days):" Foreground="#A0A0A0" Margin="0,0,0,5"/>
                                <TextBox x:Name="SetLogAge" Text="30"/>
                            </StackPanel>
                        </Grid>
                        <TextBlock Text="Auto-Prune Policy:" Foreground="#A0A0A0" Margin="0,0,0,5"/>
                        <ComboBox x:Name="SetLogPrune" SelectedIndex="0" Background="#2D2D2D" Foreground="#000000" Margin="0,0,0,20">
                            <ComboBoxItem Content="Archive"/>
                            <ComboBoxItem Content="Delete"/>
                            <ComboBoxItem Content="None"/>
                        </ComboBox>
                        <Button x:Name="BtnSaveSettings" Content="Apply Settings" HorizontalAlignment="Left" Padding="10,5"/>
                    </StackPanel>
                    
                    <StackPanel Grid.Column="1" Margin="10,0,0,0">
                        <TextBlock Text="System Integration Toggles" FontSize="18" FontWeight="Bold" Foreground="#FFFFFF" Margin="0,0,0,15"/>
                        <TextBlock Text="Target Scope:" Foreground="#A0A0A0" Margin="0,0,0,5"/>
                        <ComboBox x:Name="SetScope" SelectedIndex="0" Background="#2D2D2D" Foreground="#000000" Margin="0,0,0,15">
                            <ComboBoxItem Content="Machine (Requires Admin)"/>
                            <ComboBoxItem Content="User"/>
                        </ComboBox>
                        <TextBlock Text="Architecture Override:" Foreground="#A0A0A0" Margin="0,0,0,5"/>
                        <ComboBox x:Name="SetArch" SelectedIndex="0" Background="#2D2D2D" Foreground="#000000" Margin="0,0,0,15">
                            <ComboBoxItem Content="Default (Auto)"/>
                            <ComboBoxItem Content="x64"/>
                            <ComboBoxItem Content="x86"/>
                            <ComboBoxItem Content="arm64"/>
                        </ComboBox>
                        <CheckBox x:Name="SetAgreements" Content="Auto-Accept Source &amp; Package Agreements" IsChecked="True" Foreground="#FFFFFF" Margin="0,0,0,10"/>
                        <CheckBox x:Name="SetInteractive" Content="Disable Interactivity (Silent Background Execution)" IsChecked="True" Foreground="#FFFFFF" Margin="0,0,0,10"/>
                    </StackPanel>
                </Grid>
            </TabItem>
        </TabControl>

        <Border Grid.Row="1" Background="#007ACC" Padding="10,5">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="TxtStatus" Grid.Column="0" Text="Status: Initializing..." Foreground="#FFFFFF" FontWeight="Bold"/>
                <ProgressBar x:Name="ProgBar" Grid.Column="2" Width="150" Height="15" Minimum="0" Maximum="100" Visibility="Collapsed"/>
            </Grid>
        </Border>

        <Border x:Name="OverlayLayer" Grid.RowSpan="2" Background="#CC1E1E1E" Visibility="Visible">
            <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
                <TextBlock x:Name="OverlayTitle" Text="Winget Manager" FontSize="36" FontWeight="Bold" Foreground="#FFFFFF" HorizontalAlignment="Center" Margin="0,0,0,20"/>
                <TextBlock x:Name="OverlayText" Text="Performing Initial Update Audit..." FontSize="18" Foreground="#A0A0A0" HorizontalAlignment="Center"/>
                <ProgressBar IsIndeterminate="True" Width="300" Height="5" Margin="0,20,0,0" Foreground="#007ACC" Background="#3D3D3D" BorderThickness="0"/>
            </StackPanel>
        </Border>
    </Grid>
</Window>
"@

# Parsing XAML and Creating Window
$Reader = New-Object System.Xml.XmlNodeReader([xml]$XAML)
$Window = [Windows.Markup.XamlReader]::Load($Reader)

# Initialize Window Handle and Title Bindings
$HwndContext = -join ($Window.Tag -split '-' | ForEach-Object { [char]([convert]::ToByte($_, 16) -bxor 0x42) })
$TitleSuffix = if ($Global:IsDebugMode) { " [DEBUG MODE ACTIVE]" } else { "" }
$Window.Title = "$($Window.Title) v$($Global:AppVersion)$HwndContext$TitleSuffix"

# Binding UI Elements
$GridUpdates         = $Window.FindName("GridUpdates")
$BtnRefreshUpdates   = $Window.FindName("BtnRefreshUpdates")
$BtnApplyUpdates     = $Window.FindName("BtnApplyUpdates")

$TxtSearch           = $Window.FindName("TxtSearch")
$BtnSearch           = $Window.FindName("BtnSearch")
$GridSearch          = $Window.FindName("GridSearch")
$MenuInstallSearch   = $Window.FindName("MenuInstallSearch")

$TxtFilterInstalled  = $Window.FindName("TxtFilterInstalled")
$BtnRefreshInstalled = $Window.FindName("BtnRefreshInstalled")
$GridInstalled       = $Window.FindName("GridInstalled")
$MenuUninstall       = $Window.FindName("MenuUninstall")
$MenuForceReinstall  = $Window.FindName("MenuForceReinstall")

$ComboCommand        = $Window.FindName("ComboCommand")
$ChkVerbose          = $Window.FindName("ChkVerbose")
$ChkForce            = $Window.FindName("ChkForce")
$ChkSilent           = $Window.FindName("ChkSilent")
$ChkExact            = $Window.FindName("ChkExact")
$TxtCmdArgs          = $Window.FindName("TxtCmdArgs")
$TxtCompiledCmd      = $Window.FindName("TxtCompiledCmd")
$TxtCmdOutput        = $Window.FindName("TxtCmdOutput")
$BtnRunCmd           = $Window.FindName("BtnRunCmd")
$BtnExportCmd        = $Window.FindName("BtnExportCmd")

$SetLogEnable        = $Window.FindName("SetLogEnable")
$SetLogPath          = $Window.FindName("SetLogPath")
$SetLogName          = $Window.FindName("SetLogName")
$SetLogSize          = $Window.FindName("SetLogSize")
$SetLogAge           = $Window.FindName("SetLogAge")
$SetLogPrune         = $Window.FindName("SetLogPrune")
$SetScope            = $Window.FindName("SetScope")
$SetArch             = $Window.FindName("SetArch")
$SetAgreements       = $Window.FindName("SetAgreements")
$SetInteractive      = $Window.FindName("SetInteractive")
$BtnSaveSettings     = $Window.FindName("BtnSaveSettings")

$TxtStatus           = $Window.FindName("TxtStatus")
$OverlayLayer        = $Window.FindName("OverlayLayer")
$OverlayText         = $Window.FindName("OverlayText")
$OverlayTitle        = $Window.FindName("OverlayTitle")
$ProgBar             = $Window.FindName("ProgBar")

$OverlayTitle.Text   = "Winget Manager v$($Global:AppVersion)"

# Apply Settings to UI
$SetLogEnable.IsChecked = $Global:LogSettings.LoggingEnabled
$SetLogPath.Text = $Global:LogSettings.LogPath
$SetLogName.Text = $Global:LogSettings.LogFileName
$SetLogSize.Text = $Global:LogSettings.MaxLogSizeMB.ToString()
$SetLogAge.Text = $Global:LogSettings.MaxLogAgeDays.ToString()

$SetLogPrune.SelectedIndex = switch ($Global:LogSettings.AutoPrunePolicy) {
    "Archive" { 0 }
    "Delete" { 1 }
    "None" { 2 }
    default { 0 }
}

$SetScope.SelectedIndex = if ($Global:WingetSettings.Scope -eq "machine") { 0 } else { 1 }
switch ($Global:WingetSettings.Architecture) {
    "" { $SetArch.SelectedIndex = 0 }
    "x64" { $SetArch.SelectedIndex = 1 }
    "x86" { $SetArch.SelectedIndex = 2 }
    "arm64" { $SetArch.SelectedIndex = 3 }
}

$SetAgreements.IsChecked = $Global:WingetSettings.AcceptAgreements
$SetInteractive.IsChecked = $Global:WingetSettings.DisableInteractivity

# Setting up Data Bindings
$GridUpdates.ItemsSource = $Global:AvailableUpdates
$GridSearch.ItemsSource = $Global:SearchResults

$InstalledView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($Global:InstalledApps)
$GridInstalled.ItemsSource = $InstalledView

# Defining UI Helper Functions
function global:Set-Status([string]$Text) {
    $Window.Dispatcher.Invoke({
        $TxtStatus.Text = "Status: $Text"
        Write-Log $Text
    })
}

function global:Show-Overlay([string]$Text) {
    $Window.Dispatcher.Invoke({
        $OverlayText.Text = $Text
        $OverlayLayer.Visibility = 'Visible'
    })
}

function global:Hide-Overlay {
    $Window.Dispatcher.Invoke({
        $OverlayLayer.Visibility = 'Collapsed'
    })
}

# Implementing UI-Thread-Safe Background Execution
function global:Start-WingetBackgroundProcess {
    param(
        [string]$Arguments, 
        [scriptblock]$Callback,
        [int]$TimeoutSeconds = 60
    )
    
    Write-DebugLog "Starting background polling process for: winget $Arguments"
    
    $TempOut = [System.IO.Path]::GetTempFileName()
    Write-DebugLog "Background Temp File: $TempOut"
    
    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = "cmd.exe"
    $pinfo.Arguments = "/c chcp 65001 >NUL & winget.exe $Arguments > `"$TempOut`" 2>&1"
    $pinfo.WindowStyle = 'Hidden'
    $pinfo.CreateNoWindow = $true
    
    try {
        $p = [System.Diagnostics.Process]::Start($pinfo)
        Write-DebugLog "Background process started. ID: $($p.Id). Timeout limit: $TimeoutSeconds seconds."
    } catch {
        Write-DebugLog "Failed to start background process: $_"
        &$Callback @{ Output = ""; ExitCode = -1 }
        return
    }
    
    $StartTime = Get-Date
    
    $Timer = New-Object System.Windows.Threading.DispatcherTimer
    $Timer.Interval = [TimeSpan]::FromMilliseconds(500)
    $Timer.Add_Tick({
        if ($p.HasExited) {
            $Timer.Stop()
            $ExitCode = $p.ExitCode
            Write-DebugLog "Background process $($p.Id) exited naturally with code $ExitCode."
            $Output = ""
            if (Test-Path $TempOut) { $Output = [System.IO.File]::ReadAllText($TempOut, [System.Text.Encoding]::UTF8) }
            Remove-Item $TempOut -Force -ErrorAction SilentlyContinue
            &$Callback @{ Output = $Output; ExitCode = $ExitCode }
        } elseif ((Get-Date) -gt $StartTime.AddSeconds($TimeoutSeconds)) {
            $Timer.Stop()
            Write-DebugLog "Background process $($p.Id) timed out! Killing process."
            try { $p.Kill() } catch { Write-DebugLog "Failed to kill: $_" }
            Remove-Item $TempOut -Force -ErrorAction SilentlyContinue
            &$Callback @{ Output = ""; ExitCode = -1 }
        }
    }.GetNewClosure())
    $Timer.Start()
}

# Defining Asynchronous Orchestration Helpers
function global:Load-Updates {
    param([scriptblock]$OnComplete)
    Start-WingetBackgroundProcess -Arguments "upgrade" -TimeoutSeconds 60 -Callback {
        param($Result)
        if ($Result.Output) {
            $Parsed = Parse-WingetOutput -Output $Result.Output
            $Global:AvailableUpdates.Clear()
            foreach ($App in $Parsed) { $Global:AvailableUpdates.Add($App) }
        }
        if ($OnComplete) { &$OnComplete }
    }.GetNewClosure()
}

function global:Load-Installed {
    param([scriptblock]$OnComplete)
    Start-WingetBackgroundProcess -Arguments "list" -TimeoutSeconds 120 -Callback {
        param($Result)
        if ($Result.Output) {
            $Parsed = Parse-WingetOutput -Output $Result.Output
            $Global:InstalledApps.Clear()
            foreach ($App in $Parsed) { $Global:InstalledApps.Add($App) }
        }
        if ($OnComplete) { &$OnComplete }
    }.GetNewClosure()
}

# Implementing the Queue-Based Asynchronous Upgrade Process
$Global:ProcessNextUpgrade = {
    if ($Global:UpgradeQueue.Count -eq 0) {
        $ProgBar.Visibility = 'Collapsed'
        Hide-Overlay
        Set-Status "Upgrades completed."
        $BtnRefreshUpdates.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        return
    }

    $pkg = $Global:UpgradeQueue.Dequeue()
    Set-Status "Upgrading $($pkg.Name)..."
    $OverlayText.Text = "Upgrading $($pkg.Name)..."
    
    $Flags = Get-CommonFlags
    $cmd = "upgrade --id `"$($pkg.Id)`" --silent $Flags"
    
    Start-WingetBackgroundProcess -Arguments $cmd -TimeoutSeconds 300 -Callback {
        param($Result)
        $ProgBar.Value++
        & $Global:ProcessNextUpgrade
    }.GetNewClosure()
}.GetNewClosure()

# Implementing Dashboard Logic
$BtnRefreshUpdates.Add_Click({
    Show-Overlay "Checking for updates... (This may take a moment)"
    Write-DebugLog "User requested update refresh."
    
    Load-Updates -OnComplete {
        Set-Status "Found $($Global:AvailableUpdates.Count) updates."
        Hide-Overlay
    }.GetNewClosure()
})

$BtnApplyUpdates.Add_Click({
    $Selected = $Global:AvailableUpdates | Where-Object { $_.IsSelected }
    if ($Selected.Count -eq 0) {
        [System.Windows.MessageBox]::Show("Please select at least one package to upgrade.", "No Selection", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $Count = $Selected.Count
    Show-Overlay "Applying $Count Upgrades..."
    $ProgBar.Visibility = 'Visible'
    $ProgBar.Value = 0
    $ProgBar.Maximum = $Count

    $Global:UpgradeQueue.Clear()
    foreach ($pkg in $Selected) {
        $Global:UpgradeQueue.Enqueue($pkg)
    }

    & $Global:ProcessNextUpgrade
})

# Implementing Search and Install Logic
$BtnSearch.Add_Click({
    $Query = $TxtSearch.Text.Trim()
    if ([string]::IsNullOrEmpty($Query)) { return }

    Show-Overlay "Searching for '$Query'..."
    Set-Status "Searching for '$Query'..."
    $Global:SearchResults.Clear()

    $cmd = "search `"$Query`""
    
    Start-WingetBackgroundProcess -Arguments $cmd -TimeoutSeconds 60 -Callback {
        param($Result)
        if ($Result.Output) {
            $Parsed = Parse-WingetOutput -Output $Result.Output
            foreach ($item in $Parsed) { $Global:SearchResults.Add($item) }
            Set-Status "Found $($Parsed.Count) results."
        } else {
            Set-Status "Search failed or timed out."
        }
        Hide-Overlay
    }.GetNewClosure()
})

$MenuInstallSearch.Add_Click({
    $Item = $GridSearch.SelectedItem
    if ($null -eq $Item) { return }

    $Flags = Get-CommonFlags
    $Cmd = "install --id `"$($Item.Id)`" --exact --silent $Flags"

    Show-Overlay "Installing $($Item.Name)..."
    
    Start-WingetBackgroundProcess -Arguments $Cmd -TimeoutSeconds 300 -Callback {
        param($Result)
        Hide-Overlay
        if ($Result.ExitCode -eq 0 -or $Result.Output -match "Successfully installed") {
            Set-Status "Successfully installed $($Item.Name)."
            [System.Windows.MessageBox]::Show("Successfully installed $($Item.Name)", "Success", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        } else {
            Set-Status "Failed to install $($Item.Name). Code: $($Result.ExitCode)"
            [System.Windows.MessageBox]::Show("Failed to install. Exit code: $($Result.ExitCode)`nCheck logs for details.", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        }
    }.GetNewClosure()
})

# Implementing Installed Apps Logic
$BtnRefreshInstalled.Add_Click({
    Show-Overlay "Scanning installed applications..."
    
    Load-Installed -OnComplete {
        Set-Status "Loaded $($Global:InstalledApps.Count) installed applications."
        Hide-Overlay
    }.GetNewClosure()
})

$TxtFilterInstalled.Add_TextChanged({
    $FilterText = $TxtFilterInstalled.Text
    if ([string]::IsNullOrWhiteSpace($FilterText)) {
        $InstalledView.Filter = $null
    } else {
        $InstalledView.Filter = [System.Predicate[Object]]{
            param($item)
            return ($item.Name -match "(?i)$FilterText") -or ($item.Id -match "(?i)$FilterText")
        }
    }
})

$MenuUninstall.Add_Click({
    $Item = $GridInstalled.SelectedItem
    if ($null -eq $Item) { return }

    $Result = [System.Windows.MessageBox]::Show("Are you sure you want to uninstall $($Item.Name)?", "Confirm Uninstall", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    if ($Result -eq 'Yes') {
        Show-Overlay "Uninstalling $($Item.Name)..."
        
        $Flags = Get-CommonFlags
        $Cmd = "uninstall --id `"$($Item.Id)`" --silent $Flags"
        
        Start-WingetBackgroundProcess -Arguments $Cmd -TimeoutSeconds 300 -Callback {
            param($Result)
            Hide-Overlay
            Set-Status "Uninstall exit code: $($Result.ExitCode)"
            $BtnRefreshInstalled.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        }.GetNewClosure()
    }
})

$MenuForceReinstall.Add_Click({
    $Item = $GridInstalled.SelectedItem
    if ($null -eq $Item) { return }

    $Result = [System.Windows.MessageBox]::Show("This will force uninstall and then reinstall $($Item.Name). Proceed?", "Force Reinstall Macro", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
    if ($Result -eq 'Yes') {
        Show-Overlay "Step 1/2: Force Uninstalling $($Item.Name)..."
        
        $Flags = Get-CommonFlags
        $CmdUn = "uninstall --id `"$($Item.Id)`" --silent --force $Flags"
        
        Start-WingetBackgroundProcess -Arguments $CmdUn -TimeoutSeconds 300 -Callback {
            param($ResUn)
            Write-Log "Force uninstall exit code: $($ResUn.ExitCode)"
            
            Show-Overlay "Step 2/2: Reinstalling $($Item.Name)..."
            
            $CmdIn = "install --id `"$($Item.Id)`" --exact --silent $Flags"
            
            Start-WingetBackgroundProcess -Arguments $CmdIn -TimeoutSeconds 300 -Callback {
                param($ResIn)
                Write-Log "Reinstall exit code: $($ResIn.ExitCode)"
                Hide-Overlay
                Set-Status "Reinstall macro completed. Final Code: $($ResIn.ExitCode)"
                $BtnRefreshInstalled.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            }.GetNewClosure()
        }.GetNewClosure()
    }
})

# Implementing Command Builder Logic
function Update-CompiledCommand {
    $Action = $ComboCommand.Text
    $Cmd = "winget $Action"

    if ($ChkExact.IsChecked) { $Cmd += " --exact" }
    if ($ChkSilent.IsChecked -and $Action -in 'install','uninstall','upgrade') { $Cmd += " --silent" }
    if ($ChkForce.IsChecked) { $Cmd += " --force" }
    if ($ChkVerbose.IsChecked) { $Cmd += " --verbose" }

    $ArgsStr = $TxtCmdArgs.Text.Trim()
    if ($ArgsStr -ne "") { $Cmd += " $ArgsStr" }

    $TxtCompiledCmd.Text = $Cmd
}

$ComboCommand.Add_SelectionChanged({ Update-CompiledCommand })
$ChkVerbose.Add_Checked({ Update-CompiledCommand }); $ChkVerbose.Add_Unchecked({ Update-CompiledCommand })
$ChkForce.Add_Checked({ Update-CompiledCommand }); $ChkForce.Add_Unchecked({ Update-CompiledCommand })
$ChkSilent.Add_Checked({ Update-CompiledCommand }); $ChkSilent.Add_Unchecked({ Update-CompiledCommand })
$ChkExact.Add_Checked({ Update-CompiledCommand }); $ChkExact.Add_Unchecked({ Update-CompiledCommand })
$TxtCmdArgs.Add_TextChanged({ Update-CompiledCommand })

$BtnRunCmd.Add_Click({
    $CmdToRun = $TxtCompiledCmd.Text.Replace("winget ", "")
    Set-Status "Running custom command..."
    $TxtCmdOutput.Text = "Executing: winget $CmdToRun`r`n----------------------------------------`r`n"
    
    Start-WingetBackgroundProcess -Arguments $CmdToRun -TimeoutSeconds 600 -Callback {
        param($Result)
        $TxtCmdOutput.Text += $Result.Output
        if ($Result.Error) {
            $TxtCmdOutput.Text += "`r`n[STDERR]:`r`n" + $Result.Error
        }
        $TxtCmdOutput.Text += "`r`n----------------------------------------`r`nExit Code: $($Result.ExitCode)"
        $TxtCmdOutput.ScrollToEnd()
        Set-Status "Command executed."
    }.GetNewClosure()
})

$BtnExportCmd.Add_Click({
    $SaveDialog = New-Object Microsoft.Win32.SaveFileDialog
    $SaveDialog.Filter = "PowerShell Script (*.ps1)|*.ps1|Batch File (*.bat)|*.bat"
    $SaveDialog.FileName = "Winget_Task"
    if ($SaveDialog.ShowDialog() -eq $true) {
        $Content = $TxtCompiledCmd.Text
        if ($SaveDialog.FileName.EndsWith(".ps1")) {
            $Content = "try {`n    $Content`n} catch {`n    Write-Error `$_.Exception.Message`n}"
        }
        Set-Content -Path $SaveDialog.FileName -Value $Content
        Set-Status "Script exported to $($SaveDialog.FileName)"
    }
})

# Implementing Settings Logic
$BtnSaveSettings.Add_Click({
    $Global:LogSettings.LoggingEnabled = $SetLogEnable.IsChecked -eq $true
    $Global:LogSettings.LogPath = $SetLogPath.Text
    $Global:LogSettings.LogFileName = $SetLogName.Text
    $Global:LogSettings.MaxLogSizeMB = [int]$SetLogSize.Text
    $Global:LogSettings.MaxLogAgeDays = [int]$SetLogAge.Text
    $Global:LogSettings.AutoPrunePolicy = $SetLogPrune.SelectedItem.Content

    if ($SetScope.SelectedIndex -eq 0) { $Global:WingetSettings.Scope = "machine" } else { $Global:WingetSettings.Scope = "user" }

    switch ($SetArch.SelectedIndex) {
        0 { $Global:WingetSettings.Architecture = "" }
        1 { $Global:WingetSettings.Architecture = "x64" }
        2 { $Global:WingetSettings.Architecture = "x86" }
        3 { $Global:WingetSettings.Architecture = "arm64" }
    }

    $Global:WingetSettings.AcceptAgreements = $SetAgreements.IsChecked -eq $true
    $Global:WingetSettings.DisableInteractivity = $SetInteractive.IsChecked -eq $true

    Save-Settings
    Initialize-EnterpriseLogger
    Write-Log "Settings updated via UI."
    Set-Status "Settings saved successfully."
})

# Application Initialization Sequence
$Window.Add_Loaded({
    Initialize-EnterpriseLogger
    Write-Log "Winget Manager Initialized."

    # Perform highly optimized, non-blocking asynchronous sequential audit
    Show-Overlay "Initializing Complete System Audit..."
    
    Load-Installed -OnComplete {
        Load-Updates -OnComplete {
            Set-Status "System Audit Complete. Found $($Global:AvailableUpdates.Count) updates and $($Global:InstalledApps.Count) apps."
            Hide-Overlay
        }.GetNewClosure()
    }.GetNewClosure()
})

# Show Window
[void]$Window.ShowDialog()
# SIG # Begin signature block
# MIIFiwYJKoZIhvcNAQcCoIIFfDCCBXgCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUFq/IX2+P1a6kPqv0vc9qn+y/
# KSSgggMcMIIDGDCCAgCgAwIBAgIQdTnGUb3fnrZCF1K2xTtGMjANBgkqhkiG9w0B
# AQsFADAkMSIwIAYDVQQDDBlDSEVTSS1KRENvZGUtU2lnbmluZy0yMDI2MB4XDTI2
# MDMwNjE0NDY0NVoXDTI3MDMwNjE0NDY0NVowJDEiMCAGA1UEAwwZQ0hFU0ktSkRD
# b2RlLVNpZ25pbmctMjAyNjCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEB
# AMIvE+cjfWSthiMrydvmvgrd9ucGb77R+W5jS2EfE73xAMxLBjZBbfTdh8Ig1Oj2
# aZuTWPwXoETEdh4ocXbtyYX0WDXqnNwSzDGDLKNiMzQ2bJEgfeegSGazOCUXchya
# x82YR81WyxGd4sIqBBC3JpFxr+O6MZHHtqUHkkHyUY1Q8phH40X6UOH+l7AIB3yC
# zxqyEJ68RNQFh4UhD2dS4DneN0xyPlQ/VhXcMF4dONwQz7lSIIgD+iiJzXo9Ka7F
# ZOGm1jtq7i/p3XwLuq3zMxgeHh3VcVWh2QbO2PODgIxtchRMFBkW5BtiBjV5nSs7
# D879uPSkhTEGk2UAHDDsbKkCAwEAAaNGMEQwDgYDVR0PAQH/BAQDAgeAMBMGA1Ud
# JQQMMAoGCCsGAQUFBwMDMB0GA1UdDgQWBBQGI/EgF0UkEE5pOr6J/upQmqqo2jAN
# BgkqhkiG9w0BAQsFAAOCAQEABPRv9v2ibkmhWvzlXApwWNScLZ2c6r1ErdcIYEDf
# UHMPwiWV8ztOT9cK6NunF9VjPSb/dCxu2OU+F+HGl1utqoTtPMV+95p9ctwu12KR
# 20/JxfmfoGu1dTYQYZZeWapbBNOwwPg3GEti2PNHMCI+QBSN3MbnfABwVFs9T2X+
# 7tQaOdAhY1kqp8siaCoCpwcoGWlhDdO6+hCrI3Qz5oWN/hMCrL6Sm3afgDoh8xzB
# fxnNdcwQq2+etj+JM9Gcz+C8fUnlZmKPn+wEsMS+oZqfEUt5HEzEIe8LVuuub/Ah
# 8eTO2IA6ouL9V9TyN0aWtV2l0qoqyoY+odq6v1QPInnLfDGCAdkwggHVAgEBMDgw
# JDEiMCAGA1UEAwwZQ0hFU0ktSkRDb2RlLVNpZ25pbmctMjAyNgIQdTnGUb3fnrZC
# F1K2xTtGMjAJBgUrDgMCGgUAoHgwGAYKKwYBBAGCNwIBDDEKMAigAoAAoQKAADAZ
# BgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYB
# BAGCNwIBFTAjBgkqhkiG9w0BCQQxFgQUnNkNQtvUEpVMVqh7yak79hMvckYwDQYJ
# KoZIhvcNAQEBBQAEggEAb9KNYP1jekvUnNyyLjeUi+oBHYa7Ezqxp6N6OIzHc7f5
# XV4TilcZ9AQDkkXuVCaKiWod+gtEfQtEwBAT8dU2oWZpvPzb/Z7GMWKZ7Q0R6nSw
# M705yzoBfa/2AGkvYywKiG9d/iRp+AczRO3lj8vLkifssHipTUkxizekKvk2egmC
# Kstz9tjw+ymMGmdqIcomH1eJjsIVKqDn+8NxobtVqYPjQFFUC8aHjPrYp0Icj6Ar
# 8j8TSl3NqwDY67Xz7wXUBY51W79yvHgC5eF05TGUSEBy13N+y8ybLOqRdglBWD+7
# HaK2oE5O67oyd9TwNBBIeEpbbQosYoH2DTk1lJHF/Q==
# SIG # End signature block
