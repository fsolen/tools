<#
.SYNOPSIS
  DHCP Option 119 (Domain Search List) ayarını otomatik oluşturur ve uygular.

.DESCRIPTION
  Domain listelerini RFC 3397 formatında HEX'e dönüştürür,
  Hem Scope bazlı hem de global olarak DHCP sunucusuna uygular.

.EXAMPLE
  .\Set-DhcpDomainSearchList.ps1 -ScopeId 10.0.0.0 -Domains "fatihsolen.com,lab.fatihsolen.com"
  .\Set-DhcpDomainSearchList.ps1 -Domains "fatihsolen.com,lab.fatihsolen.com"

#>

param(
    [Parameter(Mandatory = $false)]
    [string]$ScopeId,

    [Parameter(Mandatory = $true)]
    [string]$Domains
)

# Renkli loglar
function Write-Info($msg)  { Write-Host "[INFO] "  -ForegroundColor Cyan -NoNewline;  Write-Host $msg }
function Write-Success($msg){ Write-Host "[OK] "    -ForegroundColor Green -NoNewline; Write-Host $msg }
function Write-Warning($msg){ Write-Host "[WARN] "  -ForegroundColor Yellow -NoNewline; Write-Host $msg }
function Write-ErrorMsg($msg){ Write-Host "[ERROR] " -ForegroundColor Red -NoNewline;  Write-Host $msg }

# Domainleri RFC 3397 formatında byte array'e dönüştür
function Convert-DomainSearchListToBytes($domains) {
    $bytes = New-Object System.Collections.Generic.List[byte]
    foreach ($domain in $domains -split ",") {
        $domain = $domain.Trim()
        if (-not $domain) { continue }
        foreach ($label in $domain.Split(".")) {
            $bytes.Add([byte]$label.Length)
            $label.ToCharArray() | ForEach-Object { $bytes.Add([byte][char]$_) }
        }
        $bytes.Add(0)
    }
    return $bytes
}

try {
    Write-Info "Domain listesi: $Domains"
    $val = Convert-DomainSearchListToBytes $Domains
    Write-Info ("HEX format: " + ($val | ForEach-Object { $_.ToString("X2") }) -join "")

    if ($ScopeId) {
        Write-Info "Scope bazlı uygulama başlatılıyor ($ScopeId)..."
        Set-DhcpServerv4OptionValue -ScopeId $ScopeId -OptionId 119 -Value $val -ErrorAction Stop
        Write-Success "Option 119 başarıyla $ScopeId scope'una eklendi."
    } else {
        Write-Info "Global (Server-level) uygulama başlatılıyor..."
        Set-DhcpServerv4OptionValue -OptionId 119 -Value $val -ErrorAction Stop
        Write-Success "Option 119 global olarak başarıyla eklendi."
    }
}
catch {
    Write-ErrorMsg $_.Exception.Message
}
 
