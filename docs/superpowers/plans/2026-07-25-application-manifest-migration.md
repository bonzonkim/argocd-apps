# Application Manifest Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace all 23 `config.json` inputs with complete `application.yaml` Argo CD CRDs while preserving the `applications` root Application → `appset-helm`/`appset-raw` → child Application hierarchy.

**Architecture:** Keep both existing ApplicationSets and their resource names. Their Git files generators will parse `*/*/application.yaml`, select files by `metadata.labels.source-type`, use `metadata.name` and `spec.project` in the base template, and pass the rest of each CRD through a JSON-serialized `templatePatch`.

**Tech Stack:** Argo CD Application and ApplicationSet CRDs, Go templates with Sprig functions, Helm, Bash, `yq` v4, `rg`, Kubernetes server-side dry-run.

## Global Constraints

- Preserve the resource names `applications`, `appset-helm`, and `appset-raw`.
- Preserve all 23 existing child Application names.
- Preserve the hierarchy shown in Argo CD: root Application → two ApplicationSets → child Applications.
- Store each child CRD at `<namespace>/<app>/application.yaml`.
- Every child manifest must have `apiVersion: argoproj.io/v1alpha1`, `kind: Application`, and `metadata.namespace: argocd`.
- Use `metadata.labels.source-type: helm` for 18 Helm Applications and `metadata.labels.source-type: raw` for 5 raw Applications.
- Keep `spec.project: default` and `spec.destination.server: https://kubernetes.default.svc`.
- Keep ApplicationSet `preserveResourcesOnDeletion: true`.
- Keep child automated sync with `prune: false` and `selfHeal: true`.
- Do not add `resources-finalizer.argocd.argoproj.io` to child Applications.
- Apply the previously ignored cert-manager `valuesObject` and Prometheus sync options.
- Use the published Istio chart names `cni`, `ztunnel`, and `istiod`.
- Do not modify `bootstrap/root-app.yaml`.
- Intermediate feature-branch commits may contain both file formats, but the complete branch must be merged to `main` atomically; never apply or merge a partial task commit.
- Follow `/Users/b9/.codex/RTK.md`: prefix interactive shell commands with `rtk`.

---

## File Map

### Infrastructure

- Modify `apps/appset-helm.yaml`: read Helm Application CRDs and pass their metadata/spec through.
- Modify `apps/appset-raw.yaml`: read raw Application CRDs and pass their metadata/spec through.
- Create `scripts/validate-application-manifests.sh`: enforce inventory, schema shape, values paths, raw paths, and removal of `config.json`.

### Raw Applications

- Create `fantasy-realm/fantasy-realm/application.yaml`.
- Create `grammair/server/application.yaml`.
- Create `grammair/web/application.yaml`.
- Create `running-mate/api/application.yaml`.
- Create `running-mate/postgresql/application.yaml`.

### Helm Applications

- Create `argocd/argo-cd/application.yaml`.
- Create `argocd/argocd-image-updater/application.yaml`.
- Create `cert-manager/cert-manager/application.yaml`.
- Create `infisical-operator-system/infisical-secrets-operator/application.yaml`.
- Create `istio-system/istio-cni/application.yaml`.
- Create `istio-system/istiod/application.yaml`.
- Create `istio-system/ztunnel/application.yaml`.
- Create `monitoring/grafana/application.yaml`.
- Create `monitoring/vector/application.yaml`.
- Create `node-local-dns/node-local-dns/application.yaml`.
- Create `operators/barman-cloud/application.yaml`.
- Create `operators/cloudnative-pg/application.yaml`.
- Create `postgresql/postgresql/application.yaml`.
- Create `prometheus/kube-prometheus-stack/application.yaml`.
- Create `redis/redis/application.yaml`.
- Create `reflector/reflector/application.yaml`.
- Create `victoria/loki-vl-proxy/application.yaml`.
- Create `victoria/victoria-logs/application.yaml`.

### Removal

- Delete the 23 `config.json` files only after every replacement CRD and both ApplicationSet changes exist on the feature branch.

---

### Task 1: Add the migration validator

**Files:**
- Create: `scripts/validate-application-manifests.sh`
- Test: `scripts/validate-application-manifests.sh`

**Interfaces:**
- Consumes: final repository layout and `yq` v4.
- Produces: a zero-exit validation command used by every later task and final verification.

- [ ] **Step 1: Write the final-state validator before creating Application manifests**

Create `scripts/validate-application-manifests.sh` with this exact content:

```bash
#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_root"

command -v yq >/dev/null || {
  echo "yq v4 is required" >&2
  exit 1
}

expected_names="$(
  printf '%s\n' \
    argo-cd \
    argocd-image-updater \
    barman-cloud-plugin \
    cert-manager \
    cloudnative-pg \
    fantasy-realm \
    grafana \
    grammair-server \
    grammair-web \
    infisical-secrets-operator \
    istio-cni \
    istiod \
    loki-vl-proxy \
    node-local-dns \
    prometheus-kube-prometheus-stack \
    redis \
    reflector \
    running-mate-api \
    running-mate-postgresql \
    running-mate-postgresql-cnpg \
    vector \
    victoria-logs \
    ztunnel |
    sort
)"

application_files="$(find . -mindepth 3 -maxdepth 3 -type f -name application.yaml | sort)"
application_count="$(printf '%s\n' "$application_files" | sed '/^$/d' | wc -l | tr -d ' ')"

if [[ "$application_count" != "23" ]]; then
  echo "expected 23 application.yaml files, found $application_count" >&2
  exit 1
fi

actual_names=""
helm_count=0
raw_count=0

while IFS= read -r file; do
  [[ -n "$file" ]] || continue

  yq -e '
    .apiVersion == "argoproj.io/v1alpha1" and
    .kind == "Application" and
    .metadata.namespace == "argocd" and
    .metadata.name != "" and
    .spec.project == "default" and
    .spec.destination.server == "https://kubernetes.default.svc" and
    .spec.destination.namespace != "" and
    .spec.syncPolicy.automated.prune == false and
    .spec.syncPolicy.automated.selfHeal == true
  ' "$file" >/dev/null

  if yq -e '.metadata.finalizers[]? == "resources-finalizer.argocd.argoproj.io"' "$file" >/dev/null; then
    echo "$file must not use the resources finalizer" >&2
    exit 1
  fi

  name="$(yq -r '.metadata.name' "$file")"
  source_type="$(yq -r '.metadata.labels."source-type"' "$file")"
  actual_names="${actual_names}${name}"$'\n'

  case "$source_type" in
    helm)
      helm_count=$((helm_count + 1))
      ;;
    raw)
      raw_count=$((raw_count + 1))
      source_path="$(yq -r '.spec.source.path // ""' "$file")"
      if [[ -z "$source_path" || ! -d "$source_path" ]]; then
        echo "$file references missing raw source path: $source_path" >&2
        exit 1
      fi
      ;;
    *)
      echo "$file has invalid source-type: $source_type" >&2
      exit 1
      ;;
  esac

  while IFS= read -r value_file; do
    [[ -n "$value_file" ]] || continue
    if [[ "$value_file" != '$values/'* ]]; then
      echo "$file has unsupported value file reference: $value_file" >&2
      exit 1
    fi
    values_path="${value_file#\$values/}"
    if [[ ! -f "$values_path" ]]; then
      echo "$file references missing values file: $values_path" >&2
      exit 1
    fi
  done < <(
    yq -r '
      [
        .spec.source.helm.valueFiles[]?,
        .spec.sources[]?.helm.valueFiles[]?
      ] | .[]
    ' "$file"
  )
done <<< "$application_files"

if [[ "$helm_count" != "18" || "$raw_count" != "5" ]]; then
  echo "expected 18 helm and 5 raw Applications; found $helm_count helm and $raw_count raw" >&2
  exit 1
fi

if ! diff -u \
  <(printf '%s\n' "$expected_names") \
  <(printf '%s' "$actual_names" | sort); then
  echo "Application name inventory differs" >&2
  exit 1
fi

if find . -mindepth 3 -maxdepth 3 -type f -name config.json | grep -q .; then
  echo "config.json files remain" >&2
  exit 1
fi

if rg -q 'config\.json' apps/appset-helm.yaml apps/appset-raw.yaml; then
  echo "ApplicationSets still reference config.json" >&2
  exit 1
fi

yq -e '
  .metadata.name == "appset-helm" and
  .spec.syncPolicy.preserveResourcesOnDeletion == true and
  .spec.generators[0].git.files[0].path == "*/*/application.yaml" and
  .spec.generators[0].selector.matchLabels."metadata.labels.source-type" == "helm"
' apps/appset-helm.yaml >/dev/null

yq -e '
  .metadata.name == "appset-raw" and
  .spec.syncPolicy.preserveResourcesOnDeletion == true and
  .spec.generators[0].git.files[0].path == "*/*/application.yaml" and
  .spec.generators[0].selector.matchLabels."metadata.labels.source-type" == "raw"
' apps/appset-raw.yaml >/dev/null

echo "validated 23 Application manifests: 18 helm, 5 raw"
```

- [ ] **Step 2: Make the validator executable**

Run:

```bash
rtk proxy chmod +x scripts/validate-application-manifests.sh
```

- [ ] **Step 3: Run it and verify the current repository fails for the intended reason**

Run:

```bash
rtk proxy ./scripts/validate-application-manifests.sh
```

Expected: FAIL with `expected 23 application.yaml files, found 0`.

- [ ] **Step 4: Commit the executable validator**

```bash
rtk git add scripts/validate-application-manifests.sh
rtk git commit -m "test: validate Argo CD Application manifests"
```

---

### Task 2: Convert all raw Applications

**Files:**
- Create: `fantasy-realm/fantasy-realm/application.yaml`
- Create: `grammair/server/application.yaml`
- Create: `grammair/web/application.yaml`
- Create: `running-mate/api/application.yaml`
- Create: `running-mate/postgresql/application.yaml`
- Test: all five files with `yq` and `kubectl --dry-run=client`

**Interfaces:**
- Consumes: repository paths and annotations from the five corresponding `config.json` files.
- Produces: five complete CRDs selected by `appset-raw`.

- [ ] **Step 1: Create the fantasy-realm Application**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: fantasy-realm
  namespace: argocd
  labels:
    source-type: raw
  annotations:
    argocd-image-updater.argoproj.io/image-list: fantasy-realm=ghcr.io/bonzonkim/fantasy-realm/fantasy-realm
    argocd-image-updater.argoproj.io/fantasy-realm.update-strategy: semver
    argocd-image-updater.argoproj.io/git-branch: main
    argocd-image-updater.argoproj.io/write-back-method: git
    argocd-image-updater.argoproj.io/fantasy-realm.pull-secret: pullsecret:argocd/fantasy-realm-packages
    argocd-image-updater.argoproj.io/fantasy-realm.allow-tags: 'regexp:^1\.0\.[0-9]+$'
spec:
  project: default
  source:
    repoURL: https://github.com/bonzonkim/argocd-apps
    targetRevision: main
    path: fantasy-realm/fantasy-realm
  destination:
    server: https://kubernetes.default.svc
    namespace: fantasy-realm
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 2: Create the grammair-server Application**

Use the same complete CRD shape with these exact values:

```yaml
metadata:
  name: grammair-server
  namespace: argocd
  labels:
    source-type: raw
  annotations:
    argocd-image-updater.argoproj.io/image-list: grammair-server=ghcr.io/bonzonkim/grammair-server/grammair-server
    argocd-image-updater.argoproj.io/grammair-server.update-strategy: semver
    argocd-image-updater.argoproj.io/git-branch: master
    argocd-image-updater.argoproj.io/grammair-server.pull-secret: pullsecret:argocd/grammair-packages
    argocd-image-updater.argoproj.io/grammair-server.allow-tags: 'regexp:^1\.0\.[0-9]+$'
spec:
  project: default
  source:
    repoURL: https://github.com/bonzonkim/argocd-apps
    targetRevision: main
    path: grammair/server
  destination:
    server: https://kubernetes.default.svc
    namespace: grammair
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Prepend `apiVersion: argoproj.io/v1alpha1` and `kind: Application` to the shown metadata/spec.

- [ ] **Step 3: Create the grammair-web Application**

Use `apiVersion: argoproj.io/v1alpha1`, `kind: Application`, and these exact metadata/spec values:

```yaml
metadata:
  name: grammair-web
  namespace: argocd
  labels:
    source-type: raw
  annotations:
    argocd-image-updater.argoproj.io/image-list: grammair-web=ghcr.io/bonzonkim/grammair-web/grammair-web
    argocd-image-updater.argoproj.io/grammair-web.update-strategy: semver
    argocd-image-updater.argoproj.io/git-branch: master
    argocd-image-updater.argoproj.io/grammair-web.pull-secret: pullsecret:argocd/grammair-packages
    argocd-image-updater.argoproj.io/grammair-web.allow-tags: 'regexp:^1\.0\.[0-9]+$'
spec:
  project: default
  source:
    repoURL: https://github.com/bonzonkim/argocd-apps
    targetRevision: main
    path: grammair/web
  destination:
    server: https://kubernetes.default.svc
    namespace: grammair
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 4: Create the running-mate-api Application**

Use `apiVersion: argoproj.io/v1alpha1`, `kind: Application`, and:

```yaml
metadata:
  name: running-mate-api
  namespace: argocd
  labels:
    source-type: raw
  annotations:
    argocd-image-updater.argoproj.io/image-list: running-mate-api=ghcr.io/bonzonkim/running-mate-api
    argocd-image-updater.argoproj.io/running-mate-api.update-strategy: semver
    argocd-image-updater.argoproj.io/git-branch: main
    argocd-image-updater.argoproj.io/write-back-method: git
    argocd-image-updater.argoproj.io/running-mate-api.pull-secret: pullsecret:argocd/running-mate-packages
    argocd-image-updater.argoproj.io/running-mate-api.allow-tags: 'regexp:^0\.2\.[0-9]+$'
spec:
  project: default
  source:
    repoURL: https://github.com/bonzonkim/argocd-apps
    targetRevision: main
    path: running-mate/api
  destination:
    server: https://kubernetes.default.svc
    namespace: running-mate
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 5: Create the running-mate PostgreSQL CNPG Application**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: running-mate-postgresql-cnpg
  namespace: argocd
  labels:
    source-type: raw
spec:
  project: default
  source:
    repoURL: https://github.com/bonzonkim/argocd-apps
    targetRevision: main
    path: running-mate/postgresql
  destination:
    server: https://kubernetes.default.svc
    namespace: running-mate
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 6: Validate the five raw CRDs**

Run:

```bash
rtk proxy yq -e '.kind == "Application" and .metadata.labels."source-type" == "raw"' \
  fantasy-realm/fantasy-realm/application.yaml \
  grammair/server/application.yaml \
  grammair/web/application.yaml \
  running-mate/api/application.yaml \
  running-mate/postgresql/application.yaml
```

Expected: `true` for all five documents.

Run:

```bash
for manifest in \
  fantasy-realm/fantasy-realm/application.yaml \
  grammair/server/application.yaml \
  grammair/web/application.yaml \
  running-mate/api/application.yaml \
  running-mate/postgresql/application.yaml; do
  rtk kubectl apply --dry-run=client -f "$manifest"
done
```

Expected: each Application reports `created (dry run)`.

- [ ] **Step 7: Commit the raw CRDs**

```bash
rtk git add \
  fantasy-realm/fantasy-realm/application.yaml \
  grammair/server/application.yaml \
  grammair/web/application.yaml \
  running-mate/api/application.yaml \
  running-mate/postgresql/application.yaml
rtk git commit -m "refactor: define raw apps as Application CRDs"
```

---

### Task 3: Convert Helm Applications without repository values files

**Files:**
- Create: `cert-manager/cert-manager/application.yaml`
- Create: `infisical-operator-system/infisical-secrets-operator/application.yaml`
- Create: `istio-system/istiod/application.yaml`
- Create: `istio-system/ztunnel/application.yaml`
- Create: `redis/redis/application.yaml`
- Create: `reflector/reflector/application.yaml`
- Test: the six created manifests and their Helm chart resolutions

**Interfaces:**
- Consumes: external Helm repositories and inline/special settings from existing configs.
- Produces: six single-source Helm Application CRDs selected by `appset-helm`.

- [ ] **Step 1: Create the reflector CRD as the concrete single-source reference**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: reflector
  namespace: argocd
  labels:
    source-type: helm
spec:
  project: default
  source:
    repoURL: https://emberstack.github.io/helm-charts
    chart: reflector
    targetRevision: 7.1.262
    helm:
      releaseName: reflector
  destination:
    server: https://kubernetes.default.svc
    namespace: reflector
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 2: Create the remaining five single-source Helm CRDs**

Each file uses the complete field structure shown in Step 1 and the exact
identity and source fields below:

| File | `metadata.name` | `repoURL` | `chart` | `targetRevision` | `releaseName` | destination namespace |
|---|---|---|---|---|---|---|
| `cert-manager/cert-manager/application.yaml` | `cert-manager` | `https://charts.jetstack.io` | `cert-manager` | `1.19.2` | `cert-manager` | `cert-manager` |
| `infisical-operator-system/infisical-secrets-operator/application.yaml` | `infisical-secrets-operator` | `https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts` | `secrets-operator` | `0.6.2` | `infisical-secrets-operator` | `infisical-operator-system` |
| `istio-system/istiod/application.yaml` | `istiod` | `https://istio-release.storage.googleapis.com/charts` | `istiod` | `1.30.3` | `istiod` | `istio-system` |
| `istio-system/ztunnel/application.yaml` | `ztunnel` | `https://istio-release.storage.googleapis.com/charts` | `ztunnel` | `1.30.3` | `ztunnel` | `istio-system` |
| `redis/redis/application.yaml` | `redis` | `registry-1.docker.io/bitnamicharts` | `redis` | `23.2.1` | `redis` | `redis` |

- [ ] **Step 3: Activate cert-manager CRD installation**

In `cert-manager/cert-manager/application.yaml`, make the Helm block exactly:

```yaml
helm:
  releaseName: cert-manager
  valuesObject:
    installCRDs: true
```

- [ ] **Step 4: Preserve Redis generated-secret differences**

Add this top-level spec field to `redis/redis/application.yaml`:

```yaml
ignoreDifferences:
  - group: ""
    kind: Secret
    name: redis
    jsonPointers:
      - /data/redis-password
```

- [ ] **Step 5: Validate all six CRDs locally**

Run:

```bash
rtk proxy yq -e '
  .kind == "Application" and
  .metadata.labels."source-type" == "helm" and
  .spec.source.chart != "" and
  .spec.sources == null
' \
  cert-manager/cert-manager/application.yaml \
  infisical-operator-system/infisical-secrets-operator/application.yaml \
  istio-system/istiod/application.yaml \
  istio-system/ztunnel/application.yaml \
  redis/redis/application.yaml \
  reflector/reflector/application.yaml
```

Expected: `true` for all six files.

- [ ] **Step 6: Resolve each pinned chart**

Run:

```bash
rtk proxy helm show chart cert-manager --repo https://charts.jetstack.io --version 1.19.2
rtk proxy helm show chart secrets-operator --repo https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts --version 0.6.2
rtk proxy helm show chart istiod --repo https://istio-release.storage.googleapis.com/charts --version 1.30.3
rtk proxy helm show chart ztunnel --repo https://istio-release.storage.googleapis.com/charts --version 1.30.3
rtk proxy helm show chart oci://registry-1.docker.io/bitnamicharts/redis --version 23.2.1
rtk proxy helm show chart reflector --repo https://emberstack.github.io/helm-charts --version 7.1.262
```

Expected: every command exits zero and reports the requested chart version.

- [ ] **Step 7: Commit the six CRDs**

```bash
rtk git add \
  cert-manager/cert-manager/application.yaml \
  infisical-operator-system/infisical-secrets-operator/application.yaml \
  istio-system/istiod/application.yaml \
  istio-system/ztunnel/application.yaml \
  redis/redis/application.yaml \
  reflector/reflector/application.yaml
rtk git commit -m "refactor: define standalone Helm Application CRDs"
```

---

### Task 4: Convert core Helm Applications with values files

**Files:**
- Create: `argocd/argo-cd/application.yaml`
- Create: `argocd/argocd-image-updater/application.yaml`
- Create: `node-local-dns/node-local-dns/application.yaml`
- Create: `operators/barman-cloud/application.yaml`
- Create: `operators/cloudnative-pg/application.yaml`
- Create: `postgresql/postgresql/application.yaml`
- Test: six Application CRDs, six local values references, and six chart resolutions

**Interfaces:**
- Consumes: existing `values.yaml` files and chart metadata.
- Produces: six multi-source Helm Applications.

- [ ] **Step 1: Use this exact multi-source structure**

The `argocd/argo-cd/application.yaml` file is the concrete reference:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argo-cd
  namespace: argocd
  labels:
    source-type: helm
spec:
  project: default
  sources:
    - repoURL: https://argoproj.github.io/argo-helm
      chart: argo-cd
      targetRevision: 9.3.7
      helm:
        releaseName: argocd
        valueFiles:
          - $values/argocd/argo-cd/values.yaml
    - repoURL: https://github.com/bonzonkim/argocd-apps
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 2: Create the other five CRDs from this exact field matrix**

Every file uses the same full CRD structure and second Git source shown in Step 1. Set the first source and identity fields exactly as follows:

| File | name | chart repo | chart | version | release | destination | value file |
|---|---|---|---|---|---|---|---|
| `argocd/argocd-image-updater/application.yaml` | `argocd-image-updater` | `https://argoproj.github.io/argo-helm` | `argocd-image-updater` | `0.14.0` | `argocd-image-updater` | `argocd` | `$values/argocd/argocd-image-updater/values.yaml` |
| `node-local-dns/node-local-dns/application.yaml` | `node-local-dns` | `https://raw.githubusercontent.com/deliveryhero/helm-charts/refs/heads/master/` | `node-local-dns` | `2.7.0` | `node-local-dns` | `kube-system` | `$values/node-local-dns/node-local-dns/values.yaml` |
| `operators/barman-cloud/application.yaml` | `barman-cloud-plugin` | `https://cloudnative-pg.github.io/charts` | `plugin-barman-cloud` | `0.7.0` | `plugin-barman-cloud` | `cnpg-system` | `$values/operators/barman-cloud/values.yaml` |
| `operators/cloudnative-pg/application.yaml` | `cloudnative-pg` | `https://cloudnative-pg.github.io/charts` | `cloudnative-pg` | `0.29.0` | `cloudnative-pg` | `cnpg-system` | `$values/operators/cloudnative-pg/values.yaml` |
| `postgresql/postgresql/application.yaml` | `running-mate-postgresql` | `registry-1.docker.io/bitnamicharts` | `postgresql` | `16.7.27` | `running-mate-postgresql` | `running-mate` | `$values/postgresql/postgresql/values.yaml` |

- [ ] **Step 3: Preserve PostgreSQL generated-secret differences**

Add to `postgresql/postgresql/application.yaml` under `spec`:

```yaml
ignoreDifferences:
  - group: ""
    kind: Secret
    name: running-mate-postgresql
    jsonPointers:
      - /data/postgres-password
      - /data/password
```

- [ ] **Step 4: Verify each value file reference resolves**

Run:

```bash
for values_file in \
  argocd/argo-cd/values.yaml \
  argocd/argocd-image-updater/values.yaml \
  node-local-dns/node-local-dns/values.yaml \
  operators/barman-cloud/values.yaml \
  operators/cloudnative-pg/values.yaml \
  postgresql/postgresql/values.yaml; do
  rtk proxy test -f "$values_file"
done
```

Expected: zero exit status.

- [ ] **Step 5: Resolve the charts**

```bash
rtk proxy helm show chart argo-cd --repo https://argoproj.github.io/argo-helm --version 9.3.7
rtk proxy helm show chart argocd-image-updater --repo https://argoproj.github.io/argo-helm --version 0.14.0
rtk proxy helm show chart node-local-dns --repo https://raw.githubusercontent.com/deliveryhero/helm-charts/refs/heads/master/ --version 2.7.0
rtk proxy helm show chart plugin-barman-cloud --repo https://cloudnative-pg.github.io/charts --version 0.7.0
rtk proxy helm show chart cloudnative-pg --repo https://cloudnative-pg.github.io/charts --version 0.29.0
rtk proxy helm show chart oci://registry-1.docker.io/bitnamicharts/postgresql --version 16.7.27
```

Expected: each command resolves the pinned version.

- [ ] **Step 6: Commit the six core Helm CRDs**

```bash
rtk git add \
  argocd/argo-cd/application.yaml \
  argocd/argocd-image-updater/application.yaml \
  node-local-dns/node-local-dns/application.yaml \
  operators/barman-cloud/application.yaml \
  operators/cloudnative-pg/application.yaml \
  postgresql/postgresql/application.yaml
rtk git commit -m "refactor: define core Helm apps as Application CRDs"
```

---

### Task 5: Convert observability and Istio Helm Applications with values files

**Files:**
- Create: `istio-system/istio-cni/application.yaml`
- Create: `monitoring/grafana/application.yaml`
- Create: `monitoring/vector/application.yaml`
- Create: `prometheus/kube-prometheus-stack/application.yaml`
- Create: `victoria/loki-vl-proxy/application.yaml`
- Create: `victoria/victoria-logs/application.yaml`
- Test: six Application CRDs, values references, chart resolutions, and Prometheus sync options

**Interfaces:**
- Consumes: existing values files and the approved activation of Prometheus-specific sync options.
- Produces: the final six multi-source Helm Applications, bringing the inventory to 18 Helm CRDs.

- [ ] **Step 1: Create istio-cni as the concrete multi-source CRD**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: istio-cni
  namespace: argocd
  labels:
    source-type: helm
spec:
  project: default
  sources:
    - repoURL: https://istio-release.storage.googleapis.com/charts
      chart: cni
      targetRevision: 1.30.3
      helm:
        releaseName: istio-cni
        valueFiles:
          - $values/istio-system/istio-cni/values.yaml
    - repoURL: https://github.com/bonzonkim/argocd-apps
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: istio-system
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 2: Create the remaining five multi-source CRDs**

Use the complete CRD structure shown in Step 1, including the second Git source,
with these exact identity and first-source values:

| File | name | chart repo | chart | version | release | destination | value file |
|---|---|---|---|---|---|---|---|
| `monitoring/grafana/application.yaml` | `grafana` | `https://grafana.github.io/helm-charts` | `grafana` | `10.1.2` | `grafana` | `monitoring` | `$values/monitoring/grafana/values.yaml` |
| `monitoring/vector/application.yaml` | `vector` | `https://helm.vector.dev` | `vector` | `0.46.0` | `vector` | `monitoring` | `$values/monitoring/vector/values.yaml` |
| `prometheus/kube-prometheus-stack/application.yaml` | `prometheus-kube-prometheus-stack` | `https://prometheus-community.github.io/helm-charts` | `kube-prometheus-stack` | `79.0.0` | `kube-prometheus-stack` | `prometheus` | `$values/prometheus/kube-prometheus-stack/values.yaml` |
| `victoria/loki-vl-proxy/application.yaml` | `loki-vl-proxy` | `ghcr.io/reliablyobserve/charts` | `loki-vl-proxy` | `1.8.1` | `loki-vl-proxy` | `victoria` | `$values/victoria/loki-vl-proxy/values.yaml` |
| `victoria/victoria-logs/application.yaml` | `victoria-logs` | `https://victoriametrics.github.io/helm-charts/` | `victoria-logs-single` | `0.11.16` | `victoria-logs` | `victoria` | `$values/victoria/victoria-logs/values.yaml` |

- [ ] **Step 3: Activate Prometheus-specific sync options**

In `prometheus/kube-prometheus-stack/application.yaml`, use this exact list instead of the common two-item list:

```yaml
syncOptions:
  - CreateNamespace=true
  - Validate=false
  - PrunePropagationPolicy=foreground
  - PruneLast=true
  - RespectIgnoreDifferences=true
  - ApplyOutOfSyncOnly=true
  - ServerSideApply=true
```

- [ ] **Step 4: Verify the six local values files**

```bash
for values_file in \
  istio-system/istio-cni/values.yaml \
  monitoring/grafana/values.yaml \
  monitoring/vector/values.yaml \
  prometheus/kube-prometheus-stack/values.yaml \
  victoria/loki-vl-proxy/values.yaml \
  victoria/victoria-logs/values.yaml; do
  rtk proxy test -f "$values_file"
done
```

Expected: zero exit status.

- [ ] **Step 5: Resolve all six charts**

```bash
rtk proxy helm show chart cni --repo https://istio-release.storage.googleapis.com/charts --version 1.30.3
rtk proxy helm show chart grafana --repo https://grafana.github.io/helm-charts --version 10.1.2
rtk proxy helm show chart vector --repo https://helm.vector.dev --version 0.46.0
rtk proxy helm show chart kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts --version 79.0.0
rtk proxy helm show chart oci://ghcr.io/reliablyobserve/charts/loki-vl-proxy --version 1.8.1
rtk proxy helm show chart victoria-logs-single --repo https://victoriametrics.github.io/helm-charts/ --version 0.11.16
```

Expected: every chart and version resolves.

- [ ] **Step 6: Verify the complete CRD inventory now exists**

Run:

```bash
rtk proxy find . -mindepth 3 -maxdepth 3 -type f -name application.yaml | rtk proxy wc -l
```

Expected: `23`.

The global validator still fails at this point because `config.json` files and old ApplicationSet references intentionally remain until Task 6.

- [ ] **Step 7: Commit the final six Helm CRDs**

```bash
rtk git add \
  istio-system/istio-cni/application.yaml \
  monitoring/grafana/application.yaml \
  monitoring/vector/application.yaml \
  prometheus/kube-prometheus-stack/application.yaml \
  victoria/loki-vl-proxy/application.yaml \
  victoria/victoria-logs/application.yaml
rtk git commit -m "refactor: define observability and Istio Application CRDs"
```

---

### Task 6: Switch both ApplicationSets and remove config.json

**Files:**
- Modify: `apps/appset-helm.yaml`
- Modify: `apps/appset-raw.yaml`
- Delete: all 23 `*/*/config.json` files listed by `find . -mindepth 3 -maxdepth 3 -name config.json`
- Test: `scripts/validate-application-manifests.sh`

**Interfaces:**
- Consumes: all 23 complete CRDs and their `source-type` labels.
- Produces: the final root Application → two ApplicationSets → 23 Applications reconciliation chain.

- [ ] **Step 1: Replace `apps/appset-helm.yaml` with the generic Helm pass-through ApplicationSet**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: appset-helm
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions:
    - missingkey=error
  syncPolicy:
    preserveResourcesOnDeletion: true
  generators:
    - git:
        repoURL: https://github.com/bonzonkim/argocd-apps
        revision: main
        files:
          - path: "*/*/application.yaml"
      selector:
        matchLabels:
          metadata.labels.source-type: helm
  template:
    metadata:
      name: "{{ .metadata.name }}"
    spec:
      project: "{{ .spec.project }}"
  templatePatch: |
    {{- $metadata := deepCopy .metadata }}
    {{- $spec := deepCopy .spec }}
    {{- $_ := unset $spec "project" }}
    {{- dict "metadata" $metadata "spec" $spec | mustToPrettyJson }}
```

- [ ] **Step 2: Replace `apps/appset-raw.yaml` with the raw pass-through ApplicationSet**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: appset-raw
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions:
    - missingkey=error
  syncPolicy:
    preserveResourcesOnDeletion: true
  generators:
    - git:
        repoURL: https://github.com/bonzonkim/argocd-apps
        revision: main
        files:
          - path: "*/*/application.yaml"
      selector:
        matchLabels:
          metadata.labels.source-type: raw
  template:
    metadata:
      name: "{{ .metadata.name }}"
    spec:
      project: "{{ .spec.project }}"
  templatePatch: |
    {{- $metadata := deepCopy .metadata }}
    {{- $spec := deepCopy .spec }}
    {{- $_ := unset $spec "project" }}
    {{- dict "metadata" $metadata "spec" $spec | mustToPrettyJson }}
```

- [ ] **Step 3: Confirm the root Application needs no modification**

Run:

```bash
rtk git diff --exit-code -- bootstrap/root-app.yaml
```

Expected: zero exit status and no diff.

- [ ] **Step 4: Delete exactly the 23 replaced config files**

First resolve and review the targets:

```bash
rtk proxy find . -mindepth 3 -maxdepth 3 -type f -name config.json | rtk proxy sort
```

Expected: 23 paths corresponding one-for-one with the 23 new `application.yaml` files.

Delete those explicit files with `apply_patch`; do not use a broad recursive deletion command.

- [ ] **Step 5: Run the final-state validator**

```bash
rtk proxy ./scripts/validate-application-manifests.sh
```

Expected:

```text
validated 23 Application manifests: 18 helm, 5 raw
```

- [ ] **Step 6: Validate all YAML parses**

```bash
rtk proxy yq eval-all 'true' \
  apps/appset-helm.yaml \
  apps/appset-raw.yaml \
  */*/application.yaml
```

Expected: zero exit status.

- [ ] **Step 7: Commit the atomic generator cutover**

```bash
rtk git add apps/appset-helm.yaml apps/appset-raw.yaml scripts/validate-application-manifests.sh
rtk git add -A -- '*/*/config.json'
rtk git commit -m "refactor: generate apps from Application CRDs"
```

---

### Task 7: Verify schema, behavior changes, and migration safety

**Files:**
- Verify: all 23 `application.yaml` files
- Verify: `apps/appset-helm.yaml`
- Verify: `apps/appset-raw.yaml`
- Verify: `bootstrap/root-app.yaml`
- Test: local validator, Kubernetes dry-runs, Git diff audit, and post-sync Argo CD topology

**Interfaces:**
- Consumes: the completed migration branch.
- Produces: evidence that the branch is safe to merge and that the live hierarchy remains unchanged.

- [ ] **Step 1: Run repository validation from a clean shell**

```bash
rtk proxy ./scripts/validate-application-manifests.sh
rtk git diff --check
rtk git status --short
```

Expected: validator success, no whitespace errors, and no uncommitted implementation files.

- [ ] **Step 2: Validate all child CRDs against the Kubernetes API**

First use client dry-run:

```bash
for manifest in */*/application.yaml; do
  rtk kubectl apply --dry-run=client -f "$manifest"
done
```

Expected: all 23 Applications report `created (dry run)` or `configured (dry run)`.

Then use server dry-run against the target cluster:

```bash
for manifest in */*/application.yaml; do
  rtk kubectl apply --dry-run=server -f "$manifest"
done
rtk kubectl apply --dry-run=server -f apps/appset-helm.yaml
rtk kubectl apply --dry-run=server -f apps/appset-raw.yaml
```

Expected: all 25 CRDs pass the installed Argo CD CRD schemas without mutation.

- [ ] **Step 3: Audit the two intentional behavior changes**

```bash
rtk proxy yq '.spec.source.helm.valuesObject' cert-manager/cert-manager/application.yaml
rtk proxy yq '.spec.syncPolicy.syncOptions' prometheus/kube-prometheus-stack/application.yaml
```

Expected cert-manager output:

```yaml
installCRDs: true
```

Expected Prometheus output contains all seven items:

```yaml
- CreateNamespace=true
- Validate=false
- PrunePropagationPolicy=foreground
- PruneLast=true
- RespectIgnoreDifferences=true
- ApplyOutOfSyncOnly=true
- ServerSideApply=true
```

- [ ] **Step 4: Confirm deletion and ownership safety**

```bash
rtk proxy yq '.spec.syncPolicy.preserveResourcesOnDeletion' apps/appset-helm.yaml
rtk proxy yq '.spec.syncPolicy.preserveResourcesOnDeletion' apps/appset-raw.yaml
rtk rg -n 'resources-finalizer.argocd.argoproj.io' */*/application.yaml
```

Expected: both values are `true`; `rg` finds no child finalizer and exits with no matches.

- [ ] **Step 5: Review the complete branch diff**

```bash
rtk proxy git diff --stat HEAD~6..HEAD
rtk proxy git diff HEAD~6..HEAD -- apps bootstrap/root-app.yaml
rtk proxy git diff --name-status HEAD~6..HEAD
```

Expected:

- 23 `application.yaml` files added.
- 23 matching `config.json` files deleted.
- Two ApplicationSets modified.
- One validator added.
- `bootstrap/root-app.yaml` unchanged.

- [ ] **Step 6: Merge the complete branch as one deployment unit**

Do not cherry-pick Tasks 1–5 independently into `main`. Merge only when every previous check passes so the root Application observes the complete final tree in one Git revision.

- [ ] **Step 7: Verify the live topology after root-app reconciliation**

Run:

```bash
rtk kubectl -n argocd get applicationsets.argoproj.io \
  appset-helm appset-raw \
  -o custom-columns=NAME:.metadata.name,HEALTH:.status.conditions[-1].reason

rtk kubectl -n argocd get applications.argoproj.io \
  -l argocd.argoproj.io/application-set-name=appset-helm \
  -o name | rtk proxy wc -l

rtk kubectl -n argocd get applications.argoproj.io \
  -l argocd.argoproj.io/application-set-name=appset-raw \
  -o name | rtk proxy wc -l
```

Expected: both ApplicationSets reconcile without error, `appset-helm` owns 18 Applications, and `appset-raw` owns 5.

Run:

```bash
rtk kubectl -n argocd get applications.argoproj.io \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
```

Expected: the same 23 child Application names remain present. Investigate any deliberate cert-manager or Prometheus diff before syncing it; all other Applications should retain their existing rendered workload state.

---

## Rollback

If either ApplicationSet fails to render after merge:

1. Revert the complete migration merge commit.
2. Let the unchanged root Application reconcile `apps/`.
3. Confirm both ApplicationSets again read `*/*/config.json`.
4. Confirm all 23 Application names remain present.

Workload pruning remains disabled and the ApplicationSets preserve resources on deletion, so rollback does not require deleting or reinstalling workloads.
