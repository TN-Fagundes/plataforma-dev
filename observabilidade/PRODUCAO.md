# Observabilidade de produção

Loki + Promtail + Grafana centrais, numa stack própria **no servidor de produção**, fora do deploy
de qualquer aplicação. É uma instância **separada** da de dev (`docker-compose.yml`), com os mesmos
configs de Loki, Promtail e datasource. Decisão: D2 = Opção B, variante "stack própria no servidor
de prod" ([plano §7.2](../docs/plano-migracao.md)); no `auditoria-2.0`, ADR-0013.

| Peça | Onde | Observação |
|---|---|---|
| Compose | [docker-compose.prod.yml](docker-compose.prod.yml) | projeto `plataforma-obs-prod` |
| Loki | [loki/config.yml](loki/config.yml) | o mesmo de dev; retenção 7 dias; sem porta publicada |
| Promtail | [promtail/config.yml](promtail/config.yml) | o mesmo de dev; só coleta containers com `logging: promtail` |
| Datasource | [grafana/provisioning/datasources/](grafana/provisioning/datasources/) | `uid: loki` fixo, de que dashboards e regras dependem |
| Contact point + policy | [grafana/alerting-prod/](grafana/alerting-prod/) | só em prod; um destinatário (`GF_ALERTING_EMAIL_TO`) |
| Dashboards e regras | repositório de cada aplicação | chegam pela API (`grafana-sync.sh`), nunca por arquivo |
| Variáveis | [.env.prod.example](.env.prod.example) | copiar para `.env.prod` no servidor |
| Operação | [Makefile.prod](Makefile.prod) | copiar como `Makefile` no servidor |

## Estrutura no servidor

Nada é buildado: as imagens são as oficiais do Grafana, e os configs entram por bind mount.

```
/caminho/observabilidade/
  docker-compose.prod.yml
  Makefile                     (o Makefile.prod, renomeado)
  .env.prod                    (a partir do .env.prod.example)
  loki/config.yml
  promtail/config.yml
  grafana/provisioning/datasources/loki.yml
  grafana/provisioning/dashboards/dashboards.yml
  grafana/alerting-prod/alerting.yml
```

Host e caminhos ficam no `.env` da raiz do `plataforma-dev` (não versionado), nas variáveis
`PROD_SSH`, `PROD_OBS_DIR` e `PROD_APP_DIR` (ver [.env.example](../.env.example)). A partir da
raiz, na máquina de dev:

```bash
make obs-prod-check   # só leitura: projetos compose, containers, volumes e os dois diretórios
make obs-prod-copy    # mkdir + scp dos arquivos acima + .env.prod (se faltar) + permissões
```

O `obs-prod-copy` pode ser rodado de novo a cada mudança de config: não sobrescreve um
`.env.prod` já preenchido. Ele não sobe nem derruba nada; isso é manual, no servidor.

**Depois de cada cópia, os diretórios precisam de `a+rX`** (o `obs-prod-copy` já aplica; numa
cópia manual, rode `make perms` no diretório da stack, no servidor). O Grafana roda como
uid **472** e precisa atravessar cada diretório montado. Um `scp -r` com `umask 0077` cria
diretórios `700`, e o Grafana sobe **sem ler o provisioning**: sem datasource e sem contact point,
com um `Permission denied` visível só em `docker compose logs grafana`. O `.env.prod` fica `600`:
quem o lê é o `docker compose`, não o Grafana.

## Operação

No servidor, no diretório da stack (`make help` lista os alvos):

```bash
make up           # sobe (ou aplica mudança de config)
make ps
make logs s=grafana
make down         # derruba preservando os volumes
make perms        # a+rX nos diretórios e 600 no .env.prod, após cada cópia
```

Sem `make` no servidor, o equivalente é
`docker compose -f docker-compose.prod.yml --env-file .env.prod <comando>`.

Os dados ficam nos volumes `plataforma-obs-prod_loki-data` (logs, 7 dias) e
`plataforma-obs-prod_grafana-data` (usuários, service accounts, e o que o `grafana-sync` enviou).
Dashboards e regras podem ser reenviados a qualquer momento pelo repositório de cada aplicação;
usuários e tokens, não. Se for preciso backup do `grafana-data`, ele segue o padrão do ambiente
(Apache Airflow via SSH), nunca um cron próprio.

## Conectar uma aplicação

1. **Coleta:** no compose de produção da aplicação, `labels: { logging: promtail }` em cada
   serviço cujo log deve chegar ao Loki. Sem o label, o container é ignorado.
2. **Queries por `project`:** toda query de dashboard e de regra filtra pelo nome do projeto
   Compose da aplicação. Os logs de várias aplicações dividem o mesmo Loki.
3. **Service account:** no Grafana, *Administration → Users and access → Service accounts*, uma
   por aplicação (ex.: `sync-auditoria-2-0`), papel **Admin** (o sync cria pasta, dashboards e
   regras de alerta), e um token para ela. O token vai para o `.env` da máquina que roda o sync,
   nunca para o git.
4. **Sync:** `grafana-sync.sh <dir> <uid-pasta> "<Título>"` com
   `GRAFANA_URL=http://<servidor>:3001` e `GRAFANA_TOKEN=<token>`. No `auditoria-2.0`:
   `make grafana-sync-prod`. Rode de novo a cada mudança nos dashboards ou regras.

A partir da máquina de dev, o `curl` do sync precisa alcançar o servidor **sem passar pelo proxy
corporativo**: o IP do servidor tem que estar no `NO_PROXY`/`no_proxy` do shell que roda o `make`.

## Aplicação em outro host

O Promtail desta stack só enxerga o `docker.sock` do servidor onde roda. Para coletar uma
aplicação de outro host:

- publicar a porta do Loki neste servidor (`3100`), restrita por firewall aos hosts das
  aplicações, porque o Loki roda com `auth_enabled: false`;
- subir **só um Promtail** no host da aplicação, com o mesmo `promtail/config.yml` e
  `clients[0].url` apontando para `http://<servidor>:3100/loki/api/v1/push`.

Ainda não é necessário e não está montado.

## Acesso e dado pessoal

Os logs das aplicações carregam dado pessoal: o `auditoria-2.0` registra `user_nip` e `ip` em cada
request. Numa instância compartilhada, **quem entra no Grafana lê os logs de todas as
aplicações**. Crie contas nominais com papel **Viewer** e reserve Editor/Admin para quem opera a
plataforma. O regime de retenção desse dado ainda não está declarado nos requisitos do
`auditoria-2.0` (pendência registrada no backlog de lá).

## Migração a partir da stack embutida do auditoria-2.0

Feita uma vez, no servidor de produção. Até o ADR-0013, o `auditoria-2.0` subia Loki, Promtail e
Grafana no próprio `docker-compose.yml`, com o Grafana na porta 3001.

1. **Copiar esta stack** para o servidor: `make obs-prod-check` e `make obs-prod-copy` (seção
   *Estrutura no servidor*), depois preencher o `.env.prod` lá. **Ainda não subir**: a 3001 está
   com o Grafana antigo.
2. **Atualizar o `auditoria-2.0`** no servidor com a versão que já não traz a stack de logs
   (`docker-compose.yml` e `Makefile` novos) e rodar `make up-prod`. O alvo usa
   `--remove-orphans`, que remove os containers `loki`, `promtail` e `grafana` antigos e libera a
   3001. Os volumes antigos (`loki-storage`, `grafana-storage`) **não** são apagados.
3. **Subir esta stack:** `make up`.
4. **Service account e sync:** criar a service account `sync-auditoria-2-0` e o token; na máquina
   de dev, preencher `GRAFANA_PROD_URL`/`GRAFANA_PROD_TOKEN` no `.env` do `auditoria-2.0` e rodar
   `make grafana-sync-prod`.
5. **Validar:**
   - *Explore*: `{project="auditoria-2-0-prod"}` traz linhas de `app` e `nginx` recentes;
   - dashboard *Auditoria 2.0 - Requests* com **Projeto** = `auditoria-2-0-prod` mostra dados;
   - *Alerting → Alert rules*: as três regras da pasta *Auditoria 2.0* com health `ok`;
   - *Alerting → Contact points → email-alertas → Test*: o e-mail chega.
6. **Limpar**, só depois de validar: `docker volume rm loki-storage grafana-storage`. Até lá
   eles são o rollback: voltar o `auditoria-2.0` para a versão anterior e derrubar esta stack
   restaura o arranjo antigo com os dados dele.

A instância nova começa **sem histórico**: os logs dos últimos 7 dias ficam no volume antigo até
a limpeza, e não são importados.
