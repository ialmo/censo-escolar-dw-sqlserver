# Projeto Prático 2 – ETL e DW do Censo Escolar (SQL Server)

Aluno: Ialmo Gontijo

Pipeline 100% em objetos do SQL Server (procedures, functions e triggers) que carrega os
microdados do Censo Escolar 2024 e 2025 (INEP) em um DW estrela no banco `db_educacional`.

## Conteúdo do pacote

| Arquivo / pasta | Conteúdo |
|---|---|
| `sql/01` a `sql/08` | Scripts, executados nesta ordem |
| `formatos/` | Arquivos de formato XML do `OPENROWSET(BULK)` (expõem só as colunas usadas) |
| `Documento_de_Arquitetura.pdf` | Arquitetura, regras, decisões e resultados |
| `Dicionario_de_Dados.pdf` | Origem, tipo e descrição de cada coluna |
| `evidencia*.png` | Prints da execução |

Os microdados **não estão incluídos** (cerca de 500 MB). Eles são públicos, no portal do
INEP (Microdados do Censo Escolar da Educação Básica, anos 2024 e 2025). Arquivos usados:

| Ano | Arquivo dentro do ZIP do INEP |
|---|---|
| 2024 | `microdados_censo_escolar_2024_defeso/dados/microdados_ed_basica_2024.csv` |
| 2025 | `microdados_censo_escolar_2025_v2/dados/Tabela_Escola_2025_V2.csv` |
| 2025 | `microdados_censo_escolar_2025_v2/dados/Tabela_Matricula_2025_V2.csv` |

Os CSVs devem ser usados como vêm do INEP (Latin-1, separador `;`), sem abrir e salvar no Excel.

## 1. Disponibilizar os arquivos ao SQL Server

O `OPENROWSET(BULK)` lê o disco **do servidor SQL Server**. O script 07 espera esta estrutura
(ajuste a variável `@base` no script 07 se usar outro caminho):

```
<@base>/formatos/fmt_ed_basica_2024.xml
<@base>/formatos/fmt_escola_2025.xml
<@base>/formatos/fmt_matricula_2025.xml
<@base>/microdados_censo_escolar_2024_defeso/dados/microdados_ed_basica_2024.csv
<@base>/microdados_censo_escolar_2025_v2/dados/Tabela_Escola_2025_V2.csv
<@base>/microdados_censo_escolar_2025_v2/dados/Tabela_Matricula_2025_V2.csv
```

Valor padrão: `@base = '/var/opt/mssql/projeto/'` (SQL Server em container Linux).
No Windows, use um caminho local, por exemplo `@base = 'C:\projeto\'`, com as mesmas subpastas.

Exemplo para container Docker (`C` = nome do container), a partir da pasta onde estão
`formatos/` e as pastas dos microdados:

```bash
C=sqlserver
D=/var/opt/mssql/projeto
docker exec -u 0 $C mkdir -p $D/microdados_censo_escolar_2024_defeso/dados $D/microdados_censo_escolar_2025_v2/dados
docker cp formatos $C:$D/
docker cp microdados_censo_escolar_2024_defeso/dados/microdados_ed_basica_2024.csv $C:$D/microdados_censo_escolar_2024_defeso/dados/
docker cp microdados_censo_escolar_2025_v2/dados/Tabela_Escola_2025_V2.csv $C:$D/microdados_censo_escolar_2025_v2/dados/
docker cp microdados_censo_escolar_2025_v2/dados/Tabela_Matricula_2025_V2.csv $C:$D/microdados_censo_escolar_2025_v2/dados/
docker exec -u 0 $C chmod -R a+rX $D
```

## 2. Executar os scripts (SSMS, Azure Data Studio ou VS Code)

| Script | O que faz | Tempo aprox. |
|---|---|---|
| `01_banco_e_esquemas.sql` | banco + esquemas `staging` e `dw` | segundos |
| `02_staging.sql` | tabelas da staging | segundos |
| `03_dw.sql` | dimensões, fato, auditoria e logs | segundos |
| `04_functions.sql` | functions (termina com um SELECT de teste) | segundos |
| `05_triggers.sql` | triggers | segundos |
| `06_procedures.sql` | views e procedures | segundos |
| `07_executar_pipeline.sql` | configura os arquivos e carrega 2024 e depois 2025 | alguns minutos |
| `08_validacao_e_testes.sql` | conferência, evidências e testes | alguns minutos |

A seção 1 do script 08 deve mostrar **OK em todas as linhas**.

Para recarregar do zero, execute novamente **do 02 ao 07, sem pular nenhum**: os scripts 02 e 03
recriam as tabelas, e o SQL Server apaga os triggers junto com a tabela (o 05 os recria).
Os anos devem ser carregados em ordem: 2024 antes de 2025.

Requisito: SQL Server 2019 ou superior. Com `sqlcmd`, use `-I` e `-f 65001`.

## 3. Problemas comuns

| Mensagem | Causa provável |
|---|---|
| `Cannot bulk load ... Operating system error code 2` | caminho errado – confira `staging.arquivo_fonte` |
| `... Operating system error code 5` | sem permissão de leitura para o serviço do SQL Server |
| acentos quebrados (`Ã£`) | o CSV foi regravado em UTF-8; use o arquivo original do INEP |
| `CHECK constraint "ck_fact_matricula_qt"` | o trigger da RT06 não existe; rode o script 05 depois de recriar as tabelas |
