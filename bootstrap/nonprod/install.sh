#!/usr/bin/env bash
#
# Installs Argo CD on the current kubectl context, gives it the read-only deploy key it needs
# to read cronus-gitops, and applies the AppProject and the three ApplicationSets that hand
# the rest of the repository over to Argo.
#
#   ./install.sh
#
# Steps, and the order matters:
#
#   1. The Helm release. The only part of this that Argo does not manage, deliberately: a
#      component that can be broken by its own sync is a component that cannot fix itself.
#   2. The deploy key, as a Secret in the cluster rather than a value in the chart. A private
#      SSH key cannot live in a file that is committed to git, and this repository is where
#      it would otherwise go.
#   3. The AppProject, then the ApplicationSets — the project first, because an Application
#      that names a project which does not exist cannot be created.
#
# Once these are applied, everything else in this repository belongs to Argo: the ApplicationSets
# read environments/ for what each environment declares, platform/ for the shared pieces that are
# not an environment, and charts/ for the workloads of every environment, inside the boundary the
# project describes.
#
# **This script is the only thing that applies the files in bootstrap/nonprod/, and Argo does not read the
# directory at all.** Editing bootstrap/nonprod/appproject.yaml or an ApplicationSet in git changes nothing
# in the cluster until this script runs again. That is deliberate — the objects that decide what
# Argo is allowed to do should not be editable by Argo — but it does mean a push is not a
# deployment. Re-run this after changing anything under bootstrap/nonprod/, or the cluster keeps running the
# previous revision of it.
#
# Safe to run again. The Helm release is upgraded in place, the Secret is applied rather than
# created, and the AppProject and ApplicationSets are applied.
#
# Run from a machine that can reach the cluster. `az aks get-credentials` writes the context;
# note that the API server answers only the authorized address ranges configured in
# cronus-infrastructure, so an address missing from that list cannot reach it at all.

set -euo pipefail

# Pinned rather than floating. An Argo upgrade is a deliberate act, and the chart and the
# application versions move together in a way that is worth reviewing: chart 10.9.6 ships
# Argo CD v3.5.3.
chart_version=${CHART_VERSION:-10.9.6}
namespace=${ARGOCD_NAMESPACE:-argocd}

# Must match the repoURL in each of the ApplicationSets under application-sets/. They are written
# twice because one is a Kubernetes object and the other is a credential for it, and nothing joins
# them automatically — so if they ever disagree, the key is for a repository the ApplicationSets do
# not read and every application sits in an authentication error.
repo_url=${GITOPS_REPO_URL:-git@github.com:hashirsarwar/cronus-gitops.git}

# The private half of the deploy key GitHub is given. Never committed; see .gitignore.
deploy_key_file=${DEPLOY_KEY_FILE:-$HOME/.ssh/cronus_gitops_deploy}

for tool in helm kubectl; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "install: $tool is required and is not on PATH" >&2
    exit 1
  }
done

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

echo "==> Context"
kubectl config current-context | sed 's/^/    /'

echo "==> Chart repository"
helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
helm repo update argo >/dev/null

echo "==> Argo CD $chart_version"
# --wait blocks until the controllers are actually serving rather than merely created, so a
# failure to start is reported here rather than discovered later as an Application that never
# syncs. Helm 4 defaults a fresh install to server-side apply; nothing in this chart needs a
# post-renderer, which is the one Helm 4 change that would have mattered.
helm upgrade --install argocd argo/argo-cd \
  --version "$chart_version" \
  --namespace "$namespace" \
  --create-namespace \
  --values "$here/values.yaml" \
  --wait

echo "==> Deploy key"
if [ -f "$deploy_key_file" ]; then
  # Applied rather than created so that re-running with a rotated key updates it, and so that
  # the label Argo matches on is part of the same object. kubectl apply re-reads the file, so
  # a rotated key takes effect on the next run without any other step.
  {
    cat <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: cronus-gitops-repo
  namespace: ${namespace}
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: ${repo_url}
  sshPrivateKey: |
YAML
    sed 's/^/    /' "$deploy_key_file"
  } | kubectl apply -f -

  echo "    applied from $deploy_key_file"
else
  # Not fatal: the Helm release and the ApplicationSets are both worth having without it, and
  # the Applications will simply report an authentication error until the key exists. The
  # steps to produce one are in README.md.
  echo "    no key at $deploy_key_file, so nothing was applied" >&2
  echo "    Argo CD will not be able to read the repository until one exists; see README.md" >&2
fi

echo "==> AppProject"
# Before the ApplicationSets, because the Applications they generate name this project and one
# cannot be created while naming a project that does not exist. Applied rather than created
# so that tightening it later is the same command as installing it the first time.
kubectl apply -f "$here/appproject.yaml" | sed 's/^/    /'

# The three ApplicationSets partition the repository, and each is applied separately so that a
# change to one can be rolled out without re-applying the others. All three name the project
# above, so they come after it.
#
#   environments.yaml  one Application per directory in environments/, owned by that environment
#   platform.yaml      one Application for platform/gateway/foundation/ — the Gateway namespace and
#                      its policies — and one per directory under platform/gateway/environments/
#   workloads.yaml     one Application per chart per environment
echo "==> Environments ApplicationSet"
kubectl apply -f "$here/application-sets/environments.yaml" | sed 's/^/    /'

echo "==> Platform ApplicationSet"
kubectl apply -f "$here/application-sets/platform.yaml" | sed 's/^/    /'

echo "==> Workloads ApplicationSet"
# Last, and not because it depends on the other two: it does not have to wait for the environments
# to sync first, even though the workloads reference ServiceAccounts that they create — the retry
# configured in the file covers the one ordering Argo does not fix.
kubectl apply -f "$here/application-sets/workloads.yaml" | sed 's/^/    /'

echo
echo "install: done"
echo
echo "The UI is not published. To reach it:"
echo "    kubectl -n $namespace port-forward svc/argocd-server 8080:443"
echo "    # then https://localhost:8080, user admin"
echo
echo "The initial admin password:"
echo "    kubectl -n $namespace get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo
echo "Applications, once the repository is readable:"
echo "    kubectl -n $namespace get applications"
echo
echo "The names sort by environment: one cronus-<environment>-foundation per directory in"
echo "environments/, then cronus-<environment>-<workload> for each chart, and the platform"
echo "Applications under cronus-platform-... and cronus-<environment>-gateway."
