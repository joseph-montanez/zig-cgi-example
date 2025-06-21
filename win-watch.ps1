# Requires PowerShell 5.1 or later.
# This script continuously watches for changes in specified files,
# triggers a Zig build, and restarts a Docker Compose service.
# It is designed to run on Windows, leveraging PowerShell's FileSystemWatcher.

# --- Configuration Variables ---

# Define the Docker service name to restart (e.g., "apache")
$DockerServiceName = "apache"

# Define the root directory to watch. This is typically the directory
# where your docker-compose.yml and this script are located.
$ProjectRoot = Get-Location

# Define relevant file extensions to trigger a build
$ExtensionsToWatch = @(".zig", ".zon", ".html", ".css", ".js")

# Define specific filenames to watch in the project root (not recursively)
$SpecificFilesToWatch = @("build.zig", "build.zig.zon")

# Debouncing variables: This prevents multiple rapid triggers from a single save event.
# The script will wait for this interval after a change before executing commands.
$LastTriggerTime = Get-Date 0 # Initialize to a very old date
$DebounceIntervalSeconds = 1  # Ignore events for 1 second after an action is triggered

# --- Initial Script Output ---

Write-Host "--------------------------------------------------------" -ForegroundColor DarkGray
Write-Host "Starting PowerShell File Watcher for Docker/Zig Project" -ForegroundColor Cyan
Write-Host "Watching for file changes... (Press Ctrl+C to stop)" -ForegroundColor White
Write-Host "--------------------------------------------------------" -ForegroundColor DarkGray

# --- Function to execute the build and restart Docker service ---
function Invoke-BuildAndRestart {
    param(
        [string]$ChangedFilePath # Path of the file that triggered the event (for logging)
    )

    $currentTime = Get-Date

    # Debounce logic: only proceed if enough time has passed since the last trigger
    if (($currentTime - $LastTriggerTime).TotalSeconds -lt $DebounceIntervalSeconds) {
        Write-Host "  [Debounce] Ignoring rapid change for: $($ChangedFilePath | Split-Path -Leaf)" -ForegroundColor DarkYellow
        return
    }

    # Set last trigger time immediately to start the debounce period
    $LastTriggerTime = $currentTime

    Write-Host ""
    Write-Host ">>> [File Change Detected: $($ChangedFilePath | Split-Path -Leaf)] <<<" -ForegroundColor Cyan
    Write-Host "--------------------------------------------------------" -ForegroundColor DarkGray

    # Step 1: Stop the Apache Docker container
    Write-Host "  Stopping Docker service '$DockerServiceName'..." -ForegroundColor Yellow
    # Execute docker compose command. $LASTEXITCODE captures the exit code.
    docker compose stop $DockerServiceName
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Error: Failed to stop $DockerServiceName. Exit Code: $LASTEXITCODE" -ForegroundColor Red
        Write-Host "  [Command Sequence Failed]" -ForegroundColor Red
        return # Exit the function if command fails
    }
    Write-Host "  [$DockerServiceName Stopped]" -ForegroundColor Green

    # Step 2: Run the Zig build
    Write-Host "  Running Zig build..." -ForegroundColor Yellow
    # Execute zig build command.
    zig build -Doptimize=Debug -Dtarget=aarch64-linux-musl -Ddeployment=local
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Error: Zig build failed. Exit Code: $LASTEXITCODE" -ForegroundColor Red
        Write-Host "  [Command Sequence Failed]" -ForegroundColor Red
        return # Exit the function if command fails
    }
    Write-Host "  [Zig Build Finished]" -ForegroundColor Green

    # Step 3: Start the Apache Docker container
    Write-Host "  Starting Docker service '$DockerServiceName'..." -ForegroundColor Yellow
    # Execute docker compose command.
    docker compose start $DockerServiceName
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Error: Failed to start $DockerServiceName. Exit Code: $LASTEXITCODE" -ForegroundColor Red
        Write-Host "  [Command Sequence Failed]" -ForegroundColor Red
        return # Exit the function if command fails
    }
    Write-Host "  [$DockerServiceName Started]" -ForegroundColor Green

    Write-Host "--------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  [Commands Finished Successfully]" -ForegroundColor Green
    Write-Host ""
    Write-Host "Watching for new changes..." -ForegroundColor White
}

# --- Setup FileSystemWatchers ---

# Create a watcher for the project root directory (for build.zig, build.zig.zon)
$rootWatcher = New-Object System.IO.FileSystemWatcher
$rootWatcher.Path = $ProjectRoot
$rootWatcher.IncludeSubdirectories = $false # Only watch the root level

# Create a watcher for the 'src' directory (and its subdirectories)
$srcPath = Join-Path $ProjectRoot "src"
# Ensure the 'src' directory exists before attempting to watch it
if (-not (Test-Path $srcPath -PathType Container)) {
    Write-Warning "The 'src' directory was not found at '$srcPath'. Please ensure it exists."
    # If src doesn't exist, this watcher won't be added, but the script can still run.
    # You might want to exit here if 'src' is mandatory for your workflow.
}
$srcWatcher = New-Object System.IO.FileSystemWatcher
$srcWatcher.Path = $srcPath
$srcWatcher.IncludeSubdirectories = $true # Watch subdirectories within src

# Common NotifyFilter for both watchers
# LastWrite: Monitors changes to the last write time of files or directories.
# FileName: Monitors changes to the names of files or directories.
# DirectoryName: Monitors changes to the names of directories.
# CreationTime: Monitors changes to the creation time of files or directories.
$notifyFilter = [System.IO.NotifyFilters]::LastWrite `
              -bor [System.IO.NotifyFilters]::FileName `
              -bor [System.IO.NotifyFilters]::DirectoryName `
              -bor [System.IO.NotifyFilters]::CreationTime

$rootWatcher.NotifyFilter = $notifyFilter
$srcWatcher.NotifyFilter = $notifyFilter

# Array to hold all active watchers
$AllWatchers = @($rootWatcher)
if (Test-Path $srcPath -PathType Container) {
    $AllWatchers += $srcWatcher
}


# Register event handlers for each watcher
foreach ($watcher in $AllWatchers) {
    # Define a common action script block for all relevant events
    # This block will be executed whenever a watched event occurs.
    $action = {
        # Access event details using $Event.SourceEventArgs
        $eventPath = $Event.SourceEventArgs.FullPath       # Full path to the file/directory that changed
        $changeType = $Event.SourceEventArgs.ChangeType    # Type of change (e.g., Changed, Created, Deleted, Renamed)
        $fileExtension = [System.IO.Path]::GetExtension($eventPath) # Extension of the file
        $fileName = [System.IO.Path]::GetFileName($eventPath)     # Name of the file

        # For 'Renamed' events, we need to check both the old and new paths/names.
        if ($changeType -eq "Renamed") {
            $oldPath = $Event.SourceEventArgs.OldFullPath
            $oldFileExtension = [System.IO.Path]::GetExtension($oldPath)
            $oldFileName = [System.IO.Path]::GetFileName($oldPath)

            # Trigger if the new name/extension is relevant, OR if the old name/extension was relevant.
            # This ensures that renaming a relevant file (even to an irrelevant name) triggers a build,
            # and renaming an irrelevant file to a relevant name also triggers a build.
            if (($ExtensionsToWatch -contains $fileExtension -or $SpecificFilesToWatch -contains $fileName) -or `
                ($ExtensionsToWatch -contains $oldFileExtension -or $SpecificFilesToWatch -contains $oldFileName)) {
                Invoke-BuildAndRestart $eventPath # Pass the new path to the function
            }
        }
        # For other event types (Changed, Created, Deleted), simply check the current file.
        elseif ($ExtensionsToWatch -contains $fileExtension -or $SpecificFilesToWatch -contains $fileName) {
            Invoke-BuildAndRestart $eventPath
        }
    }

    # Register the same action script block for different event types.
    # -SourceIdentifier is used to give a unique name to the event subscription.
    # Out-Null suppresses the output from Register-ObjectEvent, keeping the console clean.
    Register-ObjectEvent -InputObject $watcher -EventName Changed -Action $action -SourceIdentifier "FileWatcher_Changed_$(Get-Random)" | Out-Null
    Register-ObjectEvent -InputObject $watcher -EventName Created -Action $action -SourceIdentifier "FileWatcher_Created_$(Get-Random)" | Out-Null
    Register-ObjectEvent -InputObject $watcher -EventName Deleted -Action $action -SourceIdentifier "FileWatcher_Deleted_$(Get-Random)" | Out-Null
    Register-ObjectEvent -InputObject $watcher -EventName Renamed -Action $action -SourceIdentifier "FileWatcher_Renamed_$(Get-Random)" | Out-Null

    $watcher.EnableRaisingEvents = $true # Start monitoring for events on this watcher
}

Write-Host "Watchers are active on '$ProjectRoot' and 'src' subdirectories (if present)." -ForegroundColor Green
Write-Host "(Press Ctrl+C to terminate the script)" -ForegroundColor DarkGray

# --- Keep the script running indefinitely ---
# This loop prevents the script from exiting immediately after setup.
# It sleeps to prevent high CPU usage.
while ($true) {
    Start-Sleep -Seconds 1
}

# --- Cleanup (This part is typically not reached in an infinite loop due to Ctrl+C) ---
# If the script were to terminate gracefully (e.g., not by Ctrl+C),
# these commands would unregister the event handlers and dispose of the watchers.
# To stop cleanly, you would typically use a more complex shutdown mechanism or just Ctrl+C.
# Get-EventSubscriber | Where-Object { $_.SourceIdentifier -like "FileWatcher_*" } | Unregister-Event
# foreach ($watcher in $AllWatchers) {
#     $watcher.Dispose() # Release resources held by the watcher
# }
