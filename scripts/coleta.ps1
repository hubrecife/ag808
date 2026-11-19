<#
.SYNOPSIS
  Coleta dados fiscais oficiais de um municipio (Siconfi, IBGE, CAPAG/Tesouro Transparente)
  e devolve um JSON com indicadores ja calculados e status sugerido.

.DESCRIPTION
  Usado pelo agente avaliador-portaria-808. O agente deve interpretar o JSON, nao recalcular.
  Compativel com Windows PowerShell 5.1 e PowerShell 7+ (pwsh) em Windows, Linux e macOS.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts/coleta.ps1 -Ibge 2910800
  pwsh scripts/coleta.ps1 -Ibge 2910800 -Anos 3 -Saida feira.json
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Ibge,
  [int]$Exercicio = 0,          # 0 = detecta o exercicio mais recente com RREO entregue
  [int]$Anos = 3,               # exercicios fechados na serie historica
  [switch]$SemCapag,
  [string]$Saida
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$VERSAO = '2.0.0'
$SICONFI = 'https://apidatalake.tesouro.gov.br/ords/siconfi/tt'
$IBGE_API = 'https://servicodados.ibge.gov.br/api/v1/localidades/municipios'
$CKAN = 'https://www.tesourotransparente.gov.br/ckan/api/3/action/package_show?id=capag-municipios'
$avisos = New-Object System.Collections.ArrayList
$script:ultimaSiconfi = [datetime]::MinValue

if ($Ibge -notmatch '^\d{7}$') { throw "Codigo IBGE deve ter 7 digitos: '$Ibge'" }

# ---------------------------------------------------------------- HTTP
function Get-Texto([string]$url) {
  $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 120
  return [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
}

function Get-Json([string]$url, [switch]$Siconfi) {
  for ($t = 1; $t -le 4; $t++) {
    if ($Siconfi) {
      $espera = 1100 - ((Get-Date) - $script:ultimaSiconfi).TotalMilliseconds
      if ($espera -gt 0) { Start-Sleep -Milliseconds ([int]$espera) }
      $script:ultimaSiconfi = Get-Date
    }
    try { return (Get-Texto $url | ConvertFrom-Json) }
    catch {
      if ($t -eq 4) { throw }
      Start-Sleep -Seconds (2 * $t)
    }
  }
}

# Siconfi (ORDS) pagina com hasMore/offset
function Get-Siconfi([string]$recurso, [hashtable]$p) {
  $qs = ($p.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$([uri]::EscapeDataString([string]$_.Value))" }) -join '&'
  $url = "$SICONFI/$recurso`?$qs"
  $itens = @(); $offset = 0
  do {
    $u = if ($offset -gt 0) { "$url&offset=$offset" } else { $url }
    $r = Get-Json $u -Siconfi
    $itens += @($r.items)
    $offset += @($r.items).Count
  } while ($r.hasMore -and @($r.items).Count -gt 0)
  return [pscustomobject]@{ url = $url; itens = $itens }
}

function Pegar($itens, [string]$codConta, [string]$colunaRegex) {
  $x = $itens | Where-Object { $_.cod_conta -eq $codConta -and $_.coluna -match $colunaRegex } | Select-Object -First 1
  if ($x) { return [double]$x.valor } else { return $null }
}

function R2($v) { if ($null -eq $v) { return $null } else { return [math]::Round([double]$v, 2) } }

function Indicador($valor, $limite, $unidade, $status, $fonte, $obs) {
  [ordered]@{ valor = (R2 $valor); limite = $limite; unidade = $unidade; status_sugerido = $status; fonte = $fonte; observacao = $obs }
}

function Fonte($dem, $anexo, $ex, $per, $poder, $url) {
  [ordered]@{ demonstrativo = $dem; anexo = $anexo; exercicio = $ex; periodo = $per; poder = $poder; url = $url }
}

# ---------------------------------------------------------------- Classificacao
function St-Pessoal($v, [double]$alerta, [double]$prud, [double]$max) {
  if ($null -eq $v) { return 'SEM DADO' }
  if ($v -gt $max) { return 'IMPEDITIVO' }
  if ($v -gt $prud) { return 'ATENCAO' }
  if ($v -gt $alerta) { return 'ATENCAO' }
  return 'REGULAR'
}
function St-Minimo($v, [double]$min, [bool]$final) {
  if ($null -eq $v) { return 'SEM DADO' }
  if ($v -ge $min) { return 'REGULAR' }
  if ($final) { return 'IMPEDITIVO' } else { return 'ATENCAO' }
}
function St-Teto($v, [double]$alerta, [double]$max) {
  if ($null -eq $v) { return 'SEM DADO' }
  if ($v -gt $max) { return 'IMPEDITIVO' }
  if ($v -gt $alerta) { return 'ATENCAO' }
  return 'REGULAR'
}

# ---------------------------------------------------------------- Entregas
function Get-Entregas([int]$ano) {
  $r = Get-Siconfi 'extrato_entregas' @{ id_ente = $Ibge; an_referencia = $ano }
  $lista = foreach ($e in $r.itens) {
    [ordered]@{
      orgao = $e.instituicao; entregavel = $e.entregavel; periodo = $e.periodo
      periodicidade = $e.periodicidade; status = $e.status_relatorio; data_status = $e.data_status
    }
  }
  return [pscustomobject]@{ url = $r.url; itens = @($lista) }
}

function Periodos($entregas) {
  $pref = @($entregas.itens | Where-Object { $_.orgao -match '^Prefeitura' })
  $rreo = @($pref | Where-Object { $_.entregavel -match 'Resumido' } | Sort-Object { [int]$_.periodo } -Descending)
  $rgf  = @($pref | Where-Object { $_.entregavel -match 'Gest.o Fiscal' } | Sort-Object { [int]$_.periodo } -Descending)
  [pscustomobject]@{
    rreo_bimestre = if ($rreo.Count) { [int]$rreo[0].periodo } else { $null }
    rgf_periodo = if ($rgf.Count) { [int]$rgf[0].periodo } else { $null }
    rgf_periodicidade = if ($rgf.Count) { [string]$rgf[0].periodicidade } else { $null }
  }
}

# ---------------------------------------------------------------- Indicadores de um periodo
function Get-Indicadores([int]$ano, $bim, $rgfPer, $rgfPdc, [switch]$Completo) {
  $ind = [ordered]@{}
  $finalRreo = ($bim -eq 6)

  if ($bim) {
    $r = Get-Siconfi 'rreo' @{ an_exercicio = $ano; nr_periodo = $bim; co_tipo_demonstrativo = 'RREO'; no_anexo = 'RREO-Anexo 14'; id_ente = $Ibge }
    $it = $r.itens
    $f = Fonte 'RREO' 'Anexo 14' $ano "$bim bimestre" 'Consolidado' $r.url
    $parc = if ($finalRreo) { 'Exercicio completo (6o bimestre).' } else { "Parcial ate o $bim o bimestre; minimo constitucional e apurado no fechamento do exercicio." }
    if (@($it).Count -eq 0) { [void]$avisos.Add("RREO Anexo 14 $ano/$bim sem linhas.") }

    $ind.rcl = Indicador (Pegar $it 'ReceitaCorrenteLiquidaDemonstrativoSimplificado' 'Bimestre') $null 'R$' 'INFO' $f 'Receita Corrente Liquida (12 meses).'
    $sa = Pegar $it 'AplicacaoTotalDasDespesasComAcoesEServicosPublicosDeSaude' '% Aplicado'
    $ind.saude_asps_pct = Indicador $sa 15 '% receita de impostos' (St-Minimo $sa 15 $finalRreo) $f $parc
    $ed = Pegar $it 'MinimoAnualDasReceitasDeImpostosNaManutencaoEDesenvolvimentoDoEnsinoDemonstrativoSimplificado' '% Aplicado'
    $ind.educacao_mde_pct = Indicador $ed 25 '% receita de impostos' (St-Minimo $ed 25 $finalRreo) $f $parc
    $fu = Pegar $it 'MinimoAnualDoFUNDEBNaRemuneracaoDoMagisterioComEducacaoInfantilEnsinoFundamentalEMedioDemonstrativoSimplificado' '% Aplicado'
    $ind.fundeb_70_pct = Indicador $fu 70 '% do FUNDEB' (St-Minimo $fu 70 $finalRreo) $f $parc

    if ($Completo) {
      $ind.resultado_primario_sem_rpps = Indicador (Pegar $it 'ResultadoPrimarioAcimaDaLinhaSemRPPSDemonstrativoSimplificado' 'Resultado') $null 'R$' 'INFO' $f 'Acima da linha, ate o bimestre.'
      $oc = Pegar $it 'ReceitaDeOperacoesDeCreditoDemonstrativoSimplificado' 'Valor Apurado'
      $dk = Pegar $it 'DespesaDeCapitalLiquidaDemonstrativoSimplificado' 'Valor Apurado'
      $obsRg = 'CF art. 167, III: operacoes de credito nao podem exceder despesas de capital.'
      if ($null -eq $oc -and $null -ne $dk) { $oc = 0; $obsRg += ' Linha de operacoes de credito ausente no anexo: tratada como zero.' }
      $rg = if ($null -eq $oc -or $null -eq $dk) { 'SEM DADO' } elseif ($oc -le $dk) { 'REGULAR' } else { 'IMPEDITIVO' }
      $ind.regra_de_ouro = [ordered]@{ operacoes_credito = (R2 $oc); despesa_capital_liquida = (R2 $dk); status_sugerido = $rg; fonte = $f; observacao = $obsRg }
      $ppp = Pegar $it 'TotalDasDespesasDeCaraterContinuadoEmRelacaoAReceitaCorrenteLiquidaDemonstrativoSimplificado' 'Valor Apurado'
      $ind.ppp_despesas_pct_rcl = Indicador $ppp 5 '% RCL' (St-Teto $ppp 4.5 5) $f 'Lei 11.079/2004 art. 28: acima de 5% da RCL a Uniao nao concede garantia nem transferencias voluntarias.'
      $rpNp = Pegar $it 'TotalRestosAPagarDemonstrativoSimplificado' 'Saldo'
      $ind.restos_a_pagar_saldo = Indicador $rpNp $null 'R$' 'INFO' $f 'Saldo total de restos a pagar (processados + nao processados).'
    }
  } else { [void]$avisos.Add("Sem RREO entregue pela Prefeitura em $ano.") }

  if ($rgfPer) {
    $nomePer = if ($rgfPdc -eq 'S') { "$rgfPer semestre" } else { "$rgfPer quadrimestre" }
    $colPer = "^At. o $rgfPer. (Quadrimestre|Semestre)"

    $r1 = Get-Siconfi 'rgf' @{ an_exercicio = $ano; in_periodicidade = $rgfPdc; nr_periodo = $rgfPer; co_tipo_demonstrativo = 'RGF'; no_anexo = 'RGF-Anexo 01'; co_poder = 'E'; id_ente = $Ibge }
    $f1 = Fonte 'RGF' 'Anexo 01' $ano $nomePer 'Executivo' $r1.url
    $pe = Pegar $r1.itens 'DespesaComPessoalTotal' '%'
    $ind.pessoal_executivo_pct = Indicador $pe ([ordered]@{ alerta = 48.6; prudencial = 51.3; maximo = 54 }) '% RCL ajustada' (St-Pessoal $pe 48.6 51.3 54) $f1 'LRF arts. 20, 22, 23 e 59. Acima do prudencial: vedacoes do art. 22. Acima do maximo: art. 23 (vedadas transferencias voluntarias, garantias e operacoes de credito se nao reconduzir).'
    if ($Completo) {
      $ind.pessoal_executivo_pct.valor_rs = R2 (Pegar $r1.itens 'DespesaComPessoalTotal' '^Valor$')
      $r1l = Get-Siconfi 'rgf' @{ an_exercicio = $ano; in_periodicidade = $rgfPdc; nr_periodo = $rgfPer; co_tipo_demonstrativo = 'RGF'; no_anexo = 'RGF-Anexo 01'; co_poder = 'L'; id_ente = $Ibge }
      $pl = Pegar $r1l.itens 'DespesaComPessoalTotal' '%'
      $ind.pessoal_legislativo_pct = Indicador $pl ([ordered]@{ alerta = 5.4; prudencial = 5.7; maximo = 6 }) '% RCL ajustada' (St-Pessoal $pl 5.4 5.7 6) (Fonte 'RGF' 'Anexo 01' $ano $nomePer 'Legislativo' $r1l.url) 'Camara Municipal.'
    }

    $r2 = Get-Siconfi 'rgf' @{ an_exercicio = $ano; in_periodicidade = $rgfPdc; nr_periodo = $rgfPer; co_tipo_demonstrativo = 'RGF'; no_anexo = 'RGF-Anexo 02'; co_poder = 'E'; id_ente = $Ibge }
    $f2 = Fonte 'RGF' 'Anexo 02' $ano $nomePer 'Executivo' $r2.url
    $dcl = Pegar $r2.itens 'PercentualDaDCLSobreARCL' $colPer
    $ind.dcl_pct_rcl = Indicador $dcl ([ordered]@{ alerta = 108; maximo = 120 }) '% RCL ajustada' (St-Teto $dcl 108 120) $f2 'Resolucao do Senado 40/2001.'
    if ($Completo) {
      $ind.dcl_pct_rcl.dcl_rs = R2 (Pegar $r2.itens 'DividaConsolidadaLiquida' $colPer)
      $ind.dc_pct_rcl = Indicador (Pegar $r2.itens 'PercentualDaDCSobreARCL' $colPer) $null '% RCL ajustada' 'INFO' $f2 'Divida consolidada bruta.'

      $r4 = Get-Siconfi 'rgf' @{ an_exercicio = $ano; in_periodicidade = $rgfPdc; nr_periodo = $rgfPer; co_tipo_demonstrativo = 'RGF'; no_anexo = 'RGF-Anexo 04'; co_poder = 'E'; id_ente = $Ibge }
      $oc = Pegar $r4.itens 'TotalConsideradoParaFinsDaApuracaoDoCumprimentoDoLimiteOperacoesDeCredito' '%'
      $obsOc = 'Resolucao do Senado 43/2001, art. 7o, I.'
      if ($null -eq $oc -and @($r4.itens).Count -gt 0) { $oc = 0; $obsOc += ' Anexo entregue sem linha de total: nenhuma operacao informada, tratado como zero.' }
      $ind.operacoes_credito_pct_rcl = Indicador $oc ([ordered]@{ alerta = 14.4; maximo = 16 }) '% RCL ajustada' (St-Teto $oc 14.4 16) (Fonte 'RGF' 'Anexo 04' $ano $nomePer 'Executivo' $r4.url) $obsOc

      $r3 = Get-Siconfi 'rgf' @{ an_exercicio = $ano; in_periodicidade = $rgfPdc; nr_periodo = $rgfPer; co_tipo_demonstrativo = 'RGF'; no_anexo = 'RGF-Anexo 03'; co_poder = 'E'; id_ente = $Ibge }
      $gar = $r3.itens | Where-Object { $_.coluna -match $colPer -and $_.cod_conta -match 'Percentual' } | Select-Object -First 1
      $gv = if ($gar) { [double]$gar.valor } elseif (@($r3.itens).Count -gt 0) { 0 } else { $null }
      $obsG = 'Garantias concedidas pelo municipio (limite de 22% da RCL).'
      if (-not $gar -and $null -ne $gv) { $obsG += ' Anexo entregue sem linha percentual: nenhuma garantia informada, tratado como zero.' }
      $ind.garantias_concedidas_pct_rcl = Indicador $gv 22 '% RCL ajustada' (St-Teto $gv 19.8 22) (Fonte 'RGF' 'Anexo 03' $ano $nomePer 'Executivo' $r3.url) $obsG
    }
  } else { [void]$avisos.Add("Sem RGF entregue pela Prefeitura em $ano.") }

  return $ind
}

# ---------------------------------------------------------------- CAPAG
function Get-Capag {
  $pkg = Get-Json $CKAN
  $rec = @($pkg.result.resources | Where-Object { $_.format -match 'XLSX' -and $_.name -match 'Capag Munic' } |
          Sort-Object { [datetime]$(if ($_.last_modified) { $_.last_modified } else { $_.created }) } -Descending)[0]
  if (-not $rec) { throw 'Nenhuma planilha CAPAG encontrada no Tesouro Transparente.' }

  $cache = Join-Path ([IO.Path]::GetTempPath()) 'ag808'
  New-Item -ItemType Directory -Force $cache | Out-Null
  $arq = Join-Path $cache ("capag-" + $rec.id + ".xlsx")
  if (-not (Test-Path $arq)) { Invoke-WebRequest -Uri $rec.url -OutFile $arq -UseBasicParsing -TimeoutSec 600 }

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [IO.Compression.ZipFile]::OpenRead($arq)
  try {
    $ler = { param($n) $s = New-Object IO.StreamReader($zip.GetEntry($n).Open(), [Text.Encoding]::UTF8); $t = $s.ReadToEnd(); $s.Close(); $t }
    [xml]$wb = & $ler 'xl/workbook.xml'
    [xml]$rels = & $ler 'xl/_rels/workbook.xml.rels'
    $sheet = @($wb.workbook.sheets.sheet)[0]   # primeira aba = posicao vigente ("Previa da CAPAG")
    $rid = $sheet.GetAttribute('id', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships')
    $alvo = ($rels.Relationships.Relationship | Where-Object { $_.Id -eq $rid }).Target -replace '^/?xl/', ''
    [xml]$ss = & $ler 'xl/sharedStrings.xml'
    $strs = @($ss.sst.si | ForEach-Object { $_.InnerText })

    $rd = [Xml.XmlReader]::Create($zip.GetEntry("xl/$alvo").Open())
    $cab = $null; $linha = @{}; $col = $null; $tipo = $null; $achou = $null
    while ($rd.Read()) {
      if ($rd.NodeType -eq 'Element' -and $rd.LocalName -eq 'row') { $linha = @{} }
      elseif ($rd.NodeType -eq 'Element' -and $rd.LocalName -eq 'c') { $col = ($rd.GetAttribute('r') -replace '\d', ''); $tipo = $rd.GetAttribute('t') }
      elseif ($rd.NodeType -eq 'Element' -and $rd.LocalName -eq 'v') {
        $v = $rd.ReadElementContentAsString(); if ($tipo -eq 's') { $v = $strs[[int]$v] }; $linha[$col] = $v
      }
      elseif ($rd.NodeType -eq 'EndElement' -and $rd.LocalName -eq 'row') {
        if (-not $cab -and $linha['A'] -match 'digo Munic') { $cab = $linha.Clone() }
        elseif ($cab -and $linha['A'] -eq $Ibge) { $achou = $linha.Clone(); break }
      }
    }
    $rd.Close()
  } finally { $zip.Dispose() }

  $res = [ordered]@{ posicao = $rec.name.Trim(); aba = $sheet.name; url = $rec.url; encontrado = [bool]$achou }
  if ($achou) {
    $vistos = @{}
    foreach ($k in ($cab.Keys | Sort-Object { $_.Length }, { $_ })) {
      $nome = $cab[$k]; if ($vistos.ContainsKey($nome)) { continue }; $vistos[$nome] = 1
      if ($achou.ContainsKey($k)) { $res[$nome] = $achou[$k] }
    }
  }
  return $res
}

# ================================================================= Execucao
$saidaObj = [ordered]@{
  meta = [ordered]@{ script = 'ag808/scripts/coleta.ps1'; versao = $VERSAO; gerado_em = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz') }
  municipio = [ordered]@{ ibge = $Ibge }
}

# IBGE
try {
  $m = Get-Json "$IBGE_API/$Ibge"
  if ($m -and $m.nome) {
    $uf = $m.microrregiao.mesorregiao.UF
    if (-not $uf) { $uf = $m.'regiao-imediata'.'regiao-intermediaria'.UF }
    $saidaObj.municipio.nome = $m.nome; $saidaObj.municipio.uf = $uf.sigla; $saidaObj.municipio.ibge_validado = $true
  } else { $saidaObj.municipio.ibge_validado = $false; [void]$avisos.Add('IBGE nao retornou municipio para este codigo.') }
} catch { $saidaObj.municipio.ibge_validado = $false; [void]$avisos.Add("IBGE indisponivel: $($_.Exception.Message)") }

# Exercicio de referencia
$anoAtual = (Get-Date).Year
$entregas = [ordered]@{}
if ($Exercicio -le 0) {
  $Exercicio = $anoAtual
  $e = Get-Entregas $Exercicio
  if (-not (Periodos $e).rreo_bimestre) { $entregas["$Exercicio"] = $e.itens; $Exercicio--; $e = Get-Entregas $Exercicio }
} else { $e = Get-Entregas $Exercicio }
$entregas["$Exercicio"] = $e.itens
$per = Periodos $e
if (-not $per.rgf_periodicidade) { $per.rgf_periodicidade = 'Q' }

$amostra = @($e.itens | Where-Object { $_.orgao -match '^Prefeitura' } | Select-Object -First 1)
if (-not $saidaObj.municipio.nome -and $amostra) { $saidaObj.municipio.nome_siconfi = $amostra[0].orgao }

$saidaObj.periodo_referencia = [ordered]@{ exercicio = $Exercicio; rreo_bimestre = $per.rreo_bimestre; rgf_periodo = $per.rgf_periodo; rgf_periodicidade = $per.rgf_periodicidade }
$saidaObj.indicadores = Get-Indicadores $Exercicio $per.rreo_bimestre $per.rgf_periodo $per.rgf_periodicidade -Completo

# Populacao vem nas linhas do Siconfi
try {
  $pop = (Get-Siconfi 'rreo' @{ an_exercicio = $Exercicio; nr_periodo = $(if ($per.rreo_bimestre) { $per.rreo_bimestre } else { 6 }); co_tipo_demonstrativo = 'RREO'; no_anexo = 'RREO-Anexo 01'; id_ente = $Ibge }).itens | Select-Object -First 1
  if ($pop) { $saidaObj.municipio.populacao_siconfi = $pop.populacao; if (-not $saidaObj.municipio.uf) { $saidaObj.municipio.uf = $pop.uf } }
} catch { [void]$avisos.Add("Populacao nao obtida: $($_.Exception.Message)") }

# Serie historica (exercicios fechados)
$serie = @()
for ($a = $Exercicio - 1; $a -ge $Exercicio - $Anos; $a--) {
  try {
    $eh = Get-Entregas $a; $entregas["$a"] = $eh.itens
    $ph = Periodos $eh
    $pdc = if ($ph.rgf_periodicidade) { $ph.rgf_periodicidade } else { 'Q' }
    $fim = if ($pdc -eq 'S') { 2 } else { 3 }
    $bimH = if ($ph.rreo_bimestre -eq 6) { 6 } else { $null }
    $rgfH = if ($ph.rgf_periodo -eq $fim) { $fim } else { $null }
    if (-not $bimH) { [void]$avisos.Add("$a : RREO do 6o bimestre nao consta no extrato.") }
    if (-not $rgfH) { [void]$avisos.Add("$a : RGF do ultimo periodo nao consta no extrato.") }
    $serie += [ordered]@{ exercicio = $a; rreo_bimestre = $bimH; rgf_periodo = $rgfH; rgf_periodicidade = $pdc; indicadores = (Get-Indicadores $a $bimH $rgfH $pdc) }
  } catch { [void]$avisos.Add("Serie $a falhou: $($_.Exception.Message)") }
}
$saidaObj.serie_historica = $serie

# Entregas resumidas
$saidaObj.entregas = $entregas
$saidaObj.legenda_status_entrega = [ordered]@{ HO = 'homologado'; RE = 'retificado (substitui versao homologada)'; vazio = 'sem status de homologacao informado (comum em MSC); nao confirma homologacao' }

# CAPAG
if (-not $SemCapag) {
  try {
    $cp = Get-Capag
    if ($cp.encontrado) {
      $nota = [string]$cp['CAPAG']
      $cp.status_sugerido_trilha2 = if ($nota -match '^[AB]') { 'REGULAR' } elseif ($nota -match '^[CD]') { 'IMPEDITIVO' } else { 'SEM DADO' }
      $cp.observacao = 'Garantia da Uniao exige, em regra, CAPAG A ou B (Portaria MF 501/2017 e normas posteriores). Verificar excecoes legais vigentes antes de concluir.'
    } else { [void]$avisos.Add('Municipio nao encontrado na planilha CAPAG mais recente.') }
    $saidaObj.capag = $cp
  } catch { $saidaObj.capag = [ordered]@{ encontrado = $false; erro = $_.Exception.Message }; [void]$avisos.Add("CAPAG indisponivel: $($_.Exception.Message)") }
}

$saidaObj.nao_coberto = @('CAUC', 'SADIPEM/PVL', 'CNDT (TST)', 'CRF-FGTS (Caixa)', 'TCU/CGU (CEIS, CNEP, CEPIM)', 'plano anual da Portaria 808', 'legislacao local')
$saidaObj.avisos = @($avisos)

$json = $saidaObj | ConvertTo-Json -Depth 12
if ($Saida) { [IO.File]::WriteAllText($Saida, $json, (New-Object Text.UTF8Encoding($false))) }
$json
