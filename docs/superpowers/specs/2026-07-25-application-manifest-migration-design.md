# Application Manifest Migration Design

## Goal

Replace every per-application `config.json` with a complete Argo CD
`Application` CRD manifest named `application.yaml`, while preserving the
existing ownership hierarchy:

```text
applications (root Application)
├── appset-helm (ApplicationSet)
│   └── Helm Applications
└── appset-raw (ApplicationSet)
    └── Raw Applications
```

The migration covers the entire repository: 18 Helm Applications and 5 raw
Git Applications.

## Repository Layout

Each managed application uses this layout:

```text
<namespace>/<app>/
├── application.yaml
└── values.yaml  # only when the Helm application has repository-managed values
```

Every `application.yaml` is independently valid as an Argo CD CRD:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: example
  namespace: argocd
  labels:
    source-type: helm
spec:
  project: default
  # Complete Application specification
```

The `source-type` label is part of the valid Application metadata and is also
the discriminator used by the two ApplicationSets.

## Root Application

`bootstrap/root-app.yaml` remains unchanged. It continues to reconcile the
`apps/` directory recursively, which contains `appset-helm.yaml` and
`appset-raw.yaml`.

The root Application does not directly reconcile the per-application
manifests. This preserves the existing three-level ownership hierarchy and the
relationships visible in the Argo CD UI.

## ApplicationSet Design

Both existing ApplicationSet resource names are preserved. Their Git files
generators change from:

```yaml
files:
  - path: "*/*/config.json"
```

to:

```yaml
files:
  - path: "*/*/application.yaml"
```

`appset-helm` selects generated parameters whose
`metadata.labels.source-type` value is `helm`. `appset-raw` selects the same
field with value `raw`.

Both ApplicationSets enable Go templating with `missingkey=error`. Their base
template supplies the fields that cannot safely be passed through a template
patch:

```yaml
template:
  metadata:
    name: "{{ .metadata.name }}"
  spec:
    project: "{{ .spec.project }}"
```

The ApplicationSet `templatePatch` copies the remaining metadata and spec from
the parsed CRD. It removes `spec.project` from the patch because Argo CD does
not support setting that field from `templatePatch`; the base template is its
single source of truth. The patch is serialized as JSON before parsing to
prevent YAML or template injection through string values.

`apiVersion` and `kind` from the source file are validation and portability
fields. The ApplicationSet controller supplies those fields on generated
Applications.

The following existing ApplicationSet behavior remains unchanged:

- `spec.syncPolicy.preserveResourcesOnDeletion: true`
- Generated Application names
- `appset-helm` and `appset-raw` resource names
- Default project `default`
- Destination cluster `https://kubernetes.default.svc`

## Application Specifications

### Helm Applications

A Helm Application with a repository-managed `values.yaml` uses Argo CD
multi-source configuration:

1. The external Helm chart repository and pinned chart version.
2. This Git repository with `ref: values`.
3. `$values/<namespace>/<app>/values.yaml` in the Helm source.

`helm.ignoreMissingValueFiles` is no longer used to hide absent files. An
Application either references an existing `values.yaml` or omits the value file
source entirely.

A Helm Application without a repository-managed values file uses a single
Helm source. Inline Helm settings such as `valuesObject` remain in that source.

Every Helm Application explicitly carries:

- Chart repository, chart name, and target revision
- Helm release name
- Destination namespace
- Automated self-heal behavior
- Application-specific sync options
- Application-specific `ignoreDifferences`

Istio chart names match the names published in the configured Helm repository:
`cni`, `ztunnel`, and `istiod`.

### Raw Git Applications

Each raw Application points to its own `<namespace>/<app>` path in this
repository. Its destination namespace is explicit rather than inferred from
the first directory segment.

Argo CD Image Updater annotations currently stored in `config.json` move
unchanged to `metadata.annotations` in the corresponding Application.

### Previously Ignored Configuration

The complete CRDs make application-specific intent authoritative rather than
limiting it to fields recognized by a shared template. The migration therefore
activates settings that exist in `config.json` but are not currently consumed:

- `cert-manager` receives `spec.source.helm.valuesObject.installCRDs: true`.
- `prometheus-kube-prometheus-stack` receives its configured sync options.
- Applications with an existing `values.yaml` explicitly reference it.

These are intentional behavior changes and must be called out in the rendered
manifest comparison before deployment.

## Sync and Deletion Semantics

Generated Applications retain automated self-healing and `prune: false`.
Helm Applications retain `CreateNamespace=true` and `ServerSideApply=true`
unless an Application defines a more specific sync option set. Raw
Applications retain `CreateNamespace=true`.

Per-application manifests do not add
`resources-finalizer.argocd.argoproj.io`. ApplicationSet-level
`preserveResourcesOnDeletion: true` remains enabled, preventing an
ApplicationSet deletion from cascading into managed workloads.

## Migration Strategy

The repository changes land atomically in one commit:

1. Add all 23 `application.yaml` files.
2. Change both existing ApplicationSets to consume those files.
3. Delete all 23 `config.json` files.
4. Leave `bootstrap/root-app.yaml` unchanged.

Keeping the same ApplicationSet names and generated Application names lets the
ApplicationSet controller update existing Application resources in place.
There is no ownership handoff to a differently named ApplicationSet.

The commit must not temporarily contain an Application name in both old and
new generator outputs. Both ApplicationSets switch their file patterns in the
same commit as the file migration.

Rollback is a single revert of the migration commit. Because workload pruning
is disabled and ApplicationSet deletion preservation remains enabled, rollback
does not require workload recreation.

## Validation

Pre-deployment validation must prove:

1. All 23 `application.yaml` files parse as YAML and have
   `apiVersion: argoproj.io/v1alpha1`, `kind: Application`, and
   `metadata.namespace: argocd`.
2. Application names are unique and exactly match the 23 current generated
   names.
3. Exactly 18 files have `source-type: helm` and 5 have `source-type: raw`.
4. Every referenced repository-managed values file exists.
5. Every raw Git source path exists.
6. Each configured Helm chart and pinned version can be resolved from its
   repository.
7. ApplicationSet generation produces exactly the same 23 Application names.
8. Existing Image Updater annotations, `ignoreDifferences`, release names,
   destination namespaces, and sync policies are preserved.
9. The deliberate `cert-manager` and Prometheus behavior changes appear in the
   rendered Applications.
10. There are no remaining `config.json` files or ApplicationSet references to
    `config.json`.

After deployment, Argo CD must show the same root Application to ApplicationSet
to Application topology, with both ApplicationSets healthy and all 23 child
Applications present.

## Non-Goals

- Consolidating the two ApplicationSets into one.
- Changing the root Application.
- Changing Application names, release names, chart versions, or destination
  namespaces except where a formerly inferred namespace is made explicit.
- Enabling workload pruning.
- Refactoring workload manifests or Helm values unrelated to Application
  ownership.
