# Link a COFF MoonBit static archive and the C host using MSVC.
param([string]$OutputDir = "stage")
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
Push-Location $root
try {
    $stem = Join-Path $root "_build/native/release/build/colmugx/cetas-go/native_bridge/native_bridge"
    if (Test-Path "$stem.a") {
        $archive = (Resolve-Path "$stem.a").Path
    } elseif (Test-Path "$stem.lib") {
        $archive = (Resolve-Path "$stem.lib").Path
    } else {
        throw "MoonBit archive missing: $stem.a (or $stem.lib)"
    }
    $dest = [IO.Path]::GetFullPath((Join-Path $root $OutputDir))
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $dll = Join-Path $dest "cetas_moon.dll"
    $obj = Join-Path $dest "cetas_host.obj"
    $implib = Join-Path $dest "cetas_moon_import.lib"
    $def = Join-Path $root "cetas-go/tools/cetas_moon.def"
    $hostSrc = Join-Path $root "cetas-go/go_bridge/host.c"
    # The MoonBit archive's allocator and host.c must agree. The default
    # (and all CI/release builds) is system; mimalloc is an explicit opt-in.
    $allocatorDefine = @()
    if ($env:MOONBIT_ALLOCATOR -eq 'mimalloc') {
        $allocatorDefine = @('/DCETAS_USE_MIMALLOC=1')
    }
    & cl.exe /nologo /c /O1 /Gy /Gw /GL /MD /W3 @allocatorDefine "/Fo$obj" "$hostSrc"
    if ($LASTEXITCODE -ne 0) { throw "MSVC host.c compilation failed ($LASTEXITCODE)" }
    & link.exe /nologo /DLL /INCREMENTAL:NO "/OUT:$dll" "/IMPLIB:$implib" `
        "/DEF:$def" /LTCG /OPT:REF /OPT:ICF "/WHOLEARCHIVE:$archive" "$obj" `
        ws2_32.lib bcrypt.lib dbghelp.lib pathcch.lib ntdll.lib `
        iphlpapi.lib secur32.lib crypt32.lib
    if ($LASTEXITCODE -ne 0) { throw "MSVC DLL link failed ($LASTEXITCODE)" }
    if (-not (Test-Path $dll)) { throw "MSVC linker produced no DLL: $dll" }
    $exports = & dumpbin.exe /nologo /exports "$dll"
    if ($LASTEXITCODE -ne 0) { throw "dumpbin failed to inspect $dll" }
    foreach ($name in @(
        "cetas_host_boot", "cetas_host_infra_run", "cetas_host_send",
        "cetas_host_poll_event", "cetas_host_submit_harness",
        "cetas_host_wait_event", "cetas_bridge_publish"
    )) {
        if (-not ($exports | Select-String -SimpleMatch $name)) {
            throw "Missing DLL export: $name"
        }
    }
    Write-Host "MSVC MoonBit DLL: $dll"
} finally {
    Pop-Location
}
