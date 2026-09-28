# Runbook — SonarQube da plataforma

Origem: `auditoria-2.0/docs/qualidade-codigo-sonarqube.md` §B.5, generalizado para a plataforma.
Comandos a partir da raiz do `plataforma-dev`.

## Operação

```bash
make sonar-up      # sobe sonarqube + sonar-db (1ª vez: ~1-2 min até ficar UP)
make sonar-down    # derruba PRESERVANDO os volumes
curl -s localhost:9000/api/system/status   # deve trazer "status":"UP"
```

> ⚠️ **Nunca** rode `docker compose -f sonarqube/docker-compose.yml down -v` sem backup: o `-v`
> apaga o `sonar-db-data` e, com ele, histórico, Quality Gates, Quality Profiles e tokens de
> **todos** os projetos.

O healthcheck usa `curl` (a imagem não traz `wget`). Se o container aparecer `unhealthy` logo
depois de subir, confira direto na API.

## Pré-requisito de kernel: `vm.max_map_count=262144`

O Elasticsearch embutido não sobe sem isso. Precisa ser reaplicado em host novo ou depois de
recriar a distro do WSL. Sintoma: o `sonarqube` reinicia em loop com
`max virtual memory areas vm.max_map_count [65530] is too low`.

- **WSL2**: em `~/.wslconfig`
  ```ini
  [wsl2]
  kernelCommandLine = sysctl.vm.max_map_count=262144
  ```
  depois `wsl --shutdown`. Temporário até reiniciar:
  `wsl -d docker-desktop sysctl -w vm.max_map_count=262144`.
- **Linux**: `sudo sysctl -w vm.max_map_count=262144`, persistido em `/etc/sysctl.conf`.

RAM: reservar ≥ 2 GB livres para o Sonar.

## Backup e restore

O banco guarda o que **não está em git nenhum**: histórico, achados, Quality Gates, Quality
Profiles e tokens. Faça backup antes de qualquer upgrade de versão.

```bash
make backup-sonar                       # → backups/sonar-db-AAAA-MM-DD.sql.gz

# Restore: sonar-db no ar, sonarqube PARADO
docker compose -f sonarqube/docker-compose.yml --env-file .env stop sonarqube
gunzip -c backups/sonar-db-<data>.sql.gz | \
  docker exec -i plataforma-sonar-sonar-db-1 psql -U sonar -d sonar
make sonar-up
```

Os índices do Elasticsearch (`sonar-data`) se reconstroem sozinhos a partir do banco.

## Configuração por projeto (vive só no banco)

Cada projeto tem, no servidor, o seu projeto Sonar, Quality Gate e Quality Profiles. Se o banco
for recriado do zero, sem restore, é preciso refazer tudo à mão. No `auditoria-2.0`:

- Quality Gate **"Auditoria 2.0 - Clean as You Code"** associado ao projeto `auditoria-2-0`;
- Quality Profiles **`Auditoria 2.0`** para `php`, `ts` e `js`: `change_parent` para
  `Sonar way`, `deactivate_rule` da **S1135** e `add_project` em `auditoria-2-0`. Sem isso a S1135
  volta a marcar "todo" em PT-BR no editor de todo mundo, e o CI continua limpo (o
  `sonar-project.properties` a ignora), o que esconde o problema.

## Tokens

- Tipos: *Global Analysis Token* para scanners; *User Token* para administrar via API.
- Gerar e revogar: UI → avatar → **My Account → Security**. Anote a data de expiração.
- Um token de análise costuma estar em **dois lugares**: no `.env` do projeto (scanner local) e
  no segredo do repositório no Gitea (CI). Ao rotacionar, atualize os dois.
- Os tokens atuais do `auditoria-2.0` vencem em **02/11/2026**.

## Imagens na intranet

As imagens vêm do Docker Hub. Para uma máquina sem acesso, espelhe no registry interno
`10.6.130.22:5000` e troque os `image:` do compose.
