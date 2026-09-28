# Plano de migração — tirar Gitea, SonarQube e Grafana do `auditoria-2.0`

> **Status (2026-09-28):**
> - **Fase 0:** repo com a estrutura da §3.1, rede `devtools`, backups de Sonar e Gitea,
>   inventário (Gitea: usuário `tnfagundes`, segredo `SONAR_TOKEN`). D1 = (a). **Pendente:**
>   rotacionar A2.
> - **Fase 1 (Sonar): concluída.** Servidor migrado por cópia de volume, no ar em
>   `plataforma-sonar`. Mudanças do §5.2 em `auditoria-2.0@ccf08ca` (`develop`). Validado: 5.3-1,
>   5.3-2 (projeto, histórico, gate, profiles com S1135 desativada) e 5.3-4 (job `quality` verde
>   com o `ci.yml` novo, gate OK em 16:11 UTC). **Pendente:** 5.3-5 (SonarLint no editor).
> - **Ponte temporária:** o `plataforma-sonar-sonarqube-1` também está na rede antiga
>   `auditoria-2-0-sonar_sonarnet`, com alias `sonarqube`, porque a `master` do `auditoria-2.0`
>   ainda tem o `ci.yml` antigo. Desfazer quando a `develop` for integrada na `master`:
>   `docker network disconnect auditoria-2-0-sonar_sonarnet plataforma-sonar-sonarqube-1`.
>   (A ponte não sobrevive a um `up` que recrie o container.)
> - **Fase 2 (Gitea): concluída.** Volume copiado, no ar em `plataforma-gitea` (mesma porta 3001). Validado:
>   6.4-1 (healthz 200), 6.4-2 (repo com os mesmos refs, usuário `tnfagundes`, segredo
>   `SONAR_TOKEN`), 6.4-3 (runner `dev-box-wsl` reconectou sozinho) e 6.4-5 (`git push gitea`).
>   Mudanças do §6.3 em `auditoria-2.0@bd8c4ed`; o checkout via `GITHUB_SERVER_URL` funcionou no
>   job `quality`. 6.4-4 ok: `quality` (gate OK, 16:20 UTC) e `e2e` verdes nesse push.
> - **A1/A4:** corrigidos em `auditoria-2.0@b1f2334`. Os alertas não disparavam em ambiente
>   nenhum (o seletor por container não casava nada nem em dev); agora filtram por
>   `project`+`service`, ignoram os containers `*-run-*` (suíte de testes) e leem status/nível do
>   JSON. Prod só recebe no próximo deploy.
> - **Fase 3.1 (observabilidade de dev):** `plataforma-obs` no ar, começando sem histórico (decisão
>   do usuário). Promtail por opt-in (`logging: promtail`), já recebendo `app`/`nginx`/`scheduler`
>   de `auditoria-2-0`. `grafana-sync.sh` (genérico, nesta pasta) enviou dashboard e 3 regras pela
>   API, com token de service account `sync-auditoria-2-0` no `.env` do projeto; as regras avaliam
>   com `health: ok`. Mudanças do §7.1 em `auditoria-2.0@c1aca84`. Fora do
>   escopo por ora: contact points/policies por projeto (SMTP de dev está desligado). Prod
>   inalterada (D2 = Opção A).
> - Containers e volumes antigos (`auditoria-2-0-sonar*`, `auditoria-2-0-gitea*`,
>   `auditoria-2-0_loki-data`, `auditoria-2-0_grafana-data`) estão parados e
>   preservados, para rollback. Limpeza futura: o runner `dev-box` (sem contato desde 2026-07-08,
>   sobra da tentativa de runner em container), o volume `auditoria-2-0-gitea_runner-data` e os
>   volumes órfãos `auditoria-2-0_sonar-*`. Caminhos `auditoria-2.0/...` são relativos à raiz
> daquele repositório; "o projeto", sem qualificação, é o `auditoria-2.0`.
> **Relacionado:** `auditoria-2.0/docs/qualidade-codigo-sonarqube.md` (Sonar, Gitea,
> runner), `auditoria-2.0/CLAUDE.md` § Observabilidade e § Deploy em produção,
> `auditoria-2.0/docs/adr/0008-testes-e2e.md` (CI do E2E).

## 1. Objetivo

Hoje três ferramentas de uso geral vivem **dentro** do repositório `auditoria-2.0`:

- **Gitea**: hospedagem git + CI (Gitea Actions);
- **SonarQube**: análise estática + Quality Gate;
- **Grafana**, com **Loki** e **Promtail**: agregação de logs, dashboards e alertas.

A proposta é tirá-las de lá e transformá-las numa **plataforma de ferramentas** que sirva a este e
aos próximos projetos. Um projeto novo deve poder ter CI, Quality Gate e logs centralizados
**sem copiar compose, sem subir outra instância e sem disputar portas**.

**Veredito:** é possível. A dificuldade, porém, varia muito entre as três:

| Ferramenta | Dificuldade | Motivo |
|---|---|---|
| SonarQube | **Baixa** | O servidor não tem nada do `auditoria-2.0`. O que é do projeto (scanner + `sonar-project.properties`) **fica no `auditoria-2.0`**. |
| Gitea | **Baixa a média** | Já roda como stack própria. O cuidado está nos dados (repos, segredos, registro do runner) e na URL fixa no CI. |
| Grafana/Loki/Promtail | **Dev: baixa. Prod: decisão de arquitetura** | Em produção a stack vai no deploy da aplicação. Centralizar depende de existir um servidor de observabilidade compartilhado. |

---

## 2. Diagnóstico: como está hoje

### 2.1 Gitea

- **Onde:** `auditoria-2.0/docker-compose.gitea.yml`, projeto Compose
  `auditoria-2-0-gitea`, imagem `gitea/gitea:1.22`, **SQLite**, volume `gitea-data` (nome real
  no Docker: `auditoria-2-0-gitea_gitea-data`), portas `3001` (HTTP) e `2222` (SSH).
- **Runner:** `act_runner` **nativo no WSL**, em host mode, em `~/gitea-runner/`, registrado com
  label `native:host` contra `http://localhost:3001` e iniciado no logon pela tarefa agendada
  `GiteaActionsRunner` do Windows. Já foi pensado para ser reutilizável: o registro usa o token
  **de instância**, então atende qualquer repo desse Gitea
  (`auditoria-2.0/docs/qualidade-codigo-sonarqube.md`).
- **Amarras com este projeto:**
  1. **URL fixa no CI.** Os dois jobs clonam de
     `http://ci:<token>@localhost:3001/...` (`auditoria-2.0/.gitea/workflows/ci.yml`, step
     *Checkout* de `quality` e de `e2e`).
  2. **Remote git** `gitea` → `http://localhost:3001/tnfagundes/auditoria-2.0.git`.
  3. **Portas.** `GITEA_HTTP_PORT=3001` e `GRAFANA_PORT=3001` são os **dois defaults** no
     `.env.example`. Hoje o choque só é evitado porque o `.env` local muda o Grafana para 3002.
  4. **Nome do projeto/volume** com prefixo `auditoria-2-0-`.
  5. **Segredos do repo** (`SONAR_TOKEN`) guardados no banco do Gitea.

### 2.2 SonarQube

- **Onde:** `auditoria-2.0/docker-compose.sonar.yml`, projeto
  `auditoria-2-0-sonar`: `sonarqube` (community) + `sonar-db` (Postgres 17 dedicado) + `scanner`
  (profile `scan`), rede `sonarnet`, volumes `sonar-data`, `sonar-extensions`, `sonar-logs` e
  `sonar-db-data`.
- **O que é do servidor (sai do projeto):** `sonarqube` e `sonar-db`.
- **O que é do projeto (fica):**
  - o **serviço `scanner`**: monta a raiz do repo e usa o volume
    `auditoria-2-0_frontend-node-modules` da stack de dev para resolver os tipos do TS;
  - o `auditoria-2.0/sonar-project.properties`;
  - os alvos `sonar`/`quality` do `auditoria-2.0/Makefile`.
- **Amarras:**
  1. O scanner alcança o servidor como `http://sonarqube:9000` **pela rede `sonarnet`**. No CI,
     o step do scanner força `COMPOSE_PROJECT_NAME=auditoria-2-0-sonar` justamente para cair
     nessa rede.
  2. **Configuração que não está no git.** Os Quality Profiles `Auditoria 2.0` (PHP/TS/JS, com
     a S1135 desligada), o Quality Gate "Auditoria 2.0 - Clean as You Code", o histórico e os
     tokens vivem **só no volume `sonar-db-data`**.
  3. O SonarLint em Connected Mode aponta para `http://localhost:9000`
     (`auditoria-2.0/.vscode/settings.json`).
  4. O `vm.max_map_count=262144` precisa estar configurado no host que roda o Sonar.

### 2.3 Grafana + Loki + Promtail

- **Onde:** dentro da **stack da aplicação**, tanto em dev (`auditoria-2.0/docker-compose.yml`,
  rede `appnet`) quanto em **prod** (`auditoria-2.0/docker-compose.prod.yml`).
  Configs por bind mount em `docker/loki/`, `docker/promtail/` e `docker/grafana/provisioning/`.
- **Amarras (a maior das três):**
  1. **Faz parte do deploy de produção.** O CLAUDE.md lista a stack entre os containers de prod,
     e o checklist de deploy manda copiar `docker/{loki,promtail,grafana}` e rodar
     `chmod -R a+rX docker/`.
  2. **O Promtail só aceita projetos `auditoria-2-0.*|auditoria-20.*`**
     (`auditoria-2.0/docker/promtail/config.yml`): logs de qualquer outro projeto são
     descartados.
  3. **Os dashboards consultam por `service` sem filtrar projeto**, por exemplo
     `{service="nginx"}` em `auditoria-2.0/docker/grafana/provisioning/dashboards/requests.json`.
     Num Loki compartilhado, o nginx de outro projeto entraria na mesma contagem. **Isso já
     acontece hoje em dev**: a stack de dev e a de E2E (`auditoria-2-0-e2e`) passam pelo filtro e
     se misturam nos painéis.
  4. **As regras de alerta usam nomes de container de dev**, por exemplo
     `{container="auditoria-2-0-app-1"}` em
     `auditoria-2.0/docker/grafana/provisioning/alerting/rules.yml`. Ver achado **A1** na §9.
  5. O SMTP dos alertas em prod usa as `MAIL_*` da aplicação e o contact point
     `email-alertas` é único (`auditoria-2.0/docker/grafana/provisioning/alerting/alerting.yml`).
  6. O datasource tem `uid: loki` fixo, e dashboards e regras dependem dele.
- **Limite físico:** o Promtail lê o `docker.sock` **local**. Ele não pode ser centralizado e
  precisa rodar **em cada host** que tenha containers para coletar.

---

## 3. Arquitetura-alvo

### 3.1 Um repositório de plataforma

Criar um repositório próprio. O nome é sugestão: **`plataforma-dev`**.

```
plataforma-dev/
  README.md                      # o que tem, portas, como um projeto se conecta
  Makefile                       # up/down/backup/restore por ferramenta
  .env.example
  rede.md                        # a rede externa e o mapa de portas
  gitea/
    docker-compose.yml           # name: plataforma-gitea
  sonarqube/
    docker-compose.yml           # name: plataforma-sonar  (sonarqube + sonar-db)
    runbook.md                   # vm.max_map_count, backup, profiles, tokens
  observabilidade/
    docker-compose.yml           # name: plataforma-obs    (loki + grafana)
    loki/config.yml
    grafana/provisioning/
      datasources/loki.yml       # uid: loki (mantido)
      dashboards/dashboards.yml  # um provider por projeto (ver §7)
  runner/
    README.md                    # act_runner nativo: instalação, registro, tarefa agendada
```

### 3.2 Uma rede Docker compartilhada, com nome fixo

Criar uma vez: `docker network create devtools`. Cada compose da plataforma entra nela e cada
projeto consumidor a declara como externa:

```yaml
networks:
  devtools:
    external: true
    name: devtools
```

Com isso os serviços se encontram pelo nome (`sonarqube:9000`, `loki:3100`) **sem depender do
`COMPOSE_PROJECT_NAME`**, o que resolve a amarra 2.2-1.

> A rede só vale para ferramentas no **mesmo host** que o projeto. Se a plataforma for para um
> servidor (§3.3), o acesso passa a ser por URL/IP e a rede deixa de ser necessária para os
> consumidores.

### 3.3 Onde a plataforma roda (decisão D1)

| Opção | Prós | Contras |
|---|---|---|
| **(a) Na máquina de dev, como hoje, mas fora do repo** | Migração quase sem risco: mesmas portas, mesmo runner, CI inalterado. | Continua "global" só para quem usa essa máquina. Divide RAM com dev + E2E + Sonar (ver memória de flakiness por pressão de memória). |
| **(b) Num servidor da intranet** (ex.: o host do registry `10.6.130.22`) | Global de verdade para a equipe; libera RAM da máquina de dev; sobe 24/7. | Precisa de host com RAM (Sonar ≥ 2 GB + ES), `vm.max_map_count`, backup via Airflow, NO_PROXY e ajuste de URL no CI. |

**Recomendação:** fazer em **duas etapas**. Primeiro **(a)**: desacoplar sem mudar de host, com
risco mínimo e as mesmas URLs. Depois **(b)**, quando houver host definido. O plano abaixo
separa o que muda em cada etapa.

### 3.4 Mapa de portas proposto

Hoje as portas colidem por default (Gitea 3001 × Grafana 3001; 3000 é do Gotenberg). A plataforma
passa a ser **dona** destas portas, e nenhum projeto as usa:

| Serviço | Porta host | Observação |
|---|---|---|
| Gitea HTTP | 3001 | mantida: runner e remotes continuam válidos na etapa (a) |
| Gitea SSH | 2222 | mantida |
| SonarQube | 9000 | mantida: SonarLint continua válido |
| Grafana | 3002 | é o valor que o `.env` local já usa |
| Loki | não publicada | só pela rede `devtools`; em prod, via Grafana |

---

## 4. Fase 0 — Preparação (antes de mover qualquer coisa)

1. **Rotacionar credenciais expostas (achado A2, §9).** O `auditoria-2.0/.claude/settings.json`
   é **versionado** e guarda, em entradas da allowlist, a **senha do admin do Gitea** e um
   **token de acesso** em texto claro. O repo tem remote no GitHub (`origin`). Antes da
   migração:
   - trocar a senha do usuário admin e revogar o token no Gitea;
   - remover essas entradas do `settings.json` (trocar por padrões com curinga, ou mover para o
     `settings.local.json`, que não é versionado);
   - se o arquivo já foi para o GitHub, considerar as credenciais **comprometidas** mesmo depois
     de apagadas, porque ficam no histórico.
2. **Backups completos** (servem de rollback em todas as fases):
   ```bash
   # Sonar: banco (histórico, gate, profiles, tokens)
   docker compose -f docker-compose.sonar.yml exec -T sonar-db \
     pg_dump -U sonar sonar | gzip > sonar-db-$(date +%F).sql.gz

   # Gitea: dump oficial (repos + sqlite + config)
   docker compose -f docker-compose.gitea.yml exec -u git gitea \
     gitea dump -c /data/gitea/conf/app.ini -f /tmp/gitea-dump.zip
   docker compose -f docker-compose.gitea.yml cp gitea:/tmp/gitea-dump.zip ./gitea-dump-$(date +%F).zip

   # Grafana/Loki (dev): em geral descartáveis; faça tar do volume se houver
   # dashboard editado pela UI que não esteja no provisioning
   ```
3. **Anotar o que não está no git:** segredos cadastrados no repo do Gitea (hoje o
   `SONAR_TOKEN`), expiração dos tokens do Sonar (no `.env`, 02/11/2026) e usuários do Gitea.
   Como os dois tokens do Sonar vencem em 02/11/2026, vale fazer a migração **antes** disso ou
   já rotacioná-los durante ela.
4. **Criar o repo `plataforma-dev`** com a estrutura da §3.1 e a rede `devtools`.
5. **Registrar a decisão D1** (onde a plataforma roda) e a **D2** (Grafana em prod, §7.2).

---

## 5. Fase 1 — SonarQube

### 5.1 Na plataforma

`plataforma-dev/sonarqube/docker-compose.yml` = os serviços `sonarqube` + `sonar-db` do compose
atual, **sem o `scanner`** e **sem o volume externo `frontend-node-modules`**, com `name:
plataforma-sonar`, rede `devtools` no lugar de `sonarnet` e `restart: unless-stopped`.

**Migrar os dados** (escolher um caminho):

- **Cópia de volume** (preserva tudo byte a byte). Com o Sonar antigo **parado**:
  ```bash
  for v in sonar-data sonar-extensions sonar-db-data; do
    docker volume create plataforma-sonar_$v
    docker run --rm -v auditoria-2-0-sonar_$v:/de:ro -v plataforma-sonar_$v:/para \
      alpine sh -c 'cp -a /de/. /para/'
  done
  ```
  (`sonar-logs` pode começar vazio.) Os volumes antigos ficam intactos e servem de rollback.
- **pg_dump/restore** (obrigatório se mudar de host na etapa b): subir só o `sonar-db` novo,
  restaurar o dump da Fase 0, depois subir o `sonarqube`. Os índices do Elasticsearch
  (`sonar-data`) se reconstroem sozinhos a partir do banco.

**Não reutilizar o volume antigo como `external`.** Funciona, mas perpetua o prefixo
`auditoria-2-0-` numa ferramenta que deixou de ser do projeto.

### 5.2 No `auditoria-2.0`

| Arquivo | Mudança |
|---|---|
| `auditoria-2.0/docker-compose.sonar.yml` | Fica **só o `scanner`**. Sai `sonarqube`, `sonar-db`, `depends_on` e os volumes do servidor. Rede `sonarnet` → `devtools` (external). Mantém o volume externo `frontend-node-modules`. `name:` pode virar `auditoria-2-0-scan`. |
| `auditoria-2.0/.gitea/workflows/ci.yml` | No step do scanner, **remover** o `COMPOSE_PROJECT_NAME: auditoria-2-0-sonar` e o comentário que o justifica, porque a rede deixa de depender do nome do projeto. `--no-deps` passa a ser redundante. |
| `auditoria-2.0/Makefile` | `sonar-up`/`sonar-down` saem (ou viram um aviso apontando para `plataforma-dev`). `sonar` continua. |
| `auditoria-2.0/.env.example` | Saem `SONAR_PORT`, `SONAR_DB_USER`, `SONAR_DB_PASSWORD`. Ficam `SONAR_HOST_URL`, `SONAR_TOKEN`, `SONAR_USER_TOKEN`. |
| `auditoria-2.0/docs/qualidade-codigo-sonarqube.md` | §B.5 (runbook do servidor) vai para `plataforma-dev/sonarqube/runbook.md`; no `auditoria-2.0` fica um link. |
| `auditoria-2.0/.vscode/settings.json` | Etapa (a): nada muda. Etapa (b): `connectionId` → URL do servidor. |

**Na etapa (b)**, `SONAR_HOST_URL=http://<host>:9000`. O scanner deixa de precisar da rede
`devtools`, mas **continua precisando** do volume de `node_modules` local.

### 5.3 Validação

1. `curl -s localhost:9000/api/system/status` → `"status":"UP"`.
2. UI: projeto `auditoria-2-0` com histórico; Quality Gate associado; profiles `Auditoria 2.0`
   presentes e com a S1135 **desativada**.
3. `make sonar` local passa.
4. Um push no Gitea → job `quality` verde, com o gate avaliado (`wait=true`).
5. SonarLint no VS Code conectado, e **"todo" em PT-BR não sublinhado** (prova de que os
   profiles vieram junto).

**Rollback:** `docker compose -f plataforma-dev/sonarqube/docker-compose.yml down` e reverter o
commit no `auditoria-2.0`. Os volumes antigos foram preservados.

---

## 6. Fase 2 — Gitea

### 6.1 Na plataforma

`plataforma-dev/gitea/docker-compose.yml` = o compose atual com `name: plataforma-gitea`, rede
`devtools` no lugar de `gitea-net` e o volume `gitea-data`.

**Migrar os dados:** com o Gitea antigo **parado**, copiar o volume
(`auditoria-2-0-gitea_gitea-data` → `plataforma-gitea_gitea-data`) do mesmo jeito da §5.1. Se
mudar de host, usar o `gitea dump` da Fase 0 e seguir o procedimento de restore da documentação
do Gitea (descompactar em `/data`, ajustar dono `git:git`).

**Aproveitar a migração para:**
- **Fixar a versão** da imagem num patch (`gitea/gitea:1.22.x`) e planejar upgrade. A 1.22 já
  tem versões mais novas; o upgrade é um passo **separado**, depois da migração validada.
- **Etapa (b):** trocar `ROOT_URL`/`DOMAIN` para o host/DNS interno, e considerar Postgres
  quando houver vários projetos e usuários. SQLite atende bem uma equipe pequena.

### 6.2 Runner

- **Etapa (a):** **nada muda.** A URL `http://localhost:3001` continua válida, e o registro em
  `~/gitea-runner/.runner` continua apontando para ela.
- **Etapa (b):** o runner **continua nativo no WSL**, na máquina que tem o Docker do projeto,
  porque ele precisa orquestrar o `docker compose` local. Muda só o endereço: editar `address`
  em `~/gitea-runner/.runner` ou registrar de novo com
  `--instance http://<host>:3001`. Garantir que o IP do host está no `NO_PROXY` do WSL.
- **Para vários projetos e máquinas:** um runner por **máquina**, com labels que digam o que
  ela oferece (ex.: `native`, `docker-compose`). Não se registra runner por projeto (o
  token é de instância).

### 6.3 No `auditoria-2.0`

| Arquivo | Mudança |
|---|---|
| `auditoria-2.0/docker-compose.gitea.yml` | **Sai do repo** (vai para `plataforma-dev`). |
| `auditoria-2.0/.gitea/workflows/ci.yml` | Tirar `localhost:3001` dos **dois** steps *Checkout* (jobs `quality` e `e2e`). Ver snippet abaixo. |
| `auditoria-2.0/.env.example` | Saem `GITEA_HTTP_PORT`, `GITEA_SSH_PORT`, `GITEA_RUNNER_TOKEN`. O `NO_PROXY` mantém `gitea`/`10.6.130.22` e ganha o host novo, se for outro. |
| `auditoria-2.0/docs/qualidade-codigo-sonarqube.md` | §B.6 (runner) vai para `plataforma-dev/runner/README.md`; no `auditoria-2.0` fica um link. |
| `auditoria-2.0/docker-compose.e2e.yml` | Só o comentário da linha 10, se mencionar a localização do Gitea. |

Checkout sem host fixo. O Gitea Actions expõe `GITHUB_SERVER_URL` = `ROOT_URL` da instância:

```yaml
- name: Checkout
  run: |
    srv="${GITHUB_SERVER_URL%/}"
    git clone --no-single-branch --depth 1 \
      "${srv%%://*}://ci:${{ github.token }}@${srv#*://}/${{ github.repository }}.git" .
    git checkout "${GITHUB_HEAD_REF:-$GITHUB_REF_NAME}"
    git log --oneline -1
```

> Por que o clone usava `localhost`: para **não passar pelo proxy corporativo**. Com host remoto,
> o mesmo efeito vem do `NO_PROXY` contendo o IP/DNS do Gitea. Validar isso **antes** de trocar,
> com um `git ls-remote` a partir do WSL.

**Remote local do desenvolvedor** (etapa b): `git remote set-url gitea http://<host>:3001/tnfagundes/auditoria-2.0.git`.

### 6.4 Validação

1. `curl -s -o /dev/null -w "%{http_code}" http://localhost:3001/api/healthz` → `200`.
2. Login, repo, histórico, **segredo `SONAR_TOKEN`** presente em Settings → Actions → Secrets.
3. Admin → Actions → Runners: `dev-box-wsl` **online**.
4. Push em branch de teste → jobs `quality` **e** `e2e` rodam (o `e2e` também tem checkout).
5. `git push gitea` a partir da máquina de dev.

**Rollback:** parar o Gitea da plataforma e subir de novo o `docker-compose.gitea.yml` antigo
(ainda no histórico do git); o volume antigo está preservado.

---

## 7. Fase 3 — Grafana, Loki e Promtail

Aqui há duas situações diferentes, e o plano trata cada uma separadamente.

### 7.1 Dev — separar (recomendado)

**Na plataforma** (`plataforma-dev/observabilidade/`):
- `loki` + `grafana` na rede `devtools`, Grafana na **3002**, Loki sem porta publicada. O
  datasource continua com `uid: loki`.
- `promtail` também na plataforma, **uma instância por host** (em dev, o host é a mesma
  máquina), coletando todos os projetos que optarem por isso.

**Promtail: trocar a allowlist de nomes por opt-in por label.** Em vez da regex
`auditoria-2-0.*|auditoria-20.*`, cada serviço declara que quer ter os logs coletados:

```yaml
# no compose de CADA projeto, nos serviços que devem ser coletados
labels:
  logging: promtail
```
```yaml
# promtail/config.yml da plataforma
- source_labels: ['__meta_docker_container_label_logging']
  regex: 'promtail'
  action: keep
```

O label `project` (nome do projeto Compose) continua sendo extraído e passa a ser **obrigatório
em toda query**. O pipeline JSON atual serve para qualquer app Laravel + nginx no mesmo padrão;
um projeto com formato diferente ganha um `match` próprio no pipeline.

**Dashboards e alertas continuam versionados no `auditoria-2.0`**, porque descrevem esta aplicação. O
Grafana da plataforma os lê por provider:

```yaml
# plataforma-dev/observabilidade/grafana/provisioning/dashboards/dashboards.yml
providers:
  - name: auditoria-2-0
    folder: 'Auditoria 2.0'
    type: file
    options: { path: /var/lib/grafana/projetos/auditoria-2-0/dashboards }
```

Como o conteúdo chega ao Grafana, em ordem de preferência:
1. **API do Grafana** (`POST /api/dashboards/db`, `/api/v1/provisioning/alert-rules`) chamada
   por um alvo `make grafana-sync` do `auditoria-2.0`. Não acopla filesystems e funciona igual em host
   remoto.
2. **Bind mount** do diretório do projeto no compose da plataforma. Simples, mas só funciona no
   mesmo host e faz a plataforma conhecer o caminho dos projetos.

**Ajustes nos artefatos do `auditoria-2.0` (obrigatórios em qualquer cenário compartilhado):**
- `auditoria-2.0/docker/grafana/provisioning/dashboards/requests.json`: adicionar
  `project=~"$projeto"` em **todas** as queries, com uma variável de dashboard `projeto`
  (valores: `auditoria-2-0`, `auditoria-2-0-prod`, `auditoria-2-0-e2e`). Isso resolve também a
  mistura dev+E2E que já existe.
- `auditoria-2.0/docker/grafana/provisioning/alerting/rules.yml`: trocar
  `container="auditoria-2-0-app-1"` por `project="<projeto>", service="app"` (ver **A1**).
- `auditoria-2.0/docker/grafana/provisioning/alerting/alerting.yml`: o contact point e a
  notification policy passam a ser **por projeto** (`email-auditoria-2-0`), com rota por label
  `project`. Hoje existe uma única policy raiz, e numa instância compartilhada um projeto
  receberia os alertas de outro.

**No `auditoria-2.0` (dev):**

| Arquivo | Mudança |
|---|---|
| `auditoria-2.0/docker-compose.yml` | Saem `loki`, `promtail`, `grafana` e os volumes `loki-data`/`grafana-data`. Os serviços `app`, `worker`, `scheduler`, `nginx` ganham `labels: { logging: promtail }`. |
| `auditoria-2.0/Makefile` | `logs-up`/`logs-down`/`grafana` saem (ou apontam para a plataforma). Entra `grafana-sync`. |
| `docker/loki/`, `docker/promtail/` | Saem de **dev** (mas veja 7.2: continuam necessários para **prod** se a opção for manter). |
| `docker/grafana/provisioning/` | Fica, como **fonte** dos dashboards e alertas do projeto. |
| `auditoria-2.0/.env.example` | Saem `LOKI_PORT`, `GRAFANA_PORT`, `GRAFANA_PASSWORD`, `GF_SMTP_*` de dev. |
| `auditoria-2.0/CLAUDE.md` | Seção Observabilidade: o "Uso" passa a apontar para a plataforma. |

### 7.2 Produção — decisão D2

O Promtail **tem que rodar no servidor da aplicação** em qualquer opção. O que se discute é onde
ficam Loki e Grafana.

| | **Opção A — manter embutido (como hoje)** | **Opção B — Loki + Grafana centrais** |
|---|---|---|
| Pré-requisito | nenhum | um **servidor de observabilidade** na intranet, com backup (Airflow) e retenção definida |
| No servidor da app | loki + promtail + grafana | só **promtail**, enviando para `http://<obs-host>:3100` |
| `docker-compose.prod.yml` | igual | saem `loki`/`grafana` e volumes `loki-storage`/`grafana-storage`; o `promtail` ganha a URL do Loki central por env |
| Deploy | copia `docker/{loki,promtail,grafana}` | copia só `docker/promtail/`; dashboards e alertas vão por `grafana-sync` contra o Grafana central |
| Visão entre sistemas | não (um Grafana por app) | sim (todos os projetos num lugar) |
| Ponto único de falha | não | sim, para **logs e alertas**: se o host central cair, somem os alertas de todas as apps |
| Rede | local | o Loki central precisa aceitar push dos servidores de app (porta 3100 entre hosts); avaliar autenticação (hoje `auth_enabled: false`) |

**Recomendação:** **Opção A até existir o servidor de observabilidade**. Com mais de um sistema
em produção querendo o mesmo painel, migrar para a **B**. Mesmo na A, vale aplicar agora os
ajustes de artefato da §7.1 (filtro por `project`, regras sem nome de container), porque eles
corrigem **A1** e deixam a mudança para B barata.

A troca para B **reverte uma decisão registrada** (containers de prod no CLAUDE.md, checklist de
deploy, `Makefile.prod`) e exige **ADR própria**. Gitea e Sonar são ferramentas de dev e não
precisam.

---

## 8. Como um projeto novo passa a usar a plataforma

Checklist de onboarding (vai para o `README` da `plataforma-dev`):

- **Gitea:** criar o repo, cadastrar os segredos (ex.: `SONAR_TOKEN`), escrever
  `.gitea/workflows/*.yml` com `runs-on: native` e checkout via `GITHUB_SERVER_URL` (§6.3).
  Nenhum runner novo.
- **Sonar:** criar o projeto na UI (ou via API), gerar um *Global Analysis Token* ou por
  projeto, associar gate e profiles, versionar `sonar-project.properties` e um serviço
  `scanner` no compose do projeto ligado à rede `devtools` (ou por URL).
- **Logs:** adicionar `labels: { logging: promtail }` nos serviços, emitir logs em JSON (padrão
  `RequestLogger`), versionar dashboards e alertas no próprio repo, filtrar sempre por
  `project=`, e rodar o `grafana-sync`.

---

## 9. Achados colaterais (existem hoje, independentes da separação)

- **A1 — Alertas do Grafana não disparam em produção.** As regras em
  `auditoria-2.0/docker/grafana/provisioning/alerting/rules.yml` filtram por
  `container="auditoria-2-0-app-1"`, `auditoria-2-0-nginx-1` e `auditoria-2-0-worker-1`, nomes da
  stack de **dev**. Em prod o projeto é `auditoria-2-0-prod`, os containers se chamam
  `auditoria-2-0-prod-app-1` etc., e as queries não casam nada: `or vector(0)` → **sempre 0** →
  alerta nunca dispara, sem erro aparente. Correção: filtrar por `project` + `service` (§7.1).
  Vale tratar como item próprio do backlog, antes e independente da migração.
- **A2 — Credenciais em arquivo versionado.** O `auditoria-2.0/.claude/settings.json`
  (rastreado pelo git, com remote `origin` no GitHub) contém a senha do admin do Gitea e um token
  de acesso em entradas da allowlist de comandos. Tratar como na Fase 0, item 1.
- **A3 — Colisão de portas por default.** `.env.example` define `GITEA_HTTP_PORT=3001` **e**
  `GRAFANA_PORT=3001`. Quem copia o exemplo sem editar tem a segunda stack falhando ao subir.
  Some com a separação (§3.4).
- **A4 — Dashboards misturam dev e E2E.** As queries por `service=` sem `project=` somam as duas
  stacks, que passam pelo mesmo filtro do Promtail. Some com o filtro por `project` (§7.1).

---

## 10. Riscos e mitigação

| Risco | Mitigação |
|---|---|
| Perder profiles/gate do Sonar (não versionados) | Cópia de volume **ou** dump da Fase 0; validação 5.3-5 (S1135 no editor) |
| Perder repos/segredos do Gitea | `gitea dump` + volume antigo preservado até validar |
| CI quebra por proxy ao trocar `localhost` por host remoto | Etapa (a) primeiro (URL não muda); na (b), `NO_PROXY` + `git ls-remote` de teste antes |
| Runner "offline" após mudança | Etapa (a): nada muda; (b): editar `.runner` ou registrar de novo, conferir em Admin → Runners |
| Tokens do Sonar vencem em 02/11/2026 no meio da migração | Migrar antes ou rotacionar durante (atualizar `.env` **e** segredo do Gitea) |
| Grafana central vira ponto único de falha de alertas | Opção A em prod até existir host dedicado com backup |
| RAM na máquina de dev | Etapa (b) tira Sonar (o mais pesado) da máquina de dev |

## 11. Ordem de execução resumida

1. **Fase 0:** rotacionar A2, backups, criar `plataforma-dev` + rede `devtools`, decidir D1.
2. **Item de backlog independente:** corrigir **A1** (e A4) nos artefatos do Grafana.
3. **Fase 1:** Sonar para a plataforma, mesmo host; scanner fica no `auditoria-2.0`.
4. **Fase 2:** Gitea para a plataforma, mesmo host; CI com checkout via `GITHUB_SERVER_URL`.
5. **Fase 3.1:** observabilidade de dev para a plataforma (opt-in por label, sync de dashboards).
6. **Etapa (b), quando houver host:** mover Sonar e Gitea para o servidor (URL no CI, `NO_PROXY`,
   runner, SonarLint).
7. **Decisão D2 (ADR):** produção segue embutida (A) ou passa a Loki/Grafana central (B).
