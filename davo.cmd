@echo off

setlocal EnableExtensions DisableDelayedExpansion



where powershell.exe >nul 2>&1

if errorlevel 1 (

  echo davo.sh: error: Windows PowerShell is required. 1^>^&2

  exit /b 1

)



set "DAVO_PS_ARGS="

:collect_args

if "%~1"=="" goto args_done

set "DAVO_PS_ARGS=%DAVO_PS_ARGS%,'%~1'"

shift

goto collect_args



:args_done

powershell.exe -NoLogo -NoProfile -Command "$argv=@(%DAVO_PS_ARGS%);$s=[System.IO.File]::ReadAllText('davo.cmd');$m='# --- POWERSHELL '+'PAYLOAD ---';$p=$s.IndexOf($m);if($p -lt 0){exit 1};$payload=$s.Substring($p+$m.Length);$source=$payload+[Environment]::NewLine+'Main $argv';$tokens=$null;$errors=$null;[System.Management.Automation.Language.Parser]::ParseInput($source,'davo.cmd.generated.ps1',[ref]$tokens,[ref]$errors)|Out-Null;if($errors.Count -gt 0){$errors|ForEach-Object{[Console]::Error.WriteLine('davo.sh: PowerShell syntax error: ' + $_.Message + ' at line ' + $_.Extent.StartLineNumber + ', column ' + $_.Extent.StartColumnNumber)};exit 2};& ([scriptblock]::Create($source))"

set "DAVO_EXIT=%ERRORLEVEL%"

exit /b %DAVO_EXIT%



# --- POWERSHELL PAYLOAD ---

$ErrorActionPreference = 'Stop'

Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Net.Http



$VERSION = '1.2.0'

$OPENPGP_VERSION = '6.3.1'

$OPENPGP_DEFAULT = "https://unpkg.com/openpgp@$OPENPGP_VERSION/dist/openpgp.min.js"

$OPENPGP_FALLBACK = "https://cdn.jsdelivr.net/npm/openpgp@$OPENPGP_VERSION/dist/openpgp.min.js"

$WORDLIST_URL = if ($env:DAVO_WORDLIST_URL) { $env:DAVO_WORDLIST_URL } else { 'https://www.eff.org/files/2016/07/18/eff_large_wordlist.txt' }

$S2K_COUNT = '65011712'

$ARCHIVE_THRESHOLD = 10MB

$BOBA_MAX = 1GB

$QURL_MAX = 500MB


$BOBA_MAX_EXPIRY = 30 * 86400

$QURL_MAX_EXPIRY = 7 * 86400


$CACHE = if ($env:XDG_CACHE_HOME) { Join-Path $env:XDG_CACHE_HOME 'davo.sh' } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache/davo.sh' }




function Die([string]$Message) { throw "davo.sh: error: $Message" }

function SizeOf([string]$Path) { return (Get-Item -LiteralPath $Path).Length }

function Ensure-Command([string]$Name) { if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { Die "missing required command: $Name" } }

function Sha256([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }



function Download-File([string]$Url, [string]$Destination, [int]$TimeoutSec = 30) {

    $client = New-Object System.Net.Http.HttpClient

    $response = $null; $stream = $null; $file = $null

    try {

        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)

        $client.DefaultRequestHeaders.UserAgent.ParseAdd("davo.sh/$VERSION")

        $response = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()

        if(-not $response.IsSuccessStatusCode){ if($response.StatusCode -eq [Net.HttpStatusCode]::NotFound){throw 'download failed: the file was not found or has expired (HTTP 404)'};throw "download failed: server returned HTTP $([int]$response.StatusCode)" }

        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()

        $file = [IO.File]::Create($Destination)

        $stream.CopyTo($file)

    } finally { if($file){$file.Dispose()};if($stream){$stream.Dispose()};if($response){$response.Dispose()};$client.Dispose() }

}



function New-Password {

    if (-not (Test-Path -LiteralPath $CACHE)) { New-Item -ItemType Directory -Path $CACHE -Force | Out-Null }

    $path = Join-Path $CACHE 'wordlist-7776.txt'

    $valid = $false

    if (Test-Path -LiteralPath $path) {

        try { $words = [IO.File]::ReadAllLines($path); $valid = ($words.Count -eq 7776 -and (@($words | Select-Object -Unique).Count -eq 7776)) } catch { $valid = $false }

    }

    if (-not $valid) {

        $tmp = "$path.tmp"

        try {

            Download-File $WORDLIST_URL $tmp 15

            $words = foreach ($line in [IO.File]::ReadAllLines($tmp)) {

                $parts = $line -split '\s+'

                if ($parts.Count -ge 2) { $parts[1] }

            }

            if ($words.Count -ne 7776 -or (@($words | Select-Object -Unique).Count -ne 7776)) { throw 'invalid word list' }

            [IO.File]::WriteAllLines($tmp, $words)

            Move-Item -LiteralPath $tmp -Destination $path -Force

        } catch {

            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

            $words = $null

        }

    }

    if ($words -and $words.Count -eq 7776) {

        $picked = for ($i = 0; $i -lt 3; $i++) {

        $bytes = New-Object byte[] 4

        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()

        try {

            do { $rng.GetBytes($bytes); $n = [BitConverter]::ToUInt32($bytes, 0) } while ($n -ge ([uint64]::MaxValue - ([uint64]::MaxValue % [uint64]$words.Count)))

        } finally { $rng.Dispose() }

        $words[[int]($n % [uint64]$words.Count)]

    }

        return ($picked -join '-')

    }

    [Console]::Error.WriteLine('Word list unavailable; using a random 32-character fallback.')

    $bytes = New-Object byte[] 16

    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()

    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }

    return ([BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()

}



function Get-Password($Options, [bool]$Required) {

    if ($Options.RandomPassword) {

        if ($Required) { Die '--random-password cannot be used for decryption' }

        $p = New-Password; [Console]::Error.WriteLine("Password: $p"); return $p

    }

    if ($null -ne $Options.Password) { $p = [string]$Options.Password }

    elseif ($Options.PasswordFile) {

        try { $p = ([IO.File]::ReadAllLines($Options.PasswordFile))[0] } catch { Die "cannot read password file: $($Options.PasswordFile)" }

    }

    elseif ($Options.PasswordEnv) { $p = $env:DAVO_PASSWORD; if ([string]::IsNullOrEmpty($p)) { Die 'DAVO_PASSWORD is empty' } }

    elseif ($Required) { Die 'a passphrase is required when decrypting; use --password-file or --password-env for non-interactive use' }

    else {

        $p = Read-Host 'Passphrase (leave blank to generate one)'

        if ([string]::IsNullOrEmpty($p)) { $p = New-Password; [Console]::Error.WriteLine("Generated passphrase: $p") }

    }

    [Console]::Error.WriteLine("Password: $p")

    return $p

}



function Invoke-Gpg($Options, [string]$InputPath, [string]$OutputPath, [bool]$Decrypt) {

    $pwfile = Join-Path $script:TMP 'password'

    [IO.File]::WriteAllText($pwfile, $Options._Password)

    $gpgArgs = @('--batch','--yes','--pinentry-mode','loopback','--no-symkey-cache','--passphrase-file',$pwfile,'--output',$OutputPath)

    if ($Decrypt) { $gpgArgs += @('--decrypt',$InputPath) }

    else { $gpgArgs += @('--symmetric','--cipher-algo','AES256','--s2k-mode','3','--s2k-digest-algo','SHA256','--s2k-count',$S2K_COUNT,'--compress-algo','none',$InputPath) }

    $gpgOut = Join-Path $script:TMP 'gpg.out'

    $gpgErr = Join-Path $script:TMP 'gpg.err'

    & gpg @gpgArgs > $gpgOut 2> $gpgErr

    if ($LASTEXITCODE -ne 0) {

        if ($Decrypt) { Die 'OpenPGP decryption failed (wrong password or corrupt payload)' }

        else { Die 'OpenPGP encryption failed' }

    }

}



function Zip-Input([string]$Source, [string]$Output) {

    Add-Type -AssemblyName System.IO.Compression

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $zip = [IO.Compression.ZipFile]::Open($Output, [IO.Compression.ZipArchiveMode]::Create)

    try {

        $item = Get-Item -LiteralPath $Source

        if ($item.PSIsContainer) {

            $root = $item.Parent.FullName

            foreach ($file in Get-ChildItem -LiteralPath $Source -Recurse -File -Force) {

                $entry = $file.FullName.Substring($root.Length).TrimStart([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar).Replace('\','/')

                [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,$file.FullName,$entry,[IO.Compression.CompressionLevel]::Optimal) | Out-Null

            }

        } else {

            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,$item.FullName,$item.Name,[IO.Compression.CompressionLevel]::Optimal) | Out-Null

        }

    } finally { $zip.Dispose() }

}



function Get-OpenPgpBundle {

    $candidates = @()

    if ($env:DAVO_OPENPGP_BUNDLE) { $candidates += $env:DAVO_OPENPGP_BUNDLE }

    $candidates += @((Join-Path (Get-Location) 'openpgp.min.js'), (Join-Path $CACHE "openpgp-$OPENPGP_VERSION.min.js"))

    $expected = if ($env:DAVO_OPENPGP_SHA256) { $env:DAVO_OPENPGP_SHA256.ToLowerInvariant() } else { '' }

    foreach ($p in $candidates) {

        if (Test-Path -LiteralPath $p) {

            $text = [IO.File]::ReadAllText($p)

            if ($text.Contains("OpenPGP.js v$OPENPGP_VERSION") -and (!$expected -or (Sha256 $p) -eq $expected)) { return $p }

        }

    }

    if (-not (Test-Path -LiteralPath $CACHE)) { New-Item -ItemType Directory -Path $CACHE -Force | Out-Null }

    $path = Join-Path $CACHE "openpgp-$OPENPGP_VERSION.min.js"; $tmp = "$path.tmp"

    $urls = if ($env:DAVO_OPENPGP_URL) { @($env:DAVO_OPENPGP_URL) } else { @($OPENPGP_DEFAULT,$OPENPGP_FALLBACK) }

    foreach ($url in $urls) {

        try {

            [Console]::Error.WriteLine("Downloading OpenPGP.js $OPENPGP_VERSION ...")

            Download-File $url $tmp 120

            $text = [IO.File]::ReadAllText($tmp)

            if (-not $text.Contains("OpenPGP.js v$OPENPGP_VERSION")) { throw 'unexpected OpenPGP.js bundle' }

            if ($expected -and (Sha256 $tmp) -ne $expected) { throw 'OpenPGP.js checksum mismatch' }

            Move-Item -LiteralPath $tmp -Destination $path -Force; return $path

        } catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }

    }

    Die "could not obtain OpenPGP.js $OPENPGP_VERSION; use DAVO_OPENPGP_BUNDLE=/path/to/openpgp.min.js for offline/local use"

}



function Render-Html([string]$Payload,[string]$Filename,[string]$Output,[long]$CreatedAt,[long]$ExpiresAt) {

    $js = [IO.File]::ReadAllText((Get-OpenPgpBundle)) -replace "\r?\n?//# sourceMappingURL=.*?(\r?\n|$)", "`n"

    $data = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Payload))

    $name = (ConvertTo-Json ([IO.Path]::GetFileName($Filename)) -Compress).Replace('<','\u003c').Replace('>','\u003e').Replace('&','\u0026').Replace([string][char]0x2028,'\u2028').Replace([string][char]0x2029,'\u2029')

    $digest = Sha256 (Get-OpenPgpBundle)

    $page = @'

<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="referrer" content="no-referrer"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none"><title>davo.sh encrypted file</title><style>:root{color-scheme:light dark;font-family:system-ui,sans-serif}body{margin:0;min-height:100vh;display:grid;place-items:center}main{width:min(32rem,calc(100vw - 2rem));padding:2rem;box-sizing:border-box}h1{font-size:1.35rem;margin:0 0 .5rem}p{opacity:.75}label{display:block;margin:1.5rem 0 .4rem}input,button{box-sizing:border-box;width:100%;padding:.75rem;font:inherit}button{margin-top:.8rem;cursor:pointer}#status{min-height:1.5em;margin-top:1rem}</style></head><body><main><h1>davo.sh encrypted file</h1><p>This file decrypts locally in your browser. Nothing is uploaded.</p><label for="password">Passphrase</label><input id="password" type="password" autocomplete="off" autofocus><button id="decrypt" type="button">Decrypt</button><p id="status" role="status" aria-live="polite"></p></main><script>/* OpenPGP.js 6.3.1 - LGPL-3.0+ - SHA-256: __SHA__ */__JS__</script><script>'use strict';const DAVO_PAYLOAD_B64='__PAYLOAD__';const DAVO_FILENAME=__NAME__;const DAVO_CREATED_AT=__CREATED__;const DAVO_EXPIRES_AT=__EXPIRES__;const button=document.getElementById('decrypt'),password=document.getElementById('password'),status=document.getElementById('status');function setStatus(t){status.textContent=t}function decodeBase64(s){const raw=atob(s),out=new Uint8Array(raw.length);for(let i=0;i<raw.length;i++)out[i]=raw.charCodeAt(i);return out}async function decryptFile(){const pass=password.value;if(!pass){setStatus('Enter the passphrase.');password.focus();return}button.disabled=true;password.disabled=true;setStatus('Decrypting locally...');try{if(!globalThis.openpgp)throw new Error('OpenPGP implementation is unavailable');const message=await openpgp.readMessage({binaryMessage:decodeBase64(DAVO_PAYLOAD_B64)});const result=await openpgp.decrypt({message,passwords:[pass],format:'binary'});const data=result.data instanceof Uint8Array?result.data:new Uint8Array(result.data),url=URL.createObjectURL(new Blob([data],{type:'application/octet-stream'})),a=document.createElement('a');a.href=url;a.download=DAVO_FILENAME;document.body.appendChild(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),60000);setStatus('Decrypted successfully. Your download should start shortly.')}catch(e){console.error(e);setStatus('Could not decrypt the file. Check the passphrase or the file integrity.');password.disabled=false;password.select()}finally{button.disabled=false}}button.addEventListener('click',decryptFile);password.addEventListener('keydown',e=>{if(e.key==='Enter')decryptFile()});</script></body></html>

'@

    $page = $page.Replace('__SHA__',$digest).Replace('__JS__',$js).Replace('__PAYLOAD__',$data).Replace('__NAME__',$name).Replace('__CREATED__',[string]$CreatedAt).Replace('__EXPIRES__',[string]$ExpiresAt)

    [IO.File]::WriteAllText($Output,$page,(New-Object Text.UTF8Encoding($false)))

}



function Convert-ExpiryToSeconds([string]$Expiry) {

    if ($Expiry -eq '0') { return 0 }

    $m=[regex]::Match($Expiry,'^(\d+)(m|h|d)$')

    if(-not $m.Success){throw "expiry must be a duration such as 30m, 1h, or 7d; got: $Expiry"}

    $n=[decimal]$m.Groups[1].Value

    $max = switch($m.Groups[2].Value){'m'{525600};'h'{8760};'d'{365}}

    if($n -gt $max){throw 'expiry exceeds the maximum supported lifetime of 365 days'}

    switch($m.Groups[2].Value){'m'{return [int64]($n*60)};'h'{return [int64]($n*3600)};'d'{return [int64]($n*86400)}}

}



function Get-ExpiryTimestamp([string]$Expiry) {

    $seconds=Convert-ExpiryToSeconds $Expiry

    if($seconds -eq 0){return 0}

    return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+$seconds

}



function Upload([string]$Payload,[string]$Name,[string]$ContentType,[string]$Backend,[string]$Expiry) {

    $seconds = Convert-ExpiryToSeconds $Expiry

    if ($Backend -eq 'auto') { $backends = @('bobashare','qurl') } elseif ($Backend -in @('bobashare','qurl')) { $backends = @($Backend) } else { Die "unknown backend: $Backend (choose auto, bobashare, or qurl)" }

    $filtered = foreach ($b in $backends) {

        $limit = if($b -eq 'bobashare'){$BOBA_MAX_EXPIRY}else{$QURL_MAX_EXPIRY}

        if ($seconds -eq 0 -and $b -eq 'qurl') {

            if ($Backend -ne 'auto') { Die 'qurl.sh does not support non-expiring uploads' }

            continue

        }

        if ($seconds -ne 0 -and $seconds -gt $limit) {

            if ($Backend -ne 'auto') { $days = [int]($limit / 86400); Die "$(if($b -eq 'bobashare'){'BobaShare'}else{'qurl.sh'}) supports uploads for at most $days days" }

            continue

        }

        $b

    }

    $backends = @($filtered)

    if ($backends.Count -eq 0) { Die "no upload backend supports the requested expiry: $Expiry" }

    foreach ($i in 0..($backends.Count-1)) {

        $b=$backends[$i]; $limit=if($b -eq 'bobashare'){$BOBA_MAX}else{$QURL_MAX}; $label=if($b -eq 'bobashare'){'BobaShare'}else{'qurl.sh'}

        if ((SizeOf $Payload) -gt $limit) { if($i -lt $backends.Count-1){[Console]::Error.WriteLine("$label cannot carry this encrypted upload; trying the next backend.")}else{[Console]::Error.WriteLine("$label cannot carry this encrypted upload.")}; continue }

        [Console]::Error.WriteLine("Uploading via $label ...")

        try {

            $base=if($b -eq 'bobashare'){if($env:DAVO_BOBASHARE_URL){$env:DAVO_BOBASHARE_URL}else{'https://share.boba.best'}}else{if($env:DAVO_QURL_URL){$env:DAVO_QURL_URL}else{'https://qurl.sh'}}

            $uri = if($b -eq 'bobashare'){ $base.TrimEnd('/')+'/api/v1/upload/'+[Uri]::EscapeDataString($Name) } else { $base.TrimEnd('/')+'/'+[Uri]::EscapeDataString($Name) }

            $client=[Net.Http.HttpClient]::new(); $client.Timeout=[TimeSpan]::FromMinutes(30); $stream=$null;$content=$null;$form=$null;$req=$null;$r=$null; try {

                $stream=[IO.File]::OpenRead($Payload); $content=[Net.Http.StreamContent]::new($stream); $content.Headers.ContentType=[Net.Http.Headers.MediaTypeHeaderValue]::Parse($ContentType)

                if($b -eq 'bobashare'){$req=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Put,$uri);$req.Headers.Add('Bobashare-Expiry',$Expiry);$req.Content=$content}elseif($b -eq 'qurl'){$req=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Put,$uri);$req.Headers.Add('X-TTL',$Expiry);$req.Headers.Add('X-Format','url');$req.Content=$content}

                $r=$client.SendAsync($req).GetAwaiter().GetResult(); $body=$r.Content.ReadAsStringAsync().GetAwaiter().GetResult(); if(-not $r.IsSuccessStatusCode){throw "$label returned HTTP $([int]$r.StatusCode): $body"}

                if($b -eq 'bobashare'){ $loc=$null; try{$json=$body|ConvertFrom-Json;$loc=[string]$json.direct_url}catch{}; if(-not $loc -and $r.Headers.Location){$location=$r.Headers.Location.AbsoluteUri;$u=[Uri]$location;$loc=$u.Scheme+'://'+$u.Authority+'/raw/'+$u.AbsolutePath.Trim('/')} if(-not $loc){throw 'no upload URL returned'}; return $(if($loc.Contains('?')){$loc}else{$loc + '?download'}) }

                if($b -eq 'qurl'){$text=$body.Trim();if($text.StartsWith('{')){try{$json=$text|ConvertFrom-Json;$text=[string]$json.url}catch{}};$m=[regex]::Match($text,'https?://[^\s"<>]+');if(-not $m.Success){throw 'no upload URL returned'};return $m.Value.TrimEnd('.',',',';',')')}

                $m=[regex]::Matches($body,'https?://\S+');if($m.Count -eq 0){throw 'no upload URL returned'};return $m[$m.Count-1].Value.TrimEnd('.',',',';',')')

            } finally { if($req){$req.Dispose()};if($form){$form.Dispose()};if($content){$content.Dispose()};if($stream){$stream.Dispose()};$client.Dispose()}

        } catch { $reason=$_.Exception.Message; if($i -lt $backends.Count-1){[Console]::Error.WriteLine("$label upload failed: $reason; trying the next backend.")}else{[Console]::Error.WriteLine("$label upload failed: $reason")} }

    }

    Die 'all selected upload backends failed'

}



function Parse-Args([string[]]$argv) {

    $backend = if ($env:DAVO_BACKEND) { $env:DAVO_BACKEND } else { 'auto' }

    $expiry = if ($env:DAVO_EXPIRY) { $env:DAVO_EXPIRY } else { '1h' }

    $o=[ordered]@{Command=$null;Input=$null;Password=$null;PasswordFile=$null;PasswordEnv=$false;RandomPassword=$false;Output=$null;Force=$false;NoHtml=$false;Backend=$backend;Expiry=$expiry;Help=$false;Version=$false}

    if($argv.Count -eq 0){$o.Help=$true;return [pscustomobject]$o}

    $i=0

    if($argv[0] -in @('-h','--help')){$o.Help=$true;return [pscustomobject]$o};if($argv[0] -eq '--version'){$o.Version=$true;return [pscustomobject]$o}

    if($argv[0] -notin @('send','get','encrypt','decrypt')){Die "unknown command: $($argv[0])"};$o.Command=$argv[0];$i=1

    if($i -ge $argv.Count){Die "missing input for $($o.Command)"};$o.Input=$argv[$i];$i++

    while($i -lt $argv.Count){$x=$argv[$i];switch($x){'-p' {if(++$i -ge $argv.Count){Die '-p requires a value'};$o.Password=$argv[$i]};'--password' {if(++$i -ge $argv.Count){Die '--password requires a value'};$o.Password=$argv[$i]};'-P' {if(++$i -ge $argv.Count){Die '-P requires a file'};$o.PasswordFile=$argv[$i]};'--password-file' {if(++$i -ge $argv.Count){Die '--password-file requires a file'};$o.PasswordFile=$argv[$i]};'--password-env' {$o.PasswordEnv=$true};'--random-password' {$o.RandomPassword=$true};'-o' {if(++$i -ge $argv.Count){Die '-o requires a file'};$o.Output=$argv[$i]};'--output' {if(++$i -ge $argv.Count){Die '--output requires a file'};$o.Output=$argv[$i]};'-f' {$o.Force=$true};'--force' {$o.Force=$true};'--no-html' {$o.NoHtml=$true};'--backend' {if(++$i -ge $argv.Count){Die '--backend requires a value'};$o.Backend=$argv[$i]};'-e' {if(++$i -ge $argv.Count){Die '-e requires a value'};$o.Expiry=$argv[$i]};'--expiry' {if(++$i -ge $argv.Count){Die '--expiry requires a value'};$o.Expiry=$argv[$i]};'-h' {$o.Help=$true};'--help' {$o.Help=$true};default {Die "unknown option: $x"}};$i++}

    return [pscustomobject]$o

}

function Check-Output([string]$Path,$Options){if((Test-Path -LiteralPath $Path) -and -not $Options.Force){Die "output exists: $Path (use --force to overwrite)"}}



function Show-Help {
    @'
davo.sh - simple encrypted file transport

Usage:
  davo.cmd send <file|directory> [options]
  davo.cmd get <url> [options]
  davo.cmd encrypt <file> [options]
  davo.cmd decrypt <file> [options]

Options:
  -p, --password STRING      Use STRING as the password.
  -P, --password-file FILE   Read the password from FILE.
      --password-env         Read the password from DAVO_PASSWORD.
      --random-password      Generate and print a random three-word password.
      --no-html              Upload the encrypted OpenPGP file directly.
      --backend NAME         Use bobashare or qurl (default: auto; tries both).
  -o, --output FILE          Output file.
  -f, --force                Overwrite an existing output file.
  -e, --expiry TIME          Upload expiry (default: 1h).
  -h, --help                Show this help.
      --version             Show the version.

Examples:
  davo.cmd send photo.jpg
  davo.cmd send project/ --expiry 6h
  davo.cmd send report.pdf -p 'correct horse battery staple'
  davo.cmd get 'https://...' -P password.txt
  davo.cmd send backup.zip --no-html --backend qurl
'@
}



function Main([string[]]$argv) {

    $a=Parse-Args $argv

    if($a.Version){Write-Output "davo.sh $VERSION";return}

    if($a.Help){Show-Help;return}

    if($a.Command -in @('send','encrypt','decrypt')){Ensure-Command 'gpg'}

    $script:TMP=Join-Path ([IO.Path]::GetTempPath()) ("davo.sh-"+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $script:TMP -Force|Out-Null

    try {

        $a | Add-Member NoteProperty _Password (Get-Password $a ($a.Command -in @('get','decrypt')))

        if($a.Command -eq 'send'){

            $src=Get-Item -LiteralPath $a.Input -ErrorAction Stop;$archive=Join-Path $script:TMP 'archive.zip';$name=$src.Name

            if($src.PSIsContainer -or (!$src.PSIsContainer -and (SizeOf $src.FullName) -gt $ARCHIVE_THRESHOLD)){Zip-Input $src.FullName $archive;$source=$archive;$name="$($src.Name).zip"}else{$source=$src.FullName}

            $payload=Join-Path $script:TMP 'payload.gpg';Write-Output "Encrypting $name ...";Invoke-Gpg $a $source $payload $false

            if($a.NoHtml){$url=Upload $payload "$name.gpg" 'application/octet-stream' $a.Backend $a.Expiry}else{Write-Output 'Packaging recipient HTML ...';$html=Join-Path $script:TMP 'davo.sh.html';$created=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();$expires=Get-ExpiryTimestamp $a.Expiry;Render-Html $payload $name $html $created $expires;$url=Upload $html (([IO.Path]::GetFileNameWithoutExtension($name))+'.html') 'text/html; charset=utf-8' $a.Backend $a.Expiry}

            Write-Output "`nPassword: $($a._Password)`nURL: $url";return

        }

        if($a.Command -eq 'encrypt'){

            $src=Get-Item -LiteralPath $a.Input -ErrorAction Stop;if($src.PSIsContainer){Die 'encrypt accepts a regular file; use send for directories'};if($a.NoHtml -or $a.Backend -ne 'auto'){Die '--no-html/--backend is only valid with send'};$out=if($a.Output){$a.Output}else{Join-Path $src.DirectoryName ($src.BaseName+'.gpg')};Check-Output $out $a;Invoke-Gpg $a $src.FullName $out $false;Write-Output "Created: $out";return

        }

        if($a.Command -eq 'decrypt'){

            $src=Get-Item -LiteralPath $a.Input -ErrorAction Stop;if($src.PSIsContainer){Die "not a regular file: $($a.Input)"};if($a.NoHtml -or $a.Backend -ne 'auto'){Die '--no-html/--backend is only valid with send'};$out=if($a.Output){$a.Output}else{Join-Path $src.DirectoryName ($src.BaseName+'.recovered')};Check-Output $out $a;Invoke-Gpg $a $src.FullName $out $true;Write-Output "Recovered: $out";return

        }

        $input=Join-Path $script:TMP 'input';Download-File $a.Input $input 1800;$payload=Join-Path $script:TMP 'payload.gpg';$text=$null;try{$text=[IO.File]::ReadAllText($input)}catch{}

        $m=[regex]::Match($text,"const DAVO_PAYLOAD_B64='([^']+)';");$fm=[regex]::Match($text,'const DAVO_FILENAME=(.*?);');$em=[regex]::Match($text,'const DAVO_EXPIRES_AT=(\d+);')

        if($m.Success -and $fm.Success){if($em.Success -and [int64]$em.Groups[1].Value -ne 0 -and [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -ge [int64]$em.Groups[1].Value){Die 'this davo.sh file has expired'};[IO.File]::WriteAllBytes($payload,[Convert]::FromBase64String($m.Groups[1].Value));$name=(ConvertFrom-Json $fm.Groups[1].Value);if([string]::IsNullOrEmpty($name) -or $name -match '[\\/]') { Die 'invalid filename in davo.sh HTML artifact' };$out=if($a.Output){$a.Output}else{$name}}else{Copy-Item $input $payload -Force;$out=if($a.Output){$a.Output}else{'davo.sh-recovered'}}

        if(-not $a.Output -and (Test-Path -LiteralPath $out)){ $out="davo.sh-recovered.$(Split-Path $out -Leaf)" };Check-Output $out $a;Write-Output 'Decrypting ...';Invoke-Gpg $a $payload $out $true;Write-Output "Recovered: $out"

    } finally {Remove-Item -LiteralPath $script:TMP -Recurse -Force -ErrorAction SilentlyContinue}

}





