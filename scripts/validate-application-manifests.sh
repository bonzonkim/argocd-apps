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
    vector \
    victoria-logs \
    ztunnel |
    sort
)"

application_files="$(find . -mindepth 3 -maxdepth 3 -type f -name application.yaml | sort)"
application_count="$(printf '%s\n' "$application_files" | sed '/^$/d' | wc -l | tr -d ' ')"

if [[ "$application_count" != "22" ]]; then
  echo "expected 22 application.yaml files, found $application_count" >&2
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

  if yq -e '.metadata.finalizers[]? == "resources-finalizer.argocd.argoproj.io"' "$file" >/dev/null 2>&1; then
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

if [[ "$helm_count" != "18" || "$raw_count" != "4" ]]; then
  echo "expected 18 helm and 4 raw Applications; found $helm_count helm and $raw_count raw" >&2
  exit 1
fi

if ! diff -u \
  <(printf '%s\n' "$expected_names") \
  <(printf '%s' "$actual_names" | sort); then
  echo "Application name inventory differs" >&2
  exit 1
fi

manifest_matrix="$(
  printf '%s\n' \
    './argocd/argo-cd/application.yaml|helm|argo-cd|https://argoproj.github.io/argo-helm|argo-cd|9.3.7|argocd|argocd|$values/argocd/argo-cd/values.yaml|' \
    './argocd/argocd-image-updater/application.yaml|helm|argocd-image-updater|https://argoproj.github.io/argo-helm|argocd-image-updater|0.14.0|argocd-image-updater|argocd|$values/argocd/argocd-image-updater/values.yaml|' \
    './cert-manager/cert-manager/application.yaml|helm|cert-manager|https://charts.jetstack.io|cert-manager|1.19.2|cert-manager|cert-manager||' \
    './infisical-operator-system/infisical-secrets-operator/application.yaml|helm|infisical-secrets-operator|https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts|secrets-operator|0.6.2|infisical-secrets-operator|infisical-operator-system||' \
    './istio-system/istio-cni/application.yaml|helm|istio-cni|https://istio-release.storage.googleapis.com/charts|cni|1.30.3|istio-cni|istio-system|$values/istio-system/istio-cni/values.yaml|' \
    './istio-system/istiod/application.yaml|helm|istiod|https://istio-release.storage.googleapis.com/charts|istiod|1.30.3|istiod|istio-system||' \
    './istio-system/ztunnel/application.yaml|helm|ztunnel|https://istio-release.storage.googleapis.com/charts|ztunnel|1.30.3|ztunnel|istio-system||' \
    './monitoring/grafana/application.yaml|helm|grafana|https://grafana.github.io/helm-charts|grafana|10.1.2|grafana|monitoring|$values/monitoring/grafana/values.yaml|' \
    './monitoring/vector/application.yaml|helm|vector|https://helm.vector.dev|vector|0.46.0|vector|monitoring|$values/monitoring/vector/values.yaml|' \
    './node-local-dns/node-local-dns/application.yaml|helm|node-local-dns|https://raw.githubusercontent.com/deliveryhero/helm-charts/refs/heads/master/|node-local-dns|2.7.0|node-local-dns|kube-system|$values/node-local-dns/node-local-dns/values.yaml|' \
    './operators/barman-cloud/application.yaml|helm|barman-cloud-plugin|https://cloudnative-pg.github.io/charts|plugin-barman-cloud|0.7.0|plugin-barman-cloud|cnpg-system|$values/operators/barman-cloud/values.yaml|' \
    './operators/cloudnative-pg/application.yaml|helm|cloudnative-pg|https://cloudnative-pg.github.io/charts|cloudnative-pg|0.29.0|cloudnative-pg|cnpg-system|$values/operators/cloudnative-pg/values.yaml|' \
    './postgresql/postgresql/application.yaml|helm|running-mate-postgresql|registry-1.docker.io/bitnamicharts|postgresql|16.7.27|running-mate-postgresql|running-mate|$values/postgresql/postgresql/values.yaml|' \
    './prometheus/kube-prometheus-stack/application.yaml|helm|prometheus-kube-prometheus-stack|https://prometheus-community.github.io/helm-charts|kube-prometheus-stack|79.0.0|kube-prometheus-stack|prometheus|$values/prometheus/kube-prometheus-stack/values.yaml|' \
    './redis/redis/application.yaml|helm|redis|registry-1.docker.io/bitnamicharts|redis|23.2.1|redis|redis||' \
    './reflector/reflector/application.yaml|helm|reflector|https://emberstack.github.io/helm-charts|reflector|7.1.262|reflector|reflector||' \
    './victoria/loki-vl-proxy/application.yaml|helm|loki-vl-proxy|ghcr.io/reliablyobserve/charts|loki-vl-proxy|1.8.1|loki-vl-proxy|victoria|$values/victoria/loki-vl-proxy/values.yaml|' \
    './victoria/victoria-logs/application.yaml|helm|victoria-logs|https://victoriametrics.github.io/helm-charts/|victoria-logs-single|0.11.16|victoria-logs|victoria|$values/victoria/victoria-logs/values.yaml|' \
    './fantasy-realm/fantasy-realm/application.yaml|raw|fantasy-realm|https://github.com/bonzonkim/argocd-apps||||fantasy-realm||fantasy-realm/fantasy-realm' \
    './grammair/server/application.yaml|raw|grammair-server|https://github.com/bonzonkim/argocd-apps||||grammair||grammair/server' \
    './grammair/web/application.yaml|raw|grammair-web|https://github.com/bonzonkim/argocd-apps||||grammair||grammair/web' \
    './running-mate/api/application.yaml|raw|running-mate-api|https://github.com/bonzonkim/argocd-apps||||running-mate||running-mate/api'
)"

while IFS='|' read -r file source_type name repo chart version release destination value_file raw_path; do
  [[ -f "$file" ]] || {
    echo "missing expected Application manifest: $file" >&2
    exit 1
  }

  if [[ "$source_type" == "helm" && -n "$value_file" ]]; then
    if ! \
      EXPECTED_NAME="$name" \
      EXPECTED_REPO="$repo" \
      EXPECTED_CHART="$chart" \
      EXPECTED_VERSION="$version" \
      EXPECTED_RELEASE="$release" \
      EXPECTED_DESTINATION="$destination" \
      EXPECTED_VALUE_FILE="$value_file" \
      yq -e '
        .metadata.name == strenv(EXPECTED_NAME) and
        .metadata.labels."source-type" == "helm" and
        .spec.source == null and
        (.spec.sources | length) == 2 and
        .spec.sources[0].repoURL == strenv(EXPECTED_REPO) and
        .spec.sources[0].chart == strenv(EXPECTED_CHART) and
        .spec.sources[0].targetRevision == strenv(EXPECTED_VERSION) and
        .spec.sources[0].helm.releaseName == strenv(EXPECTED_RELEASE) and
        (.spec.sources[0].helm.valueFiles | length) == 1 and
        .spec.sources[0].helm.valueFiles[0] == strenv(EXPECTED_VALUE_FILE) and
        .spec.sources[1].repoURL == "https://github.com/bonzonkim/argocd-apps" and
        .spec.sources[1].targetRevision == "main" and
        .spec.sources[1].ref == "values" and
        .spec.destination.namespace == strenv(EXPECTED_DESTINATION)
      ' "$file" >/dev/null; then
      echo "$file differs from the expected Helm source matrix" >&2
      exit 1
    fi
  elif [[ "$source_type" == "helm" ]]; then
    if ! \
      EXPECTED_NAME="$name" \
      EXPECTED_REPO="$repo" \
      EXPECTED_CHART="$chart" \
      EXPECTED_VERSION="$version" \
      EXPECTED_RELEASE="$release" \
      EXPECTED_DESTINATION="$destination" \
      yq -e '
        .metadata.name == strenv(EXPECTED_NAME) and
        .metadata.labels."source-type" == "helm" and
        .spec.sources == null and
        .spec.source.repoURL == strenv(EXPECTED_REPO) and
        .spec.source.chart == strenv(EXPECTED_CHART) and
        .spec.source.targetRevision == strenv(EXPECTED_VERSION) and
        .spec.source.helm.releaseName == strenv(EXPECTED_RELEASE) and
        .spec.source.helm.valueFiles == null and
        .spec.destination.namespace == strenv(EXPECTED_DESTINATION)
      ' "$file" >/dev/null; then
      echo "$file differs from the expected Helm source matrix" >&2
      exit 1
    fi
  else
    if ! \
      EXPECTED_NAME="$name" \
      EXPECTED_REPO="$repo" \
      EXPECTED_DESTINATION="$destination" \
      EXPECTED_PATH="$raw_path" \
      yq -e '
        .metadata.name == strenv(EXPECTED_NAME) and
        .metadata.labels."source-type" == "raw" and
        .spec.sources == null and
        .spec.source.repoURL == strenv(EXPECTED_REPO) and
        .spec.source.targetRevision == "main" and
        .spec.source.path == strenv(EXPECTED_PATH) and
        .spec.destination.namespace == strenv(EXPECTED_DESTINATION)
      ' "$file" >/dev/null; then
      echo "$file differs from the expected raw source matrix" >&2
      exit 1
    fi
  fi
done <<< "$manifest_matrix"

check_annotations() {
  local file="$1"
  local expected_annotations="$2"
  local actual_json
  local expected_json

  actual_json="$(yq -o=json -I=0 '.metadata.annotations | sort_keys(.)' "$file")"
  expected_json="$(
    EXPECTED_ANNOTATIONS="$expected_annotations" \
      yq -n -o=json -I=0 'strenv(EXPECTED_ANNOTATIONS) | from_json | sort_keys(.)'
  )"

  if [[ "$actual_json" != "$expected_json" ]]; then
    echo "$file differs from the expected image-updater annotations" >&2
    exit 1
  fi
}

check_annotations fantasy-realm/fantasy-realm/application.yaml \
  '{"argocd-image-updater.argoproj.io/image-list":"fantasy-realm=ghcr.io/bonzonkim/fantasy-realm/fantasy-realm","argocd-image-updater.argoproj.io/fantasy-realm.update-strategy":"semver","argocd-image-updater.argoproj.io/git-branch":"main","argocd-image-updater.argoproj.io/write-back-method":"git","argocd-image-updater.argoproj.io/fantasy-realm.pull-secret":"pullsecret:argocd/fantasy-realm-packages","argocd-image-updater.argoproj.io/fantasy-realm.allow-tags":"regexp:^1\\.0\\.[0-9]+$"}'
check_annotations grammair/server/application.yaml \
  '{"argocd-image-updater.argoproj.io/image-list":"grammair-server=ghcr.io/bonzonkim/grammair-server/grammair-server","argocd-image-updater.argoproj.io/grammair-server.update-strategy":"semver","argocd-image-updater.argoproj.io/git-branch":"master","argocd-image-updater.argoproj.io/grammair-server.pull-secret":"pullsecret:argocd/grammair-packages","argocd-image-updater.argoproj.io/grammair-server.allow-tags":"regexp:^1\\.0\\.[0-9]+$"}'
check_annotations grammair/web/application.yaml \
  '{"argocd-image-updater.argoproj.io/image-list":"grammair-web=ghcr.io/bonzonkim/grammair-web/grammair-web","argocd-image-updater.argoproj.io/grammair-web.update-strategy":"semver","argocd-image-updater.argoproj.io/git-branch":"main","argocd-image-updater.argoproj.io/grammair-web.pull-secret":"pullsecret:argocd/grammair-packages","argocd-image-updater.argoproj.io/grammair-web.allow-tags":"regexp:^1\\.0\\.[0-9]+$"}'
check_annotations running-mate/api/application.yaml \
  '{"argocd-image-updater.argoproj.io/image-list":"running-mate-api=ghcr.io/bonzonkim/running-mate-api","argocd-image-updater.argoproj.io/running-mate-api.update-strategy":"semver","argocd-image-updater.argoproj.io/git-branch":"main","argocd-image-updater.argoproj.io/write-back-method":"git","argocd-image-updater.argoproj.io/running-mate-api.pull-secret":"pullsecret:argocd/running-mate-packages","argocd-image-updater.argoproj.io/running-mate-api.allow-tags":"regexp:^0\\.2\\.[0-9]+$"}'

if ! yq -e '
  (.spec.ignoreDifferences | length) == 1 and
  .spec.ignoreDifferences[0].group == "" and
  .spec.ignoreDifferences[0].kind == "Secret" and
  .spec.ignoreDifferences[0].name == "redis" and
  (.spec.ignoreDifferences[0].jsonPointers | length) == 1 and
  .spec.ignoreDifferences[0].jsonPointers[0] == "/data/redis-password"
' redis/redis/application.yaml >/dev/null; then
  echo "redis/redis/application.yaml has unexpected ignoreDifferences" >&2
  exit 1
fi

if ! yq -e '
  (.spec.source.helm.valuesObject | keys | length) == 1 and
  .spec.source.helm.valuesObject.installCRDs == true
' cert-manager/cert-manager/application.yaml >/dev/null; then
  echo "cert-manager/cert-manager/application.yaml must set only installCRDs=true in valuesObject" >&2
  exit 1
fi

if ! yq -e '
  (.spec.syncPolicy.syncOptions | length) == 7 and
  .spec.syncPolicy.syncOptions[0] == "CreateNamespace=true" and
  .spec.syncPolicy.syncOptions[1] == "Validate=false" and
  .spec.syncPolicy.syncOptions[2] == "PrunePropagationPolicy=foreground" and
  .spec.syncPolicy.syncOptions[3] == "PruneLast=true" and
  .spec.syncPolicy.syncOptions[4] == "RespectIgnoreDifferences=true" and
  .spec.syncPolicy.syncOptions[5] == "ApplyOutOfSyncOnly=true" and
  .spec.syncPolicy.syncOptions[6] == "ServerSideApply=true"
' prometheus/kube-prometheus-stack/application.yaml >/dev/null; then
  echo "prometheus/kube-prometheus-stack/application.yaml has unexpected syncOptions" >&2
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

check_appset() {
  local file="$1"
  local expected_name="$2"
  local expected_source_type="$3"

  if ! \
    EXPECTED_NAME="$expected_name" \
    EXPECTED_SOURCE_TYPE="$expected_source_type" \
    yq -e '
      .metadata.name == strenv(EXPECTED_NAME) and
      .spec.goTemplate == true and
      (.spec.goTemplateOptions | length) == 1 and
      .spec.goTemplateOptions[0] == "missingkey=error" and
      .spec.syncPolicy.preserveResourcesOnDeletion == true and
      (.spec.generators | length) == 1 and
      (.spec.generators[0].git.files | length) == 1 and
      .spec.generators[0].git.files[0].path == "*/*/application.yaml" and
      (.spec.generators[0].selector.matchLabels | keys | length) == 1 and
      .spec.generators[0].selector.matchLabels."metadata.labels.source-type" ==
        strenv(EXPECTED_SOURCE_TYPE) and
      .spec.template.metadata.name == "{{ .metadata.name }}" and
      .spec.template.spec.project == "{{ .spec.project }}" and
      .spec.template.spec.destination.server == "{{ .spec.destination.server }}" and
      .spec.template.spec.destination.namespace == "{{ .spec.destination.namespace }}" and
      (.spec.templatePatch // "") != "" and
      (.spec.templatePatch | contains("deepCopy")) and
      (.spec.templatePatch | contains("unset")) and
      (.spec.templatePatch | contains("mustToPrettyJson"))
    ' "$file" >/dev/null; then
    echo "$file differs from the expected ApplicationSet contract" >&2
    exit 1
  fi
}

check_appset apps/appset-helm.yaml appset-helm helm
check_appset apps/appset-raw.yaml appset-raw raw

echo "validated 22 Application manifests: 18 helm, 4 raw"
