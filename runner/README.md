# Runner do Gitea Actions (nativo no WSL, host mode)

Origem: `auditoria-2.0/docs/qualidade-codigo-sonarqube.md` §B.6.

## Por que nativo, e não em container

Um `act_runner` em container **não** consegue orquestrar o `docker compose` dos projetos: o job
não tem o daemon (Docker-outside-of-Docker sem socket), e os bind mounts do compose não resolvem,
porque o `/workspace` do job é um volume, não um caminho do host (validado em 2026-07-08). Em
**host mode** os steps rodam direto no WSL, onde `docker compose` funciona como no terminal.

## Um runner por máquina, não por projeto

O registro usa o **token de instância** do Gitea, então o runner atende **qualquer repo**. Ele
mora em `~/gitea-runner/`, fora de qualquer projeto. Com `capacity: 1` os jobs rodam em série,
o que evita colisão de porta e de compose entre projetos.

Para várias máquinas: um runner em cada, com labels que digam o que ela oferece (ex.: `native`,
`docker-compose`).

## Setup (uma vez, na distro Ubuntu do WSL)

```bash
mkdir -p ~/gitea-runner && cd ~/gitea-runner
# 1) act_runner
curl -sSL -o act_runner https://dl.gitea.com/act_runner/0.2.11/act_runner-0.2.11-linux-amd64
chmod +x act_runner
# 2) node em userspace (o runner precisa; apt exige sudo)
curl -sSL -o node.tar.xz https://nodejs.org/dist/v20.18.0/node-v20.18.0-linux-x64.tar.xz
tar -xf node.tar.xz && mv node-v20.18.0-linux-x64 node && rm node.tar.xz
# 3) registrar em host mode
#    token: docker compose -f gitea/docker-compose.yml exec -u git gitea gitea actions generate-runner-token
./act_runner register --no-interactive --instance http://localhost:3001 \
  --token <RUNNER_TOKEN> --labels 'native:host' --name <nome-da-maquina>
# 4) daemon
export PATH="$PWD/node/bin:$PATH" && ./act_runner daemon
```

> Não cole o token em comandos que fiquem salvos em arquivo versionado (allowlists, scripts,
> histórico de chat exportado). É um token de registro de instância.

## Persistência (Windows)

Tarefa agendada **`GiteaActionsRunner`** (gatilho *AtLogOn*, até 3 reinícios com 1 min de
intervalo). Ação: `wsl.exe` com os argumentos

```
-d Ubuntu bash -lc 'cd ~/gitea-runner && export PATH="$PWD/node/bin:$PATH" && until ./act_runner daemon >>daemon.log 2>&1; do echo "$(date -Is) [supervisor] daemon saiu (instancia indisponivel ou crash); novo retry em 15s" >>daemon.log; sleep 15; done'
```

O laço `until` reinicia o daemon quando ele sai, por exemplo com o Gitea fora do ar. Por isso o
runner aguenta parada e migração do Gitea sem intervenção: volta sozinho quando a instância
responde. Log em `~/gitea-runner/daemon.log`. Usa Task Scheduler porque um serviço systemd de
sistema exige sudo.

```powershell
Start-ScheduledTask     -TaskName GiteaActionsRunner
Stop-ScheduledTask      -TaskName GiteaActionsRunner
Get-ScheduledTaskInfo   -TaskName GiteaActionsRunner
```

## Quando o Gitea mudar de endereço (etapa b)

O runner continua **nesta máquina**, porque precisa do Docker local. Muda só o endereço: editar
`address` em `~/gitea-runner/.runner` ou registrar de novo com `--instance http://<host>:3001`.
Antes, confirme que o host está no `NO_PROXY` do WSL (`git ls-remote http://<host>:3001/...`).

## Como os workflows usam o runner

- `runs-on: native`.
- **Checkout manual** com `git clone`, e não `actions/checkout`: a action seria baixada do
  github.com, bloqueado pelo proxy. Montar a URL a partir de `GITHUB_SERVER_URL` (o `ROOT_URL` da
  instância), sem host fixo:
  ```yaml
  - name: Checkout
    run: |
      srv="${GITHUB_SERVER_URL%/}"
      git clone --no-single-branch --depth 1 \
        "${srv%%://*}://ci:${{ github.token }}@${srv#*://}/${{ github.repository }}.git" .
      git checkout "${GITHUB_HEAD_REF:-$GITHUB_REF_NAME}"
  ```
- O runner não tem `make`: os steps chamam `docker compose` direto.
