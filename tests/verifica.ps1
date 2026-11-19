<#
  Teste de regressao do coleta.ps1 contra valores conferidos manualmente no Siconfi
  e na planilha CAPAG (exercicio 2025 fechado). Rode depois de mudar o script:

    powershell -NoProfile -ExecutionPolicy Bypass -File tests/verifica.ps1

  Se um municipio retificar demonstrativos, o valor esperado pode mudar: confira no
  Siconfi antes de atualizar a tabela abaixo.
#>
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot '..\scripts\coleta.ps1'

# Valores de referencia: RREO 6o bim./RGF 3o quad. de 2025
$casos = @(
  @{ ibge = '2910800'; nome = 'Feira de Santana'; pessoal = 52.03; dcl = 2.43; saude = 34.95; educacao = 25.78; rcl = 2119609305.93; capag = 'C' }
)

$falhas = 0
foreach ($c in $casos) {
  $tmp = [IO.Path]::GetTempFileName()
  & powershell -NoProfile -ExecutionPolicy Bypass -File $script -Ibge $c.ibge -Exercicio 2025 -Anos 0 -Saida $tmp | Out-Null
  $j = [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8) | ConvertFrom-Json
  Remove-Item $tmp
  $i = $j.indicadores
  $checks = @(
    @('pessoal_executivo_pct', $i.pessoal_executivo_pct.valor, $c.pessoal),
    @('dcl_pct_rcl', $i.dcl_pct_rcl.valor, $c.dcl),
    @('saude_asps_pct', $i.saude_asps_pct.valor, $c.saude),
    @('educacao_mde_pct', $i.educacao_mde_pct.valor, $c.educacao),
    @('rcl', $i.rcl.valor, $c.rcl),
    @('capag', $j.capag.CAPAG, $c.capag)
  )
  foreach ($k in $checks) {
    $ok = if ($k[2] -is [string]) { $k[1] -eq $k[2] } else { $null -ne $k[1] -and [math]::Abs([double]$k[1] - $k[2]) -lt 0.01 }
    if (-not $ok) { $falhas++ }
    '{0,-4} {1,-18} {2,-24} obtido={3} esperado={4}' -f $(if ($ok) { 'OK' } else { 'FALHA' }), $c.nome, $k[0], $k[1], $k[2]
  }
}
if ($falhas) { Write-Host "$falhas verificacao(oes) falharam"; exit 1 } else { Write-Host 'Todas as verificacoes passaram' }
