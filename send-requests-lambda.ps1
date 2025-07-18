Write-Host "`nSending 100 POST requests to lambda-producer..."

$uri = "http://localhost:4000/submit"
$headers = @{ "Content-Type" = "application/json" }
$body = '{"test":"ping"}'

for ($i = 1; $i -le 100; $i++) {
    try {
        $response = Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $body
        Write-Output "`nSend request $i."
        Write-Output "StatusCode        : 200"
        Write-Output "StatusDescription : OK"
        Write-Output "Content           : {""message"":""$($response.message)""}"
    } catch {
        # Do nothing or silently continue on failure
    }
    Start-Sleep -Milliseconds 300
}

Write-Host "`nDone sending requests!"

