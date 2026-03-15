# --- Infrastructure Automation: Dynamic DNS & SSH Gateway ---
# Fully parameterized via Environment Variables

# 1. Load Secrets and User-Specific Info from Environment
$Token       = $env:CF_API_TOKEN
$ZoneID      = $env:CF_ZONE_ID
$RecordName  = $env:DEV_DOMAIN      # e.g., graviton.siliconlanguage.com
$SSHKeyPath  = $env:DEV_SSH_KEY     # e.g., ~/.ssh/spdk-dev-key.pem
$RemoteUser  = $env:DEV_USER        # e.g., ec2-user

# Validation
if (-not $Token -or -not $ZoneID -or -not $RecordName) {
    Write-Error "Missing Environment Variables! Please check your .env setup."
    exit
}

Write-Host "Checking current Public IP..." -ForegroundColor Cyan
$IP = (Invoke-RestMethod -Uri "https://checkip.amazonaws.com").Trim()

# 2. Fetch the Record ID from Cloudflare
$Headers = @{"Authorization" = "Bearer $Token"; "Content-Type" = "application/json"}
$RecordsURL = "https://api.cloudflare.com/client/v4/zones/$ZoneID/dns_records?name=$RecordName"

try {
    $Records = Invoke-RestMethod -Uri $RecordsURL -Headers $Headers
    if ($Records.result.Count -eq 0) {
        Write-Error "Could not find DNS record for $RecordName"
        exit
    }
    $RecordID = $Records.result[0].id

    # 3. Update the DNS Record
    $UpdateURL = "https://api.cloudflare.com/client/v4/zones/$ZoneID/dns_records/$RecordID"
    $Body = @{
        type    = "A"; name = $RecordName; content = $IP; ttl = 60; proxied = $false
    } | ConvertTo-Json

    $Result = Invoke-RestMethod -Method Put -Uri $UpdateURL -Headers $Headers -Body $Body

    if ($Result.success) {
        Write-Host "Successfully updated $RecordName to $IP" -ForegroundColor Green
    }
} catch {
    Write-Error "Cloudflare API Error: $_"
    exit
}

# 4. Launch SSH Session
Write-Host "Opening SSH Tunnel to $RemoteUser@$RecordName..." -ForegroundColor Yellow
ssh -i "$SSHKeyPath" "${RemoteUser}@${RecordName}"