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
