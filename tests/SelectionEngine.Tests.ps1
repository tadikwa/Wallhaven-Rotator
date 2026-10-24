param([switch]$LoadFixtureOnly,[string]$RuntimeSource='')
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $env:TEMP ('wallhaven-engine-' + [guid]::NewGuid().ToString('N'))
$env:WALLHAVEN_SHARED_BASE_DIR = $testRoot
$env:WALLHAVEN_SHARED_MUTEX_NAME = 'Local\WallhavenEngine-' + [guid]::NewGuid().ToString('N')
$env:WALLHAVEN_LEGACY_ROTATOR_HISTORY_PATH = Join-Path $testRoot 'unused-rotator.json'
$env:WALLHAVEN_LEGACY_SCREENSAVER_HISTORY_PATH = Join-Path $testRoot 'unused-screensaver.json'
[void][IO.Directory]::CreateDirectory($testRoot)
$failures = @()
try {
    . (Join-Path $Root 'src/Wallhaven-SharedPolicy.ps1')
    $tokens = $null; $errors = $null
    if (-not $RuntimeSource) { $RuntimeSource=Join-Path $Root 'src/Wallhaven-Wallpaper-Tray.ps1' }
    $ast = [Management.Automation.Language.Parser]::ParseFile($RuntimeSource, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw $errors[0] }
    # Real selection, persistence and shared history; only HTTP and desktop/UI are replaced.
    foreach ($fn in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if ($fn.Name -in @('Load-MetadataCache','Save-MetadataCache','Remember-WallhavenMetadata',
            'Get-CachedContentDecision','Get-EligibleCandidates','Begin-CandidateEvaluation',
            'Retry-ApiSelection','Start-RecycleSelection','Start-WallpaperChange','Start-ApiRequest',
            'Begin-CandidateDownload','Process-AsyncState','Handle-RequestFailure','Finish-NoEligibleCandidate',
            'Complete-Wallpaper','Get-ApiUrl','Get-SelectionPage','Get-SelectionPageLimit','ConvertTo-QueryString',
            'Get-WallhavenResponseJson','Get-WallhavenRatioForSize','Test-ImageBytes',
            'Get-ResolutionQueryParameters','Test-ResolutionFallbackAllowed','Get-DeepErrorMessage',
            'Get-LocalSelectionKey','Start-CachedSelection','Start-WallhavenApiTask',
            'Initialize-SelectionCycle','Write-SelectionSummary','Load-SearchCache','Save-SearchCache',
            'Start-DiscoveredSelection','Get-QualifiedCandidateRank','Stop-SelectionRequests',
            'Get-SelectionHistorySnapshot','Publish-WallpaperState')) {
            Invoke-Expression $fn.Extent.Text
        }
    }
    Add-Type -AssemblyName System.Net.Http
    Add-Type -ReferencedAssemblies System.Net.Http @'
using System;
using System.Collections.Generic;
using System.Threading.Tasks;
public class SelectionHttpFixture : IDisposable {
    public void Dispose() {}
    public List<string> Requests = new List<string>();
    public Queue<string> Replies = new Queue<string>();
    public Dictionary<string,string> UrlReplies = new Dictionary<string,string>();
    public byte[] DownloadBytes;
    public long NowTicks;
    public List<long> Times = new List<long>();
    public Task<System.Net.Http.HttpResponseMessage> GetAsync(string url, System.Threading.CancellationToken token) {
        return GetAsync(url);
    }
    public Task<System.Net.Http.HttpResponseMessage> GetAsync(string url) {
        Requests.Add(url);
        if (url.StartsWith("https://w.wallhaven.cc/")) {
            var image = new TaskCompletionSource<System.Net.Http.HttpResponseMessage>();
            if (DownloadBytes == null) image.SetException(new Exception("download failed"));
            else image.SetResult(new System.Net.Http.HttpResponseMessage(System.Net.HttpStatusCode.OK) { Content = new System.Net.Http.ByteArrayContent(DownloadBytes) });
            return image.Task;
        }
        Times.Add(NowTicks);
        var t = new TaskCompletionSource<System.Net.Http.HttpResponseMessage>();
        string reply = UrlReplies.ContainsKey(url) ? UrlReplies[url] : (Replies.Count > 0 ? Replies.Dequeue() : "ERROR:offline");
        if (reply.StartsWith("ERROR:429")) {
            var response = new System.Net.Http.HttpResponseMessage((System.Net.HttpStatusCode)429);
            string value = reply.Substring("ERROR:429".Length).Trim();
            if (value.Length > 0) response.Headers.TryAddWithoutValidation("Retry-After", value);
            response.Content = new System.Net.Http.StringContent("");
            t.SetResult(response);
        }
        else if (reply.StartsWith("ERROR:")) t.SetException(new Exception(reply.Substring(6)));
        else t.SetResult(new System.Net.Http.HttpResponseMessage(System.Net.HttpStatusCode.OK) { Content = new System.Net.Http.StringContent(reply) });
        return t.Task;
    }
    public Task<byte[]> GetByteArrayAsync(string url) {
        Requests.Add(url);
        var t = new TaskCompletionSource<byte[]>();
        if (DownloadBytes == null) t.SetException(new Exception("download failed"));
        else t.SetResult(DownloadBytes);
        return t.Task;
    }
}
'@
    function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
    function Write-Log { param($Level, $Message) $script:Logs+=([string]$Message) }
    function Set-Status { param($Message) }
    function Write-CandidateDiagnostic { param($Kind,$Id,$Detail) $script:Diagnostics += "$Kind|$Id|$Detail" }
    function Refresh-DiagnosticsUi {}
    function Refresh-SharedHistoryView {}
    function Trim-WallpaperCache { param($KeepPath) }
    function Schedule-NextChange { $script:NextChange = [DateTime]::Now.AddHours(1) }
    function Set-WindowsWallpaper { param($Path) $script:Applied += $Path }
    function Advance-FixtureClock([double]$Seconds=3) {
        Set-SharedHistoryTestNow ((Get-SharedHistoryNow).AddSeconds($Seconds).ToString('o'))
        $script:HttpClient.NowTicks=(Get-SharedHistoryNow).UtcTicks
    }
    function Get-TargetDisplayFilter { [pscustomobject]@{Width=5120;Height=1440;Ratio='32x9';MatchMode=$(if($script:ExactTarget){'Exacte'}else{'Au moins'});IsExact=$script:ExactTarget} }
    function Candidate([string]$Id) {
        [pscustomobject]@{id=$Id;path="https://w.wallhaven.cc/full/aa/wallhaven-$Id.jpg";
            url="https://wallhaven.cc/w/$Id";category='general';resolution='5120x1440';
            dimension_x=5120;dimension_y=1440;file_type='image/jpeg';purity='sfw';selectionKey=(Get-LocalSelectionKey)}
    }
    function Reset-Fixture {
        if (Get-Command Stop-SelectionRequests -ErrorAction SilentlyContinue) { Stop-SelectionRequests }
        Reset-SharedWallpaperHistory
        Set-SharedHistoryTestNow '2026-10-23T12:00:00Z'
        $script:Settings = [pscustomobject]@{contentFilter='Strict';query='';category='General';sort='Random'}
        $script:ExactTarget=$true
        $script:HttpClient = New-Object SelectionHttpFixture
        $script:HttpClient.NowTicks=(Get-SharedHistoryNow).UtcTicks
        $script:State='Idle'; $script:Running=$true; $script:PendingManual=$false
        $script:NextChange=$null; $script:ApiRetryAfter=$null; $script:ApiAttempt=0
        $script:MetadataChecks=0; $script:AllowRecentHistoryRecycle=$false
        $script:ReservedCandidateId=$null; $script:Candidate=$null; $script:CandidateQueue=@()
        $script:ApiTask=$null; $script:MetadataTask=$null; $script:DownloadTask=$null
        $script:PageCeilings=@{}; $script:PagesTried=@()
        $script:Diagnostics=@(); $script:Logs=@(); $script:Applied=@(); $script:OfflineSelection=$false
        $script:MetadataCache=@{}; $script:MetadataCacheDirty=$false
        $script:ApiUsedResolution=$true
        $script:LastWallpaperId=$null
        $script:DeferredApiRequest=$null
        $script:ApiCachedJson=$null
        $script:SearchCache=@{}; $script:SearchCacheDirty=$false
        $script:SelectionSearches=0; $script:SelectionSeenIds=@{}; $script:SelectionUrls=@{}
        $script:SelectionDeadline=(Get-SharedHistoryNow).AddSeconds(45)
        $script:SelectionSummaryWritten=$false; $script:SelectionStats=$null
        $script:SelectionHistorySnapshot=$null; $script:WorkerCancellation=$null
        Remove-Item -LiteralPath $script:WallhavenApiBudgetPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $MetadataCachePath,$SearchCachePath -Force -ErrorAction SilentlyContinue
    }
    function Test-Case([string]$Name, [scriptblock]$Body) {
        try { Reset-Fixture; & $Body; Write-Host "PASS $Name" }
        catch { $script:failures += "$Name : $($_.Exception.Message)"; Write-Host "FAIL $Name : $_" }
    }
    $CacheDir = Join-Path $testRoot 'images'
    [void][IO.Directory]::CreateDirectory($CacheDir)
    Add-Type -AssemblyName System.Drawing
    $bitmap=New-Object Drawing.Bitmap(5120,1440)
    $imageBuffer=New-Object IO.MemoryStream
    try { $bitmap.Save($imageBuffer,[Drawing.Imaging.ImageFormat]::Jpeg); $fixtureImage=$imageBuffer.ToArray() }
    finally { $bitmap.Dispose(); $imageBuffer.Dispose() }
    $MetadataCachePath = Join-Path $testRoot 'metadata-cache.json'
    $SearchCachePath = Join-Path $testRoot 'search-cache.json'
    $MetadataCacheMaxAgeDays=7; $MetadataCacheMaxEntries=1200
    $MetadataChecksPerSelection=6; $ApiSelectionAttemptsPerMode=4
    $SearchRequestsPerSelection=2
    $ApiBase='https://wallhaven.cc/api/v1/search'
    $menuCurrent=[pscustomobject]@{Enabled=$false}
    $CurrentWallpaperButton=[pscustomobject]@{IsEnabled=$false}
    if (-not $LoadFixtureOnly) {
    Set-Item Function:Process-AsyncStateCore (Get-Item Function:Process-AsyncState).ScriptBlock
    function Process-AsyncState { Advance-FixtureClock; Process-AsyncStateCore }

    Test-Case 'quota skips unknowns and still finds validated candidates' {
        Remember-WallhavenMetadata -Id 'cached' -Category general -Tags @('forest')
        $script:MetadataChecks=16; $script:AllowRecentHistoryRecycle=$true
        $script:CandidateQueue=@((Candidate 'unknown'), (Candidate 'cached'))
        Begin-CandidateEvaluation
        Assert ($script:Candidate.id -eq 'cached' -and $script:State -eq 'Download') 'Cached candidate after unknown was lost at exhausted quota.'
        Assert ($script:MetadataChecks -eq 16) 'Cache hit consumed quota.'
    }
    Test-Case 'cached rejections do not reserve or rewrite shared history' {
        Remember-WallhavenMetadata -Id 'unsafe' -Category general -Tags @('women')
        $script:AllowRecentHistoryRecycle=$true; $script:ApiAttempt=4
        $before=[IO.File]::ReadAllText($script:WallhavenSharedHistoryPath)
        [IO.File]::SetLastWriteTimeUtc($script:WallhavenSharedHistoryPath, [DateTime]::UtcNow.AddHours(-1))
        $writeTime=(Get-Item $script:WallhavenSharedHistoryPath).LastWriteTimeUtc
        $script:CandidateQueue=@((Candidate 'unsafe'))
        Begin-CandidateEvaluation
        $after=[IO.File]::ReadAllText($script:WallhavenSharedHistoryPath)
        Assert ($before -eq $after) 'Rejected cached content caused a reservation/history write.'
        Assert ((Get-Item $script:WallhavenSharedHistoryPath).LastWriteTimeUtc -eq $writeTime) 'Cached rejection rewrote history.'
        Assert ($script:State -eq 'Idle' -and (Get-SharedHistorySnapshot).PendingCount -eq 0) 'Rejection left pending state.'
    }
    Test-Case '429 blocks pending and new manual requests, then resumes' {
        $script:PendingManual=$true
        Handle-RequestFailure -Message '429 Too Many Requests'
        Start-WallpaperChange -Reason Manual
        Assert ($script:HttpClient.Requests.Count -eq 0) 'Manual request bypassed 429 cooldown.'
        Assert ($script:ApiRetryAfter -gt (Get-SharedHistoryNow).LocalDateTime.AddMinutes(14)) '429 did not set a persistent cooldown.'
        Advance-FixtureClock -Seconds 901
        Start-WallpaperChange -Reason Manual
        Assert ($script:HttpClient.Requests.Count -eq 1) 'Selection did not resume after cooldown.'
    }
    Test-Case 'network metadata failure releases reservation without Strict rejection' {
        $script:CandidateQueue=@((Candidate 'neterr'))
        Begin-CandidateEvaluation
        Process-AsyncState
        Assert ((Get-SharedHistorySnapshot).PendingCount -eq 0) 'Network failure leaked reservation.'
        Assert (@($script:Diagnostics | Where-Object { $_ -like 'strict*' }).Count -eq 0) 'Network error was classified as Strict rejection.'
        Assert ($script:State -eq 'Idle') 'Offline metadata must stop instead of spending the whole quota.'
    }
    Test-Case 'duplicate IDs across pages use one network metadata check' {
        $script:HttpClient.Replies.Enqueue('{"data":{"id":"repeat","category":"general","tags":[{"name":"women"}]}}')
        $script:CandidateQueue=@((Candidate 'repeat'), (Candidate 'repeat'))
        Begin-CandidateEvaluation; Process-AsyncState
        Assert (@($script:HttpClient.Requests | Where-Object { $_ -like '*/w/repeat' }).Count -eq 1) 'Duplicate metadata call.'
        Assert ((Get-SharedHistorySnapshot).PendingCount -eq 0) 'Duplicate/rejected candidate leaked reservation.'
    }
    Test-Case 'corrupt, unsupported, expired and incomplete cache fail closed' {
        foreach ($json in @('{bad', '{"schema":99,"entries":[]}', '{"schema":1,"entries":[{"id":"bad","category":"general","checkedAt":"2099-01-01T00:00:00Z"}]}')) {
            [IO.File]::WriteAllText($MetadataCachePath,$json)
            Load-MetadataCache
            Assert ($null -eq (Get-CachedContentDecision -Id bad -Mode Strict)) 'Incomplete/future metadata was trusted.'
        }
        Remember-WallhavenMetadata -Id expired -Category general -Tags @('forest')
        $script:MetadataCache.expired.checkedAt=[DateTime]::UtcNow.AddDays(-8).ToString('o')
        Assert ($null -eq (Get-CachedContentDecision -Id expired -Mode Strict)) 'Expired entry reused.'
    }
    Test-Case 'bounded cache persists once and reloads under a new filter' {
        $MetadataCacheMaxEntries=2
        Remember-WallhavenMetadata -Id a -Category general -Tags @('forest')
        Remember-WallhavenMetadata -Id b -Category general -Tags @('women')
        Remember-WallhavenMetadata -Id c -Category general -Tags @('mountains')
        Save-MetadataCache
        $before=(Get-Item $MetadataCachePath).LastWriteTimeUtc
        Save-MetadataCache
        Assert ((Get-Item $MetadataCachePath).LastWriteTimeUtc -eq $before) 'Clean cache was rewritten.'
        Load-MetadataCache
        Assert ($script:MetadataCache.Count -eq 2) 'Cache was not bounded.'
        Assert (-not (Get-CachedContentDecision -Id b -Mode Strict).Allowed) 'Strict rejection lost on restart.'
        Assert ((Get-CachedContentDecision -Id b -Mode Reduced).Allowed) 'Filter change reused verdict.'
    }
    Test-Case 'empty, partial and saturated history allow repeated rotations without daily repeats' {
        foreach ($size in @(0,3,5000)) {
            Reset-Fixture
            $state=New-EmptySharedHistoryState
            $state.migrations.rotatorV1=$true; $state.migrations.screensaverV1=$true
            $state.entries=@(for($i=1;$i -le $size;$i++) {
                [pscustomobject]@{wallhavenId="old$i";shownAt='2026-10-22T10:00:00Z'}
            })
            Write-SharedHistoryStateUnlocked $state
            foreach ($id in @('old1','old2','old3')) {
                Remember-WallhavenMetadata -Id $id -Category general -Tags @('forest')
            }
            foreach ($rotation in 1..3) {
                $data=@((Candidate old1),(Candidate old2),(Candidate old3))
                $script:AllowRecentHistoryRecycle=$true
                $eligible=@(Get-EligibleCandidates $data)
                Assert ($eligible.Count -eq (4-$rotation)) 'Daily exclusions or history recycling incorrect.'
                $id=[string]$eligible[0].id
                [IO.File]::WriteAllBytes((Join-Path $CacheDir "wallhaven-$id.jpg"), $fixtureImage)
                $script:CandidateQueue=$eligible
                Begin-CandidateEvaluation
                Assert ($script:State -eq 'Idle' -and $script:LastWallpaperId -eq $id) 'Rotation failed.'
                Load-MetadataCache
                Assert ((Get-SharedHistorySnapshot).SeenToday.Contains($id)) 'History lost on restart.'
            }
            Assert ($script:HttpClient.Requests.Count -eq 0) 'Known rotations performed unnecessary network calls.'
        }
    }
    Test-Case 'API retries and recycle terminate and retain exact 32:9' {
        for($i=0;$i -lt 12;$i++) { $script:HttpClient.Replies.Enqueue('{"data":[],"meta":{"last_page":1}}') }
        Start-WallpaperChange
        foreach($tick in 1..12) { Process-AsyncState }
        Assert ($script:State -eq 'Idle' -and $script:HttpClient.Requests.Count -eq 2) 'Only the filtered query and user-only query may be searched once each.'
        Assert (@($script:HttpClient.Requests | Select-Object -Unique).Count -eq 2) 'A cached empty query was sent again.'
        foreach($url in $script:HttpClient.Requests) {
            Assert ($url -match 'ratios=32x9' -and $url -match 'resolutions=5120x1440') 'Exact resolution/ratio changed.'
        }
    }
    Test-Case 'download failure releases pending state and permits a later retry' {
        Remember-WallhavenMetadata -Id dlerr -Category general -Tags @('forest')
        $script:CandidateQueue=@((Candidate dlerr))
        Begin-CandidateEvaluation; Process-AsyncState
        Assert ((Get-SharedHistorySnapshot).PendingCount -eq 0) 'Download failure leaked reservation.'
        Assert (-not (Get-SharedHistorySnapshot).SeenToday.Contains('dlerr')) 'Failed download consumed daily ID.'
        Start-WallpaperChange
        Assert ($script:State -eq 'Download') 'A qualified discovery should retry its image without another API search.'
        Assert (@($script:HttpClient.Requests | Where-Object { $_ -like 'https://wallhaven.cc/api/*' }).Count -eq 0) 'Known download failure triggered an unnecessary API search.'
    }
    Test-Case 'malformed metadata never becomes a Strict acceptance' {
        $script:HttpClient.Replies.Enqueue('{"data":{"id":"invalid","category":"general"}}')
        $script:CandidateQueue=@((Candidate invalid))
        Begin-CandidateEvaluation; Process-AsyncState
        Assert ($script:State -eq 'Idle' -and $null -eq (Get-CachedContentDecision invalid Strict)) 'Malformed metadata accepted or cached.'
        Assert ((Get-SharedHistorySnapshot).PendingCount -eq 0) 'Malformed metadata left reservation.'
    }
    Test-Case 'offline restart reuses downloaded 32:9 images, same day and query exclusions remain' {
        foreach($id in @('local1','local2')) {
            Remember-WallhavenMetadata -Id $id -Category general -Tags @('forest')
            [IO.File]::WriteAllBytes((Join-Path $CacheDir "wallhaven-$id.jpg"), $fixtureImage)
            $script:CandidateQueue=@((Candidate $id))
            Begin-CandidateEvaluation
        }
        Load-MetadataCache
        Set-SharedHistoryTestNow '2026-10-24T12:00:00Z'
        $script:Applied=@()
        Start-WallpaperChange; Process-AsyncState
        Assert ($script:Applied.Count -eq 1) 'Offline restart did not reuse downloaded validated image.'
        Start-WallpaperChange; Process-AsyncState
        Assert ($script:Applied.Count -eq 2) 'Second offline rotation failed.'
        Start-WallpaperChange; Process-AsyncState
        Assert ($script:Applied.Count -eq 2) 'Offline rotation repeated image on same day.'
        Set-SharedHistoryTestNow '2026-10-25T12:00:00Z'
        $script:Settings.query='new query'
        Start-WallpaperChange; Process-AsyncState
        Assert ($script:Applied.Count -eq 2) 'Offline cache ignored changed search query.'
    }
    Test-Case '429 Retry-After delta and date are respected on search and metadata' {
        foreach($retry in @('1800', ([DateTimeOffset]::Parse('2026-10-23T12:35:00Z')).ToString('r'))) {
            foreach($stage in @('Api','Metadata')) {
                Reset-Fixture
                $script:HttpClient.Replies.Enqueue("ERROR:429 $retry")
                if($stage -eq 'Api') { Start-WallpaperChange }
                else { $script:CandidateQueue=@((Candidate ratelimit)); Begin-CandidateEvaluation }
                Process-AsyncState
                Assert ($script:ApiRetryAfter -gt (Get-SharedHistoryNow).LocalDateTime.AddMinutes(29)) 'Server Retry-After was ignored.'
                Assert ((Get-SharedHistorySnapshot).PendingCount -eq 0) '429 leaked a reservation.'
            }
        }
    }
    Test-Case 'cooldown does not interrupt an active selection' {
        $script:CandidateQueue=@((Candidate busy))
        Begin-CandidateEvaluation
        $script:ApiRetryAfter=[DateTime]::Now.AddMinutes(15)
        Start-WallpaperChange -Reason Manual
        Assert ($script:State -eq 'Metadata' -and $script:Candidate.id -eq 'busy' -and $script:PendingManual) 'Cooldown disturbed in-flight selection.'
    }
    Test-Case 'failed cache replacement preserves the last complete file and can retry' {
        Remember-WallhavenMetadata -Id saved -Category general -Tags @('forest')
        Save-MetadataCache
        $before=[IO.File]::ReadAllText($MetadataCachePath)
        $stream=[IO.File]::Open($MetadataCachePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try {
            Remember-WallhavenMetadata -Id later -Category general -Tags @('forest')
            Save-MetadataCache
            Assert ($script:MetadataCacheDirty) 'Failed save lost dirty state.'
            Assert ([IO.File]::ReadAllText($MetadataCachePath) -eq $before) 'Failed save corrupted cache.'
        }
        finally { $stream.Dispose() }
        Save-MetadataCache; Load-MetadataCache
        Assert ($null -ne (Get-CachedContentDecision later Strict)) 'Cache could not recover after failed save.'
        Assert (@(Get-ChildItem $testRoot | Where-Object { $_.Name -like 'metadata-cache.json.*' }).Count -eq 0) 'Temporary cache files leaked.'
    }
    Test-Case 'malformed tags are never treated as an empty safe array' {
        foreach($tags in @('{}','42','[{}]','["forest"]')) {
            Reset-Fixture
            $json='{"schema":1,"entries":[{"id":"bad","category":"general","checkedAt":"@now","tags":@tags}]}'
            [IO.File]::WriteAllText($MetadataCachePath,$json.Replace('@now',[DateTime]::UtcNow.ToString('o')).Replace('@tags',$tags))
            Load-MetadataCache
            # The cached representation must contain strings, so ["forest"] is valid only here.
            if($tags -ne '["forest"]') { Assert ($null -eq (Get-CachedContentDecision bad Strict)) 'Malformed cache tags trusted.' }
            $script:HttpClient.Replies.Enqueue(('{"data":{"id":"invalid","category":"general","tags":' + $tags + '}}'))
            $script:CandidateQueue=@((Candidate invalid))
            Begin-CandidateEvaluation; Process-AsyncState
            Assert ($script:State -eq 'Idle' -and $null -eq (Get-CachedContentDecision invalid Strict)) 'Malformed API tags accepted.'
        }
    }
    Test-Case 'changed settings during async request cannot relabel an old candidate' {
        $item=Candidate stale
        $script:HttpClient.Replies.Enqueue((ConvertTo-Json -Depth 5 -InputObject @{data=@($item);meta=@{last_page=1}}))
        $script:HttpClient.Replies.Enqueue('{"data":{"id":"stale","category":"general","tags":[{"name":"forest"}]}}')
        Start-WallpaperChange
        $script:Settings.query='changed while requesting'
        Process-AsyncState; Process-AsyncState
        Assert ($null -eq $script:ReservedCandidateId -and $script:State -eq 'Idle') 'Old query selection continued after settings changed.'
        Assert ($script:HttpClient.Requests.Count -eq 1) 'Old query triggered metadata/download under new settings.'
    }
    Test-Case 'corrupted offline image is skipped without consuming daily history' {
        Remember-WallhavenMetadata -Id corrupt -Category general -Tags @('forest')
        $path=Join-Path $CacheDir 'wallhaven-corrupt.jpg'
        [IO.File]::WriteAllBytes($path,$fixtureImage)
        $script:CandidateQueue=@((Candidate corrupt)); Begin-CandidateEvaluation
        Set-SharedHistoryTestNow '2026-10-24T12:00:00Z'
        [IO.File]::WriteAllBytes($path,[byte[]]@(1,2,3))
        $script:Applied=@()
        Start-WallpaperChange; Process-AsyncState
        Assert ($script:Applied.Count -eq 0 -and -not (Get-SharedHistorySnapshot).SeenToday.Contains('corrupt')) 'Corrupted offline image was applied/committed.'
        Assert ((Get-SharedHistorySnapshot).PendingCount -eq 0) 'Corrupted image leaked reservation.'
    }
    Test-Case 'Strict enabled during download cancels a previously allowed Reduced image' {
        $script:Settings.contentFilter='Reduced'
        $script:HttpClient.DownloadBytes=$fixtureImage
        $script:HttpClient.Replies.Enqueue('{"data":{"id":"switchdl","category":"general","tags":[{"name":"women"}]}}')
        $script:CandidateQueue=@((Candidate switchdl))
        Begin-CandidateEvaluation; Process-AsyncState
        Assert ($script:State -eq 'Download') 'Reduced fixture did not reach download.'
        $script:Settings.contentFilter='Strict'
        Process-AsyncState
        Assert ($script:Applied.Count -eq 0 -and (Get-SharedHistorySnapshot).PendingCount -eq 0) 'Enabling Strict during download did not cancel application.'
        Assert (-not (Get-SharedHistorySnapshot).SeenToday.Contains('switchdl')) 'Cancelled wallpaper consumed daily ID.'
    }
    Test-Case 'full new-image budget transitions once to cached recycling' {
        $old=New-EmptySharedHistoryState
        $old.entries=@([pscustomobject]@{wallhavenId='recycled';shownAt='2026-10-22T10:00:00Z'})
        $old.migrations.rotatorV1=$true; $old.migrations.screensaverV1=$true
        Write-SharedHistoryStateUnlocked $old
        Remember-WallhavenMetadata -Id recycled -Category general -Tags @('forest')
        [IO.File]::WriteAllBytes((Join-Path $CacheDir 'wallhaven-recycled.jpg'),$fixtureImage)
        $new=@(foreach($i in 1..17) { Candidate "new$i" })
        $script:HttpClient.Replies.Enqueue((ConvertTo-Json -Depth 5 -InputObject @{data=$new;meta=@{last_page=1}}))
        foreach($item in $new) {
            $script:HttpClient.UrlReplies["https://wallhaven.cc/api/v1/w/$($item.id)"] =
                ConvertTo-Json -Depth 5 -InputObject @{data=@{id=$item.id;category='general';tags=@(@{name='women'})}}
        }
        $script:HttpClient.Replies.Enqueue((ConvertTo-Json -Depth 5 -InputObject @{data=@((Candidate recycled));meta=@{last_page=1}}))
        Start-WallpaperChange
        foreach($tick in 1..20) { Process-AsyncState }
        Assert ($script:MetadataChecks -le $MetadataChecksPerSelection) 'Recycling reset the total per-change metadata budget.'
        Assert ($script:HttpClient.Requests.Count -le 12) 'Selection exceeded the global Rotator budget.'
    }
    Test-Case 'minimum-size fallback remains 32:9 and bounded' {
        $script:ExactTarget=$false
        foreach($i in 1..16) { $script:HttpClient.Replies.Enqueue('{"data":[],"meta":{"last_page":1}}') }
        Start-WallpaperChange
        foreach($i in 1..16) { Process-AsyncState }
        Assert ($script:State -eq 'Idle' -and $script:HttpClient.Requests.Count -eq 2) 'Fallback must use at most two distinct searches, reusing cached pages.'
        foreach($url in $script:HttpClient.Requests) { Assert ($url -match 'ratios=32x9' -and $url -notmatch '16x9') 'Fallback changed ratio.' }
        Assert ($script:HttpClient.Requests[0] -match 'atleast=5120x1440') 'Initial minimum resolution lost.'
    }
    if ($failures.Count) { throw ($failures -join "`n") }
    Write-Host 'Selection engine regression tests: OK'
    }
}
finally {
    if (-not $LoadFixtureOnly) {
    Set-SharedHistoryTestNow $null
    foreach($name in @('WALLHAVEN_SHARED_BASE_DIR','WALLHAVEN_SHARED_MUTEX_NAME','WALLHAVEN_LEGACY_ROTATOR_HISTORY_PATH','WALLHAVEN_LEGACY_SCREENSAVER_HISTORY_PATH')) {
        Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
    # Only this invocation's isolated fixture directory is removed.
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
