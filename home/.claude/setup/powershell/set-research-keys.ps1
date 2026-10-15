# Set the keys for the free research services (version 10.5)
# Run it YOURSELF, not through the agent: right-click the file -> "Run with PowerShell",
# or in PowerShell:  & "$HOME\.claude\setup\powershell\set-research-keys.ps1"
# The keys are stored as Windows user environment variables, never in a file and never in the chat.
# Empty input = skip this service. Afterwards restart all terminals and Claude Code.

$services = [ordered]@{
    'YDC_API_KEY'       = 'You.com       -> you.com/platform  (API Keys)'
    'TAVILY_API_KEY'    = 'Tavily        -> app.tavily.com   (API Keys)'
    'FIRECRAWL_API_KEY' = 'Firecrawl     -> firecrawl.dev/app/api-keys'
    'EXA_API_KEY'       = 'Exa           -> dashboard.exa.ai/api-keys'
    'TINYFISH_API_KEY'  = 'TinyFish      -> agent.tinyfish.ai/api-keys'
    'SERPER_API_KEY'    = 'Serper/Google -> serper.dev (Dashboard, API Key)'
}
foreach ($name in $services.Keys) {
    Write-Host ''
    Write-Host $services[$name]
    $sec = Read-Host -AsSecureString "Key for $name (Enter = skip)"
    $plain = [System.Net.NetworkCredential]::new('', $sec).Password
    if ([string]::IsNullOrWhiteSpace($plain)) { Write-Host '  skipped'; continue }
    [Environment]::SetEnvironmentVariable($name, $plain.Trim(), 'User')
    Write-Host '  saved'
}
Write-Host ''
Write-Host 'Done. Please restart all PowerShell windows and Claude Code.'
