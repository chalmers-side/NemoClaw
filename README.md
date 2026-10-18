# NemoClaw

這個 repo 是 NVIDIA [NemoClaw](https://github.com/NVIDIA/NemoClaw) 的**多使用者操作倉**，不是上游原始碼的 fork。用 GitHub Actions 把官方 NemoClaw 部署到 `chalmers` / `cliff` 各自的機器。

可提交的 per-user 設定在 `personal_config/<user>/config.env`。API key、bot token 寫在同目錄的 `personal_config/<user>/secrets.env`，**不進 git，也不放 GitHub Secrets**。

機器上的長期服務全部跑在 `compose/docker-compose.yml`：OpenShell gateway、Ollama、NemoClaw controller。Sandbox 仍由 gateway 用 Docker socket 另外建立，不是 compose service。

上游文件：

- [Headless 部署](https://docs.nvidia.com/nemoclaw/user-guide/openclaw/deployment/deploy-to-headless-server)
- [Credential storage](https://docs.nvidia.com/nemoclaw/user-guide/openclaw/security/credential-storage)
- [OpenShell Docker Compose](https://docs.nvidia.com/openshell/get-started/tutorials/docker-compose)

## 架構

```
GitHub Actions (選機器)
        │
        ▼
  Environment: chalmers | cliff | poc
        │
        ▼
  self-hosted runner
    poc: self-hosted, macOS, ARM64, chalmers-macmini-node-1
    others: nemoclaw,<user>
        │
        ├─ personal_config/<user>/config.env    ← git
        └─ personal_config/<user>/secrets.env   ← gitignore，只在該機器
                │
                ▼
        docker compose up
          ├─ init / gateway   OpenShell（官方 image + docker.sock）
          ├─ ollama           共用本機 LLM
          └─ nemoclaw         CLI / onboard / inference proxy
                │
                ▼
        sandbox 容器（gateway 建立的 sibling，不寫進 compose）
```

每次部署在 GitHub 選一台機器。Job 只跑在該使用者的 self-hosted runner 上，所以金鑰不必離開那台機器。

`poc` 用 `personal_config/poc/`，Actions 跑在 labels 為 `self-hosted`, `macOS`, `ARM64`, `chalmers-macmini-node-1` 的 runner 上。agent 在 `config.env` 切換。macOS 的共用 LLM 是本機 Ollama，不需要 cloud API key。

## macOS PoC（poc）

`poc` 的 deploy / status 跑在 `runs-on: [self-hosted, macOS, ARM64, chalmers-macmini-node-1]`。在那台機器的 checkout 裡，步驟與下面相同：

1. 打開 **Docker Desktop**，等到 `docker info` 成功
2. 編輯 [`personal_config/poc/config.env`](personal_config/poc/config.env)：
   - `NEMOCLAW_AGENT`：`hermes`（預設）、`openclaw`、或 `langchain-deepagents-code`
   - `NEMOCLAW_MODEL`：共用本機模型。Hermes 需要 native context ≥ 64000。16GB 預設是 `qwen3:4b`。`qwen3.5:9b` 在 64k、`q4_0` KV 時約 7.2 GiB，會和 Docker VM 搶統一記憶體。`qwen3:8b` 要先確認 context ≥ 64000 並量過 RSS，才換成預設。真 3B（`qwen2.5:3b`）請把 agent 改成 `openclaw`
3. 首次初始化與日常部署是分開的：

```bash
# First install only (refuses if poc-claw already exists)
bash ./scripts/deploy.sh poc ollama
bash ./scripts/deploy.sh poc nemoclaw
bash ./scripts/deploy.sh poc onboard

# Daily: host-file updates + health checks. Never onboard or --resume.
bash ./scripts/run-planned-deploy.sh poc
bash ./scripts/status.sh poc

# Sandbox Error / stopped: repair only. Never destroy or recreate.
bash ./scripts/recover-sandbox.sh poc
```

macOS 且 provider 是 Ollama 時：`ollama` 管本機 Ollama，`nemoclaw` 管 gateway / `nemohermes` / `:11435` auth proxy，`onboard` 只在 sandbox 不存在時建立一次。日常 `auto` / `run-planned-deploy.sh` 不跑 onboard、`--resume`、`--fresh`、`upgrade-sandboxes`。Ollama 或 gateway 沒在聽時 health check 失敗，改跑 **Deploy Ollama** / **Deploy NemoClaw host**。Linux 目標仍走 compose，但 `upgrade` / `serve` 也不再 `onboard --resume`。

服務分工：

- **gateway**：`ghcr.io/nvidia/openshell/gateway`，資料在 `/var/lib/openshell`（host 與容器同一路徑，NVIDIA 要求）
- **Ollama**：Linux 用 `NemoClaw-<user>-ollama`，host 只綁 `127.0.0.1:11434`。macOS 改跑本機 Ollama（Metal），compose 容器要停掉，否則搶同一個 port
- **NemoClaw controller**：Linux 用 `NemoClaw-<user>-cli`。macOS PoC 的 onboard 改由宿主機上的 `nemohermes` 執行，不啟動這個容器
- **auth proxy**：宿主機 LaunchAgent `com.nemoclaw.ollama-auth-proxy`，包既有的 `ollama-auth-proxy.mts`，聽 `:11435`。token 留在 `~/.nemoclaw/ollama-proxy-token`
- **Sandbox**：gateway 建立的 Docker 容器，不列在 compose 裡

這台 Mac 的 NemoClaw onboard **不會接受** Docker 發佈在 `:8080` 的 gateway（port owner 會被判成 `com.docker.backend`）。PoC 因此用 Homebrew `openshell-gateway` 聽 `127.0.0.1:8080`。Ollama 也跑在 Mac 本機（LaunchAgent `com.nemoclaw.ollama`），Docker Desktop 的 Linux VM 看不到 M4 GPU。模型仍在 `~/.ollama`，sandbox 還是打 `127.0.0.1:11435` 的 auth proxy。

Docker Desktop 會把 `host.openshell.internal` 同時寫成 IPv4 與 IPv6。OpenShell L7 proxy 走 IPv6 時會 `ssrf_denied`（IPv6 ULA 不在 `allowed_ips`）。`status.sh` / deploy 會把 sandbox `/etc/hosts` 裡的 IPv6 那行拿掉。若還要從 Mac 主機解析這個名字：

```bash
sudo ifconfig lo0 alias 10.255.255.254 netmask 255.255.255.255
printf '10.255.255.254\thost.openshell.internal\t# nemoclaw-host-openshell-internal\n' | sudo tee -a /etc/hosts
```

換 agent 只改 `NEMOCLAW_AGENT` 再 onboard；換模型改 `NEMOCLAW_MODEL` 後再 deploy。

已裝好之後，macOS 用宿主 CLI：

```bash
bash ./scripts/status.sh poc
nemohermes poc-claw status
```

Linux 的 controller 起來之後也可以 `docker compose -p nemoclaw-<user> ... exec nemoclaw`。

Hermes 官方要求 loaded context ≥ 64000。`qwen2.5:3b` 只有 32k，不能給 Hermes 用；16GB PoC 預設是 `qwen3:4b`。Ollama `KEEP_ALIVE` 是 `5m`。Docker Desktop 先量現有 VM，再以 4 CPU、6GB RAM、2GB swap、40GB disk 當起點；sandbox RSS 超過 6GB 就不要縮小。要用真 3B 時改：

```bash
# personal_config/poc/config.env
NEMOCLAW_AGENT=openclaw
NEMOCLAW_MODEL=qwen2.5:3b
```

## 什麼可以 commit

| 路徑 | 進 git？ | 內容 |
| --- | --- | --- |
| `personal_config/<user>/config.env` | 是 | OS、provider **名稱**、sandbox 名稱、policy |
| `personal_config/secrets.env.example` | 是 | 金鑰欄位範本（空值） |
| `personal_config/<user>/secrets.env` | **否** | 該使用者的 API key / bot token |
| `NEMOCLAW_VERSION` | 是 | 上游 NemoClaw commit SHA pin |
| `OPENSHELL_VERSION` | 是 | 上游 OpenShell release pin（image tag 去掉 `v`） |
| `compose/` | 是 | gateway + Ollama + NemoClaw controller |
| GitHub Environment secrets | **否** | 留空 |
| Runner registration token、`.runner` | **否** | 只在該機器使用一次 |

`config.env` 可寫的變數：

- `OS`：`linux` 或 `macos`（這台機器的 OS，給部署腳本檢查用）
- `NEMOCLAW_AGENT`：`hermes`、`openclaw`、或 `langchain-deepagents-code`
- `NEMOCLAW_PROVIDER`：本機 Compose Ollama 用 `ollama`；雲端用 `build`、`openai`、`anthropic`、`openrouter`、`gemini`
- `NEMOCLAW_MODEL`：本機 Ollama tag（例如 `qwen2.5:3b`）。同一台機器上的 sandbox 共用這顆 LLM
- `NEMOCLAW_YES=1`：非互動 onboard 時允許下載模型
- `NEMOCLAW_SANDBOX_NAME`：小寫、字母開頭，只含字母、數字、連字號
- `NEMOCLAW_POLICY_TIER`、`NEMOCLAW_WEB_SEARCH_PROVIDER`
- `DISCORD_SERVER_ID`：Discord Server ID（snowflake）。設了之後 onboard 會開 Discord，並要求 `secrets.env` 裡的 `DISCORD_BOT_TOKEN`
- 可選 `DISCORD_REQUIRE_MENTION`（預設在有 server id 時為 `1`）、`DISCORD_USER_ID`
- 可選 `NEMOCLAW_INSTALL_REF`：覆寫 `NEMOCLAW_VERSION` 的 SHA

Provider 與本機必填金鑰（寫在 `personal_config/<user>/secrets.env`，不要寫進 `config.env`）：

- `build` / `routed` → `NVIDIA_INFERENCE_API_KEY`
- `openai` → `OPENAI_API_KEY`
- `anthropic` → `ANTHROPIC_API_KEY`
- `openrouter` → `OPENROUTER_API_KEY`
- `gemini` → `GEMINI_API_KEY`
- Discord（`DISCORD_SERVER_ID` 有值時）→ `DISCORD_BOT_TOKEN`

## 新機器 / 新使用者 checklist

在目標機器上由該使用者自己做一次。

### 1. 前置

- Linux：Docker Engine + Compose 可用（`docker info` 對部署帳號成功），建議 4+ vCPU、8 GB RAM（16 GB 更好）、20 GB 以上磁碟。
- macOS：Docker Desktop。OpenShell 資料目錄是 `/var/lib/openshell`（compose 會 `create_host_path`）。

### 2. 本機金鑰

```bash
cp personal_config/secrets.env.example personal_config/<user>/secrets.env
chmod 600 personal_config/<user>/secrets.env
```

用編輯器填入該使用者 `config.env` 對應的 key。不要把填好的檔案 commit 回去。本機 Ollama 且沒開 Discord 可以不建這個檔。

Actions 會把 repo clone 到 `/opt/app/NemoClaw` 再部署，**不要**用 `actions-runner/_work` 當安裝目錄。`/opt/app` 要先在該機器建好：

```bash
sudo mkdir -p /opt/app
sudo chown "$(whoami)":staff /opt/app
```

金鑰寫在 `/opt/app/NemoClaw/personal_config/<user>/secrets.env`（mode 600）。第一次若沒有這個檔，job 會從 example 寫一份然後停下；填好再重跑。不要把金鑰放進 `_work`。

### 3. Self-hosted runner

在 GitHub repo：Settings → Actions → Runners → New self-hosted runner。依該機器 OS 安裝，labels 設為：

```text
nemoclaw,<username>
```

例如 chalmers 機器：`nemoclaw,chalmers`。`poc` 不用這組 label，它的 runner 要有 `self-hosted`、`macOS`、`ARM64`、`chalmers-macmini-node-1`。registration token 只在該機器用一次，不要進 git。

Runner 對這個 repo 有完整機器權限，只裝在可信的 chalmers / cliff 機器上。

### 4. GitHub Environment

Settings → Environments → 建立與使用者同名的 environment（`chalmers`、`cliff`）。可加 required reviewers。**Secrets 留空。**

### 5. 之後都從 Actions 部署

不必再把金鑰貼到 CI。

## 用 GitHub Actions 指定機器部署

1. 首次建立 sandbox：Actions → **First deploy** 或 **Deploy NemoClaw** stage **`sandbox`**（`onboard`）。Sandbox 或它的 Docker 容器已存在時會拒絕，不會 `--resume`。
2. 日常：Actions → **Redeploy**（push `main` / `feature*`）或 **Deploy NemoClaw** stage **`auto`**。只 sync `/opt/app`、必要時更新 host Ollama／gateway 腳本、修補 Hermes 設定，再分別檢查 Ollama、Gateway、Sandbox。不會 onboard、不會 `openshell sandbox create`。
3. Sandbox 異常：Actions → **Recover sandbox**。只 `start` / `recover` / 修 hosts。不刪、不重建。
4. Host 服務沒起來： **Deploy Ollama** / **Deploy NemoClaw host**。
5. `poc` 只會被 `chalmers-macmini-node-1` 那台 runner 接走。Branch 選 `feature/chalmers-poc`。不要選 `main` 跑 First deploy。job 先 clone 到 `/opt/app/NemoClaw`。

健康檢查：Actions → **Status NemoClaw**。分別報 Ollama / Gateway / Sandbox，**不會**把 dashboard URL 或 gateway token 印進 log。

同一台機器的 deploy / status / recover 不會並行（GitHub concurrency group `nemoclaw-<target>`，加上 `~/.nemoclaw/deploy-state/<target>/deploy.lock`）。

### 本機手動跑（除錯用）

在目標機器、repo checkout 裡：

```bash
bash ./scripts/status.sh poc
bash ./scripts/recover-sandbox.sh poc
```

長時間 onboard 若走 SSH 而不是 Actions，請在 `tmux` 裡跑，避免斷線中斷安裝：

```bash
tmux new-session -s nemoclaw-onboard
bash ./scripts/deploy.sh chalmers onboard
# Ctrl-b, d 離開；之後 tmux attach-session -t nemoclaw-onboard
```

## 旋轉金鑰

1. 在該機器改 `personal_config/<user>/secrets.env`
2. Sandbox 已存在時跑 **Recover sandbox** / `recover-sandbox.sh`，不要再 onboard。只有 sandbox 完全不存在才跑 **First deploy**。
3. 不要把舊 key 留在 shell history；部署腳本結束會 unset 已載入的變數

## 重開機後恢復

Compose 服務設了 `restart: unless-stopped`。Docker 起來之後：

```bash
sudo systemctl start docker   # Linux
docker info
bash ./scripts/status.sh <user>
```

若 Ollama 或 gateway 沒在跑，分別跑 `deploy.sh <user> ollama` / `nemoclaw`，不要 onboard。

若 sandbox 存在但不健康：

```bash
bash ./scripts/recover-sandbox.sh <user>
```

不要刪 sandbox、volume 或 credentials。OpenShell phase 停在 Error 時，依 `MEMORY.md` 的手動步驟，不要自動重建。

## Dashboard（不要對外開 port）

Gateway 與 dashboard 預設綁 `127.0.0.1`。從筆電 SSH tunnel，不要把 dashboard port 開到公網：

```bash
ssh -N -L 18789:127.0.0.1:18789 <user>@<host>
```

在**該機器的終端**取 URL（不要貼進 GitHub log 或聊天）：

```bash
docker compose -p nemoclaw-<user> -f compose/docker-compose.yml --project-directory compose exec nemoclaw \
  nemoclaw <sandbox-name> dashboard-url --quiet
```

NemoClaw 可能改用 `18789`–`18799` 的下一個空 port；以 `dashboard-url` 印出的為準。

## 故障

- 日常部署禁止 `onboard --resume`、`--fresh`、`--recreate-sandbox`。`nemohermes onboard` 會印 `Creating sandbox` 並呼叫 `openshell sandbox create`；sandbox 已存在時腳本會直接拒絕。
- `status` 失敗：先看是 Ollama、Gateway 還是 Sandbox 那一層。Sandbox Error 跑 Recover，不要 First deploy。
- 不要把 dashboard URL、gateway token、API key 貼進 issue、PR 或 Actions 註解。

官方 pin 在 [`NEMOCLAW_VERSION`](NEMOCLAW_VERSION) 與 [`OPENSHELL_VERSION`](OPENSHELL_VERSION)。更新時改這兩個檔案，不要用 `latest` / `lkg` 當長期伺服器來源。

## 新增一位使用者

1. 新增 `personal_config/<name>/config.env`
2. 在 GitHub 建同名 Environment
3. 在該機器裝 self-hosted runner，labels：`nemoclaw,<name>`
4. 在 `.github/workflows/first-deploy.yml`、`redeploy.yml` 與 `status.yml` 的 `target` choice 加上 `<name>`
5. 在該機器建立 `personal_config/<name>/secrets.env`（沒有 API key / bot token 可省略）
