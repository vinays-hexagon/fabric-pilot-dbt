# Developer Setup Guide

dbt + Microsoft Fabric Warehouse local development and CI/CD setup.

---

## Architecture

```mermaid
flowchart TD
    subgraph Sources["Sources"]
        SF["❄️ Snowflake\nas_analytics.dbt_vsesham_mdo\n21 MDO tables"]
    end

    subgraph Ingest["Ingestion — ingest/ingest_snowflake.py"]
        PY["Python EL Script\nsnowflake-connector-python\npyodbc + Azure AD token"]
    end

    subgraph Fabric["Microsoft Fabric Warehouse — dbt-pilot-wh"]
        RAW["raw schema\nIngested source tables"]
        STG["dbt_vsesham_staging\nViews — stg_organizations\nstg_customers · stg_orders"]
        MART["dbt_vsesham_marts\nTables — dim_customers\nfct_orders"]
        ELEM["dbt_vsesham_elementary\nElementary monitoring tables"]
    end

    subgraph Transform["Transformation — dbt Core + dbt-fabric 1.10"]
        DBT["dbt build\nseed · run · test"]
    end

    subgraph Quality["Data Quality — Elementary 0.24"]
        EDR["edr report\nHTML observability report\nTest results · Anomaly detection"]
    end

    subgraph Governance["Data Governance — DataHub"]
        DH_DBT["dbt connector\n238 events\nLineage · descriptions · tests"]
        DH_FAB["mssql connector\n403 events\nPhysical schema catalog"]
        DH_UI["DataHub UI :9002\nLineage graph · catalog search"]
    end

    subgraph BI["Business Intelligence"]
        PBI["Power BI\nDirectQuery → Fabric Warehouse\nReal-time reports"]
    end

    subgraph CICD["CI/CD — GitHub Actions"]
        PR["Pull Request\ndbt compile + test\nschema: dbt_ci"]
        MAIN["Push to main\ndbt seed + run + test\nElementary report artifact\nschema: dbt_prod"]
        NIGHTLY["Nightly 02:00 UTC\nSnowflake ingest\n+ dbt run"]
    end

    SF -->|"snowflake-connector-python"| PY
    PY -->|"pyodbc + Azure AD"| RAW
    RAW -->|"dbt run"| STG
    STG -->|"dbt run"| MART
    DBT --> ELEM
    RAW & STG & MART --> DBT
    DBT -->|"on-run-end hook"| ELEM
    ELEM --> EDR
    MART -->|"DirectQuery"| PBI
    MART & STG --> DH_FAB
    DBT --> DH_DBT
    DH_DBT & DH_FAB --> DH_UI

    CICD -.->|"authenticates via\nService Principal"| Fabric
    CICD -.->|"triggers"| Transform
```

---

## CI/CD Workflow

Two GitHub Actions workflows handle automation:

```mermaid
flowchart TD
    subgraph Triggers["Triggers"]
        PR["Pull Request\nopened / updated\n→ main"]
        PUSH["Push / merge\n→ main"]
        MANUAL["Manual dispatch\nor nightly 02:00 UTC"]
    end

    subgraph Setup["Runner Setup — ubuntu-latest"]
        CHK["actions/checkout@v4"]
        ODBC["Install ODBC Driver 18\n(Ubuntu 24.04 noble repo)"]
        PY["setup-python 3.11\n+ pip cache"]
        DEPS["pip install -r requirements.txt\ndbt-fabric · snowflake-connector\nazure-identity · elementary-data"]
    end

    subgraph CI["ci.yml — dbt CI"]
        COMPILE["dbt compile\n--profiles-dir .\nValidates all SQL"]
        TEST_PR["dbt test\nschema: dbt_ci\nPR gate — must pass to merge"]
        SEED["dbt seed\nschema: dbt_prod"]
        RUN["dbt run\nschema: dbt_prod\nBuilds staging + marts"]
        TEST_MAIN["dbt test\nschema: dbt_prod\n21 tests"]
        EDR["edr report\nElementary HTML report"]
        ART["Upload artifact\nelementary_report.html\n30-day retention"]
    end

    subgraph INGEST["ingest.yml — Snowflake → Fabric Ingest"]
        ING["python ingest/ingest_snowflake.py\nSnowflake MDO → Fabric raw schema\n5 tables · 49 rows"]
        DBT_ING["dbt run\n--select tag:raw_dependent"]
    end

    subgraph Auth["GitHub Secrets"]
        SEC["DBT_FABRIC_SERVER\nDBT_FABRIC_DATABASE\nAZURE_TENANT_ID\nAZURE_CLIENT_ID\nAZURE_CLIENT_SECRET\nSNOWFLAKE_ACCOUNT\nSNOWFLAKE_USER\nSNOWFLAKE_PASSWORD"]
    end

    PR --> Setup
    PUSH --> Setup
    MANUAL --> Setup
    CHK --> ODBC --> PY --> DEPS

    DEPS --> COMPILE
    COMPILE --> TEST_PR

    DEPS --> COMPILE
    COMPILE -->|"push to main"| SEED
    SEED --> RUN --> TEST_MAIN --> EDR --> ART

    DEPS -->|"ingest trigger"| ING --> DBT_ING

    Auth -.->|"injected as env vars"| CI
    Auth -.->|"injected as env vars"| INGEST
```

---

## Git Branching Strategy

```mermaid
gitGraph
   commit id: "Initial commit: project scaffold"
   commit id: "feat: dbt-fabric connection + debug"

   branch feature/staging-models
   checkout feature/staging-models
   commit id: "feat: add stg_organizations, stg_customers"
   commit id: "feat: add stg_orders with order_total"
   commit id: "test: 21 data tests across staging layer"

   checkout main
   merge feature/staging-models id: "PR #1 merged ✓ CI green"
   commit id: "feat: dim_customers + fct_orders marts"

   branch feature/cicd-setup
   checkout feature/cicd-setup
   commit id: "feat: GitHub Actions ci.yml"
   commit id: "fix: Ubuntu 24.04 ODBC install"
   commit id: "fix: commit profiles.yml for CI"

   checkout main
   merge feature/cicd-setup id: "PR #2 merged ✓ CI green"

   branch feature/snowflake-ingest
   checkout feature/snowflake-ingest
   commit id: "feat: ingest_snowflake.py EL script"
   commit id: "fix: VARCHAR not NVARCHAR in Fabric"
   commit id: "feat: ingest.yml nightly workflow"

   checkout main
   merge feature/snowflake-ingest id: "PR #3 merged ✓ CI green"
   commit id: "feat: Elementary data quality + edr report"
   commit id: "feat: DataHub dbt + mssql connectors"
   commit id: "feat: run_pipeline.sh end-to-end script"

   branch feature/new-model
   checkout feature/new-model
   commit id: "feat: add new dbt model"
   commit id: "test: add schema tests"

   checkout main
   merge feature/new-model id: "PR #N merged → deploys to dbt_prod"
```

> **Branch rules:**
> - `main` is protected — direct pushes blocked, PR required
> - PR triggers `dbt compile + test` against `dbt_ci` schema — must pass to merge
> - Merge to `main` triggers full deploy to `dbt_prod` + Elementary report artifact
> - `profiles.yml` is committed (env_var refs only, no secrets) — never add it back to `.gitignore`

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| macOS | ARM64 (Apple Silicon) | — |
| Homebrew | latest | `https://brew.sh` |
| Python | 3.11 | `brew install python@3.11` |
| Azure CLI | 2.86+ | `brew install azure-cli` |
| Git | any | pre-installed on macOS |
| GitHub CLI | latest | `brew install gh` |
| ODBC Driver 17 for SQL Server | 17 | see below |

### Install ODBC Driver 17 (macOS)

```bash
brew tap microsoft/mssql-release https://github.com/Microsoft/homebrew-mssql-release
brew install msodbcsql17
```

Verify:
```bash
odbcinst -q -d  # should show [ODBC Driver 17 for SQL Server]
```

---

## 1. Azure Login

Log in to the Hexagon Azure tenant:

```bash
az login
```

Verify you are on the correct tenant:
```bash
az account show --output table
# Expected: Hexagon AP-Prod / Hexmet.onmicrosoft.com
```

---

## 2. SSH Key for GitHub

Generate an Ed25519 key (skip if you already have one at `~/.ssh/id_ed25519.pub`):

```bash
ssh-keygen -t ed25519 -C "your.name@hexagon.com" -f ~/.ssh/id_ed25519 -N ""
ssh-keyscan github.com >> ~/.ssh/known_hosts
```

Log into GitHub CLI and upload the key in one step:

```bash
gh auth login
# Choose: GitHub.com → SSH → Upload your SSH key → ~/.ssh/id_ed25519.pub → Login with web browser
```

Verify:
```bash
ssh -T git@github.com   # "Hi <username>! You've successfully authenticated..."
```

---

## 3. Clone the Repository

```bash
git clone git@github.com:vinays-hexagon/fabric-pilot-dbt.git
cd fabric-pilot-dbt
```

---

## 4. Python Virtual Environment

Create a dedicated venv for dbt-fabric (keep it separate from other dbt projects):

```bash
python3.11 -m venv ~/.dbt/fabric-venv
~/.dbt/fabric-venv/bin/pip install -r requirements.txt
```

Add a shell alias for convenience (add to `~/.zshrc`):

```bash
echo 'alias dbt-fabric="~/.dbt/fabric-venv/bin/dbt"' >> ~/.zshrc
source ~/.zshrc
```

Verify:
```bash
dbt-fabric --version
# Core: 1.11.x  |  Plugins: fabric: 1.10.x
```

---

## 5. Local dbt Profile

The `profiles.yml` committed to the repo is for **CI only** (uses env vars). For local development you need a separate profile in `~/.dbt/profiles.yml` that uses Azure CLI auth.

Add the following block to `~/.dbt/profiles.yml` (create the file if it doesn't exist):

```yaml
fabric_pilot:
  target: dev
  outputs:
    dev:
      type: fabric
      driver: 'ODBC Driver 17 for SQL Server'
      server: h2vrmg7wxdru7hz6fw374ve7ni-ptfanl5jjmiu5cy7hishzreaae.datawarehouse.fabric.microsoft.com
      port: 1433
      database: "dbt-pilot-wh"
      schema: dbt_<your_username>      # e.g. dbt_jsmith — keeps your dev schema isolated
      authentication: CLI
      threads: 4
```

> **Important:** `~/.dbt/profiles.yml` is in `.gitignore` — never commit it. It may contain credentials for other projects.

Test the connection:

```bash
cd fabric-pilot-dbt
dbt-fabric debug
# Expected: All checks passed!
```

---

## 6. Run dbt Locally

```bash
# Load seed data
dbt-fabric seed

# Build all models
dbt-fabric run

# Run all tests
dbt-fabric test

# Or do all three in one command
dbt-fabric build
```

Your models land in the following schemas in `dbt-pilot-wh`:

| Layer | Schema | Materialization |
|-------|--------|----------------|
| Seeds (raw) | `dbt_<username>` | Table |
| Staging | `dbt_<username>_staging` | View |
| Marts | `dbt_<username>_marts` | Table |

---

## 7. CI/CD — GitHub Actions

CI runs automatically on every PR and push to `main`. No action needed from developers beyond pushing code.

### How it works

| Event | Steps | Target schema |
|-------|-------|---------------|
| Pull Request | `dbt compile` + `dbt test` | `dbt_ci` |
| Push to `main` | `dbt seed` + `dbt run` + `dbt test` | `dbt_prod` |

### Required GitHub Secrets

These are already configured on the repo. If you are setting up a **new** repo fork, add these secrets under **Settings → Secrets → Actions**:

| Secret | Description |
|--------|-------------|
| `DBT_FABRIC_SERVER` | Fabric Warehouse SQL endpoint hostname |
| `DBT_FABRIC_DATABASE` | Warehouse name (e.g. `dbt-pilot-wh`) |
| `AZURE_TENANT_ID` | Azure AD tenant ID |
| `AZURE_CLIENT_ID` | Service Principal app ID |
| `AZURE_CLIENT_SECRET` | Service Principal client secret |

### Service Principal setup (new repo only)

1. Create the SP:
   ```bash
   az ad sp create-for-rbac --name "dbt-fabric-pilot-sp" --skip-assignment --output json
   ```
2. In the Fabric workspace UI: **Manage access → Add people or groups** → search for `dbt-fabric-pilot-sp` → set role to **Contributor**

---

## 8. Making Changes

### Feature branch workflow

```bash
git checkout -b feature/your-feature-name
# ... make changes ...
git add .
git commit -m "feat: describe your change"
git push origin feature/your-feature-name
```

Open a PR on GitHub. CI will run `dbt compile + test` automatically. Merge to `main` triggers the full deploy.

### T-SQL gotchas (Fabric Warehouse is T-SQL, not ANSI SQL)

| Instead of | Use |
|---|---|
| `true` / `false` | `CAST(1 AS BIT)` / `CAST(0 AS BIT)` |
| `date_trunc('month', col)` | `DATETRUNC(month, col)` |
| `current_date` | `CAST(GETDATE() AS DATE)` |
| `||` string concat | `+` or `CONCAT(a, b)` |

---

## 9. Project Structure

```
fabric-pilot-dbt/
├── models/
│   ├── staging/          # Views — clean and rename raw columns
│   │   ├── stg_organizations.sql
│   │   ├── stg_customers.sql
│   │   ├── stg_orders.sql
│   │   └── schema.yml
│   └── marts/            # Tables — business-ready dimensions and facts
│       ├── dim_customers.sql
│       ├── fct_orders.sql
│       └── schema.yml
├── seeds/                # Static CSV reference data (loaded via dbt seed)
├── tests/                # Custom singular tests
├── macros/               # Reusable Jinja macros
├── .github/workflows/
│   └── ci.yml            # GitHub Actions CI/CD pipeline
├── profiles.yml          # CI profile (env_var refs only — safe to commit)
├── dbt_project.yml       # dbt project config
├── requirements.txt      # Pinned Python dependencies
└── DEVELOPER_SETUP.md    # This file
```

---

## Troubleshooting

**`dbt debug` fails with `Login timeout expired`**
- Ensure you are logged in: `az login`
- Ensure your account has access to the Fabric workspace

**`dbt debug` fails with `Could not find profile named 'fabric_pilot'`**
- Check `~/.dbt/profiles.yml` exists and has the `fabric_pilot` key
- You may be running `dbt` from the wrong venv — use `dbt-fabric` alias

**`Invalid column name 'true'` in a model**
- Replace `true`/`false` literals with `CAST(1 AS BIT)`/`CAST(0 AS BIT)`

**CI fails with `Could not find profile named 'fabric_pilot'`**
- `profiles.yml` must be committed to the repo — do not add it back to `.gitignore`

**CI fails with `gpg: cannot open '/dev/tty'`**
- Ensure the ODBC install step uses `gpg --batch --dearmor` and pipes via `sudo tee`
- Ensure the apt repo URL is for Ubuntu 24.04 (`noble`), not 22.04 (`jammy`)

---

## 10. Running the Full Pipeline Locally

`run_pipeline.sh` runs all three stages end-to-end:

```bash
# Set required env vars first
export SNOWFLAKE_ACCOUNT=ZFSYMIS-RX17347
export SNOWFLAKE_USER=elt_user
export SNOWFLAKE_PASSWORD=<password>
export DBT_FABRIC_SERVER=<warehouse-sql-endpoint>
export DBT_FABRIC_DATABASE=dbt-pilot-wh

./run_pipeline.sh
```

Flags to skip individual stages:
```bash
./run_pipeline.sh --skip-ingest       # skip Snowflake ingestion
./run_pipeline.sh --skip-dbt          # skip dbt build
./run_pipeline.sh --skip-elementary   # skip Elementary report
```

---

## 11. Data Quality — Elementary

Elementary captures dbt test results in `dbt-pilot-wh.dbt_vsesham_elementary`.

Generate a local report any time:
```bash
edr report --profiles-dir ~/.dbt --profile-target dev
# Opens edr_target/elementary_report.html in your browser
```

---

## 12. Power BI — Connecting to Fabric Warehouse

> **Note:** DirectLake mode requires a Fabric Lakehouse. For Fabric Warehouse use DirectQuery (real-time, zero-copy via SQL endpoint).

Fabric automatically creates a **default semantic model** for every Warehouse — no Power BI Desktop needed.

1. Open your Fabric workspace → click `dbt-pilot-wh`
2. In the toolbar click **New report**
3. Power BI opens in DirectQuery mode connected to the Warehouse
4. In the **Data** pane, expand `dbt_vsesham_marts` → `dim_customers` and `fct_orders`
5. Build your report and click **Save**

**Gotcha:** `NVARCHAR` is not supported in Fabric Warehouse (trial). All string columns are `VARCHAR(4000)`. This does not affect Power BI — it reads column types correctly.
