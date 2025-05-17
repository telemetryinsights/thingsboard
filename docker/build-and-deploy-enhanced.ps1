Set-Location -Path (Split-Path -Parent $MyInvocation.MyCommand.Definition)
param (
    [switch]$buildOnly,
    [switch]$deployOnly,
    [string]$password
)

$dockerImage = "thingsboard-dev"
$containerName = "thingsboard-build"
$hostDir = "C:\GitHub\ti\thingsboard"
$containerDir = "/home/thingsboard"

$backendJar = (Get-ChildItem "$hostDir\application\target\thingsboard-*-boot.jar" | Select-Object -First 1).FullName
$frontendDir = "$hostDir\ui-ngx\target\generated-resources\public"
$remoteHost = "192.168.86.122"
$remoteUser = "piadmin"
$remoteDir = "/usr/share/thingsboard/bin"
$tempPath = "/tmp/thingsboard.jar"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$sshUserHost = "${remoteUser}@${remoteHost}"

$plink = "C:\Program Files\PuTTY\plink.exe"
$pscp  = "C:\Program Files\PuTTY\pscp.exe"

Write-Host ""
Write-Host "==== 📦 Build and Deploy Script ===================================="
Write-Host "🧱 Build Only   : $($buildOnly.IsPresent)"
Write-Host "📤 Deploy Only  : $($deployOnly.IsPresent)"
Write-Host "🔐 Password Set : $([bool]$password)"
Write-Host "===================================================================="
Write-Host ""

if (-not $deployOnly) {
    Write-Host "🔧 Starting Docker build..."

    docker run --rm -it `
        --name $containerName `
        -v "${hostDir}:${containerDir}" `
        -w $containerDir `
        -e BUILD_TYPE="both" `
        $dockerImage `
        bash -c "./build.sh"

    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n❌ Build failed. Deployment aborted.`n"
        exit 1
    }
}

if (-not $buildOnly) {
    Write-Host "`n📤 Deploying build output to Raspberry Pi...`n"

    & $plink -pw $password $sshUserHost "if [ -f '${remoteDir}/thingsboard.jar' ]; then sudo cp '${remoteDir}/thingsboard.jar' '${remoteDir}/thingsboard_$timestamp.jar'; fi"
    & $plink -pw $password $sshUserHost "if [ -d '${remoteDir}/ui' ]; then sudo mv '${remoteDir}/ui' '${remoteDir}/ui_backup_$timestamp'; fi"

    Write-Host "📤 Uploading backend JAR..."
	& $pscp -pw $password $backendJar "${sshUserHost}:${tempPath}"
	& $plink -pw $password $sshUserHost "sudo mv $tempPath ${remoteDir}/thingsboard.jar"

    Write-Host "🔄 Restarting ThingsBoard..."
    & $plink -pw $password $sshUserHost "sudo systemctl restart thingsboard"
    Start-Sleep -Seconds 5

    Write-Host "🔍 Verifying service..."
    $status = & $plink -pw $password $sshUserHost "systemctl is-active thingsboard"

    $logEntry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Deploy result: "
    $emailMsg = ""
    $emailSubject = ""

    if ($status -eq "active") {
        Write-Host "`n✅ ThingsBoard is running.`n"
        $logEntry += "✅ Success"
        $emailSubject = "✅ ThingsBoard Deployment Success"
        $emailMsg = "Deployment succeeded at $timestamp. Service is active."
    } else {
        Write-Host "`n❌ Service failed to start. Rolling back...`n"
        $logEntry += "❌ Failed. Rolled back."

        & $plink -pw $password $sshUserHost "if [ -f '${remoteDir}/thingsboard_$timestamp.jar' ]; then mv '${remoteDir}/thingsboard_$timestamp.jar' '${remoteDir}/thingsboard.jar'; fi"
        & $plink -pw $password $sshUserHost "if [ -d '${remoteDir}/ui_backup_$timestamp' ]; then rm -rf '${remoteDir}/ui' && mv '${remoteDir}/ui_backup_$timestamp' '${remoteDir}/ui'; fi"
        & $plink -pw $password $sshUserHost "sudo systemctl restart thingsboard"

        $emailSubject = "❌ ThingsBoard Deployment Failed + Rolled Back"
        $emailMsg = "Deployment failed at $timestamp. Rollback executed. Service was restarted."
    }

    & $plink -pw $password $sshUserHost "echo '$logEntry' >> '${remoteDir}/deploy.log'"
    & $plink -pw $password $sshUserHost "echo '$emailMsg' | mail -s '$emailSubject' sysadmin@telemetryinsights.com"

    Write-Host "==== ✅ Deployment Script Finished ================================"
}

Write-Host ""

# ----------------------------------------------------------------------------------
# 🐳 Docker Build Section — Run ONLY if not DeployOnly
# ----------------------------------------------------------------------------------
if (-not $deployOnly) {
    Write-Host "`n==== 🐳 Starting Docker Build Process ===================================="

    # Ensure the Docker image is built (if not already)
    if (-not (docker images -q $dockerImage)) {
        Write-Host "🛠️  Building Docker image '$dockerImage'..."
        docker build -f "$hostDir\Dockerfile-dev" -t $dockerImage "$hostDir"
    }

    # Stop and remove old container if it exists
    if (docker ps -a --format '{{.Names}}' | Select-String -Pattern "^$containerName$") {
        Write-Host "🧹 Removing old container '$containerName'..."
        docker rm -f $containerName | Out-Null
    }

    # Start a new container in detached mode with volume for source output
    Write-Host "🚀 Starting new container '$containerName'..."
    docker run -dit --name $containerName -v "$hostDir:$containerDir" $dockerImage bash

    # Clean old files in container working dir (except /dist, .git, node_modules, etc.)
    Write-Host "🧼 Cleaning old source inside container..."
    docker exec $containerName bash -c "cd $containerDir && find . -mindepth 1 -maxdepth 1 \
        ! -name 'dist' ! -name '.git' ! -name 'node_modules' -exec rm -rf {} +"

    # Copy fresh code from host to container
    Write-Host "📁 Copying fresh source to container..."
    docker cp "$hostDir/." "$containerName:$containerDir"

    # Run Angular and Maven build inside container
    Write-Host "🧱 Running frontend (Angular) build inside container..."
    docker exec $containerName bash -c "cd $containerDir/ui-ngx && npm install && npm run build"

    Write-Host "☕ Running backend (Maven) build inside container..."
    docker exec $containerName bash -c "cd $containerDir && mvn clean install -DskipTests"

    Write-Host "✅ Build complete — container '$containerName' retained for inspection."
}
