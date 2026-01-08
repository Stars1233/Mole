#!/usr/bin/env pwsh
# Mole - Windows System Maintenance Toolkit
# Main CLI entry point

#Requires -Version 5.1
param(
    [Parameter(Position = 0)]
    [string]$Command,
    
    [Parameter(Position = 1, ValueFromRemainingArguments)]
    [string[]]$CommandArgs,
    
    [switch]$Version,
    [switch]$ShowHelp
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Get script directory
$script:MOLE_ROOT = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:MOLE_BIN = Join-Path $script:MOLE_ROOT "bin"
$script:MOLE_LIB = Join-Path $script:MOLE_ROOT "lib"

# Import core
. "$script:MOLE_LIB\core\common.ps1"

# ============================================================================
# Version Info
# ============================================================================

$script:MOLE_VER = "1.0.0"
$script:MOLE_BUILD = "2026-01-07"

function Show-Version {
    $info = Get-MoleVersion
    Write-Host "Mole v$($info.Version)"
    Write-Host "Built: $($info.BuildDate)"
    Write-Host "PowerShell: $($info.PowerShell)"
    Write-Host "Windows: $($info.Windows)"
}

# ============================================================================
# Help
# ============================================================================

function Show-MainHelp {
    $cyan = $script:Colors.Cyan
    $gray = $script:Colors.Gray
    $green = $script:Colors.Green
    $nc = $script:Colors.NC
    
    Show-Banner
    
    Write-Host "  ${cyan}Windows System Maintenance Toolkit${nc}"
    Write-Host "  ${gray}Clean, optimize, and maintain your Windows system${nc}"
    Write-Host ""
    Write-Host "  ${green}COMMANDS:${nc}"
    Write-Host ""
    Write-Host "    ${cyan}clean${nc}       Deep system cleanup (caches, temp, logs)"
    Write-Host "    ${cyan}uninstall${nc}   Smart application uninstaller"
    Write-Host "    ${cyan}analyze${nc}     Visual disk space analyzer"
    Write-Host "    ${cyan}status${nc}      Real-time system monitor"
    Write-Host "    ${cyan}optimize${nc}    System optimization tasks"
    Write-Host "    ${cyan}purge${nc}       Clean project build artifacts"
    Write-Host ""
    Write-Host "  ${green}OPTIONS:${nc}"
    Write-Host ""
    Write-Host "    ${cyan}-Version${nc}    Show version information"
    Write-Host "    ${cyan}-ShowHelp${nc}   Show this help message"
    Write-Host ""
    Write-Host "  ${green}EXAMPLES:${nc}"
    Write-Host ""
    Write-Host "    ${gray}mole${nc}                  ${gray}# Interactive menu${nc}"
    Write-Host "    ${gray}mole clean${nc}            ${gray}# Deep cleanup${nc}"
    Write-Host "    ${gray}mole clean -DryRun${nc}    ${gray}# Preview cleanup${nc}"
    Write-Host "    ${gray}mole uninstall${nc}        ${gray}# Uninstall apps${nc}"
    Write-Host "    ${gray}mole analyze${nc}          ${gray}# Disk analyzer${nc}"
    Write-Host "    ${gray}mole status${nc}           ${gray}# System monitor${nc}"
    Write-Host "    ${gray}mole optimize${nc}         ${gray}# Optimize system${nc}"
    Write-Host "    ${gray}mole purge${nc}            ${gray}# Clean dev artifacts${nc}"
    Write-Host ""
    Write-Host "  ${green}ENVIRONMENT:${nc}"
    Write-Host ""
    Write-Host "    ${cyan}MOLE_DRY_RUN=1${nc}    Preview without changes"
    Write-Host "    ${cyan}MOLE_DEBUG=1${nc}      Enable debug output"
    Write-Host ""
    Write-Host "  ${gray}Run '${nc}mole <command> -ShowHelp${gray}' for command-specific help${nc}"
    Write-Host ""
}

# ============================================================================
# Interactive Menu
# ============================================================================

function Show-MainMenu {
    $options = @(
        @{ 
            Name = "Clean" 
            Description = "Deep system cleanup" 
            Command = "clean"
            Icon = $script:Icons.Trash
        }
        @{ 
            Name = "Uninstall" 
            Description = "Remove applications" 
            Command = "uninstall"
            Icon = $script:Icons.Folder
        }
        @{ 
            Name = "Analyze" 
            Description = "Disk space analyzer" 
            Command = "analyze"
            Icon = $script:Icons.File
        }
        @{ 
            Name = "Status" 
            Description = "System monitor" 
            Command = "status"
            Icon = $script:Icons.Solid
        }
        @{ 
            Name = "Optimize" 
            Description = "System optimization" 
            Command = "optimize"
            Icon = $script:Icons.Arrow
        }
        @{ 
            Name = "Purge" 
            Description = "Clean dev artifacts" 
            Command = "purge"
            Icon = $script:Icons.List
        }
    )
    
    $selected = Show-Menu -Title "What would you like to do?" -Options $options -AllowBack
    
    if ($null -eq $selected) {
        return $null
    }
    
    return $selected.Command
}

# ============================================================================
# Command Router
# ============================================================================

function Invoke-MoleCommand {
    param(
        [string]$CommandName,
        [string[]]$Arguments
    )
    
    $scriptPath = Join-Path $script:MOLE_BIN "$CommandName.ps1"
    
    if (-not (Test-Path $scriptPath)) {
        Write-Error "Unknown command: $CommandName"
        Write-Host ""
        Write-Host "Run 'mole -ShowHelp' for available commands"
        return
    }
    
    # Execute the command script with arguments using splatting
    # This properly handles switch parameters passed as strings
    if ($Arguments -and $Arguments.Count -gt 0) {
        # Build a hashtable for splatting
        $splatParams = @{}
        $positionalArgs = @()
        
        foreach ($arg in $Arguments) {
            # Remove surrounding quotes if present
            $cleanArg = $arg.Trim("'`"")
            
            if ($cleanArg -match '^-(\w+)$') {
                # It's a switch parameter (e.g., -DryRun)
                $paramName = $Matches[1]
                $splatParams[$paramName] = $true
            }
            elseif ($cleanArg -match '^-(\w+)[=:](.+)$') {
                # It's a named parameter with value (e.g., -Name=Value or -Name:Value)
                $paramName = $Matches[1]
                $paramValue = $Matches[2].Trim("'`"")
                $splatParams[$paramName] = $paramValue
            }
            else {
                # Positional argument
                $positionalArgs += $cleanArg
            }
        }
        
        # Execute with splatting
        if ($positionalArgs.Count -gt 0) {
            & $scriptPath @splatParams @positionalArgs
        }
        else {
            & $scriptPath @splatParams
        }
    }
    else {
        & $scriptPath
    }
}

# ============================================================================
# System Info Display
# ============================================================================

function Show-SystemInfo {
    $cyan = $script:Colors.Cyan
    $gray = $script:Colors.Gray
    $green = $script:Colors.Green
    $nc = $script:Colors.NC
    
    $winInfo = Get-WindowsVersion
    $freeSpace = Get-FreeSpace
    $isAdmin = if (Test-IsAdmin) { "${green}Yes${nc}" } else { "${gray}No${nc}" }
    
    Write-Host ""
    Write-Host "  ${gray}System:${nc} $($winInfo.Name)"
    Write-Host "  ${gray}Free Space:${nc} $freeSpace on $($env:SystemDrive)"
    Write-Host "  ${gray}Admin:${nc} $isAdmin"
    Write-Host ""
}

# ============================================================================
# Main
# ============================================================================

function Main {
    # Initialize
    Initialize-Mole
    
    # Handle switches passed as strings (when called via batch file with quoted args)
    # e.g., mole '-ShowHelp' becomes $Command = "-ShowHelp" instead of $ShowHelp = $true
    $effectiveShowHelp = $ShowHelp
    $effectiveVersion = $Version
    $effectiveCommand = $Command
    
    if ($Command -match '^-(.+)$') {
        $switchName = $Matches[1]
        switch ($switchName) {
            'ShowHelp' { $effectiveShowHelp = $true; $effectiveCommand = $null }
            'Help' { $effectiveShowHelp = $true; $effectiveCommand = $null }
            'h' { $effectiveShowHelp = $true; $effectiveCommand = $null }
            'Version' { $effectiveVersion = $true; $effectiveCommand = $null }
            'v' { $effectiveVersion = $true; $effectiveCommand = $null }
        }
    }
    
    # Handle version flag
    if ($effectiveVersion) {
        Show-Version
        return
    }
    
    # Handle help flag
    if ($effectiveShowHelp -and -not $effectiveCommand) {
        Show-MainHelp
        return
    }
    
    # If command specified, route to it
    if ($effectiveCommand) {
        $validCommands = @("clean", "uninstall", "analyze", "status", "optimize", "purge")
        
        if ($effectiveCommand -in $validCommands) {
            Invoke-MoleCommand -CommandName $effectiveCommand -Arguments $CommandArgs
        }
        else {
            Write-Error "Unknown command: $effectiveCommand"
            Write-Host ""
            Write-Host "Available commands: $($validCommands -join ', ')"
            Write-Host "Run 'mole -ShowHelp' for more information"
        }
        return
    }
    
    # Interactive mode
    Clear-Host
    Show-Banner
    Show-SystemInfo
    
    while ($true) {
        $selectedCommand = Show-MainMenu
        
        if ($null -eq $selectedCommand) {
            Clear-Host
            Write-Host ""
            Write-Host "  Goodbye!"
            Write-Host ""
            break
        }
        
        Clear-Host
        Invoke-MoleCommand -CommandName $selectedCommand -Arguments @()
        
        Write-Host ""
        Write-Host "  Press any key to continue..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        Clear-Host
        Show-Banner
        Show-SystemInfo
    }
}

# Run
try {
    Main
}
catch {
    Write-Host ""
    Write-Error "An error occurred: $_"
    Write-Host ""
    exit 1
}
finally {
    Clear-TempFiles
}
