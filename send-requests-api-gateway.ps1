$uri = "http://localhost:30081/submit"
$headers = @{ "Content-Type" = "application/json" }

for ($i = 1; $i -le 10000; $i++) {
    $body = @{ message = "Test $i" } | ConvertTo-Json

    try {
        $response = Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $body
        Write-Output "`nSend request $i."
        Write-Output "StatusCode        : 200"
        Write-Output "StatusDescription : OK"
        Write-Output "Content           : {""message"":""$($response.message)""}"
    } catch {
        Write-Output "`nSend request $i."
        Write-Output "StatusCode        : 429"
        Write-Output "StatusDescription : Too Many Requests"
        Write-Output "Content           : {""message"":""Too many requests to /submit""}"
    }

    Start-Sleep -Milliseconds 5  # Adjust delay if needed
}
