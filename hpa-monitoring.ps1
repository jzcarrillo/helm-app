$command = "kubectl get hpa -n helm-app --watch"

Write-Host "Watching HPA scaling behavior in another new terminal..."
Start-Process powershell -ArgumentList @(
    "-NoProfile",
    "-NoExit",
    "-Command",
    $command
)

# STEP 10.1: HTTPS Requests (Expect: Success)
Write-Host "`nSending 500 HTTPS requests to https://localhost:31443"
1..100 | ForEach-Object {
    try {
        Invoke-WebRequest -Uri "https://localhost:31443" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop | Out-Null
        Write-Host "[$_] HTTPS success"
    } catch {
        Write-Host "[$_]  HTTPS failed - $($_.Exception.Message)"
    }
}

# STEP 10.2: HTTP Requests with port 31443 (Expect: Blocked)
Write-Host "`n Sending 500 HTTP requests to http://localhost:31443"
1..100 | ForEach-Object {
    try {
        Invoke-WebRequest -Uri "http://localhost:31443" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop | Out-Null
        Write-Host "[$_] HTTP unexpectedly succeeded"
    } catch {
        Write-Host "[$_] HTTP blocked as expected"
    }
}

# STEP 10.2: HTTP Requests with port 80 (Expect: Blocked)
Write-Host "`n Sending 500 HTTP requests to http://localhost:80"
1..100 | ForEach-Object {
    try {
        Invoke-WebRequest -Uri "http://localhost:80" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop | Out-Null
        Write-Host "[$_] HTTP unexpectedly succeeded"
    } catch {
        Write-Host "[$_] HTTP blocked as expected"
    }
}

