#!/usr/bin/env bash
# Use AKS run command because the production API is private; callers need the separate runcommand grant.
# Apply the release, read-only deploy-key Secret, project and sets manually so Argo cannot break its own bootstrap.
# Re-run after bootstrap edits; ordinary GitOps syncs do not read this directory. See README.md.

set -euo pipefail

# Pin production upgrades independently of nonprod so a development upgrade cannot change its control plane.
chart_version=${CHART_VERSION:-10.9.6}
namespace=${ARGOCD_NAMESPACE:-argocd}

# Name the target cluster explicitly; run command does not use a local kubectl context.
resource_group=${RESOURCE_GROUP:-rg-cronus-prod}
cluster_name=${CLUSTER_NAME:-aks-cronus-prod}

# Match the ApplicationSets' repoURL so Argo can associate this credential with the intended source.
repo_url=${GITOPS_REPO_URL:-git@github.com:hashirsarwar/cronus-gitops.git}

# Use an independent read-only deploy key so either cluster's access can be revoked separately.
# Never commit the private key.
deploy_key_file=${DEPLOY_KEY_FILE:-$HOME/.ssh/cronus_gitops_prod_deploy}

command -v az >/dev/null 2>&1 || {
  echo "install: az is required and is not on PATH" >&2
  exit 1
}

# Choose stat flags by platform: GNU stat -f returns filesystem data rather than failing like an unsupported flag.
case $(uname -s) in
  Darwin | *BSD) file_mode() { stat -f '%Lp' "$1"; } ;;
  *) file_mode() { stat -c '%a' "$1"; } ;;
esac

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# Azure CLI success describes the run-command operation, not the remote command.
# Require Succeeded and an explicit zero exitCode; capture stderr so pre-cluster failures remain diagnosable.
# Parse modelled fields, not CLI prose that may change between releases.
run_remote() {
  local command=$1
  shift

  local args=()
  local file
  for file in "$@"; do
    args+=(--file "$file")
  done

  local stderr_file
  stderr_file=$(mktemp -t cronus-run-command.XXXXXX)

  local output
  if ! output=$(az aks command invoke \
        --resource-group "$resource_group" \
        --name "$cluster_name" \
        --command "$command" \
        ${args[@]+"${args[@]}"} \
        --query '[provisioningState, exitCode, logs]' --output tsv 2>"$stderr_file"); then
    echo "install: the run command could not be sent to $cluster_name" >&2
    sed 's/^/    /' "$stderr_file" >&2
    rm -f "$stderr_file"
    return 1
  fi
  rm -f "$stderr_file"

  # Positional, one value per line, in the order asked for. A field with no value is an empty line, which is
  # why the state is read first and the logs are whatever follows the second newline.
  local state exit_code logs
  state=${output%%$'\n'*}
  output=${output#*$'\n'}
  exit_code=${output%%$'\n'*}
  logs=${output#*$'\n'}
  [ "$output" = "$exit_code" ] && logs=""

  if [ "$state" != "Succeeded" ]; then
    echo "install: the run command itself did not succeed (provisioning state '$state'):" >&2
    if [ -n "$logs" ]; then printf '%s\n' "$logs" | sed 's/^/    /' >&2; fi
    return 1
  fi

  if [ -z "$exit_code" ]; then
    echo "install: the run command reported no exit code, so it is not known to have succeeded:" >&2
    if [ -n "$logs" ]; then printf '%s\n' "$logs" | sed 's/^/    /' >&2; fi
    return 1
  fi

  if [ "$exit_code" != "0" ]; then
    echo "install: the command inside the cluster exited $exit_code:" >&2
    if [ -n "$logs" ]; then printf '%s\n' "$logs" | sed 's/^/    /' >&2; fi
    return 1
  fi
}

# AKS flattens attachments to basenames; upload only the manifest being applied, never the whole directory.
apply_manifest() {
  local manifest=$1
  # Use the uploaded basename for execution; the display label keeps temporary Secret filenames out of messages.
  local display=${2:-$(basename "$manifest")}
  run_remote "kubectl apply -f $(basename "$manifest")" "$manifest" || {
    echo "install: could not apply $display" >&2
    exit 1
  }
  echo "    applied $display"
}

echo "==> Cluster"
# Fail early if the signed-in subscription cannot resolve the intended production cluster.
az aks show --resource-group "$resource_group" --name "$cluster_name" \
  --query '{cluster:name, version:currentKubernetesVersion, private:apiServerAccessProfile.enablePrivateCluster}' \
  --output table

echo "==> Argo CD $chart_version"
# Keep repository setup and Helm installation in one remote pod; attach only the values file.
# Without --wait, verify controllers below and check the remote exit code rather than Azure operation success.
run_remote \
  "helm repo add argo https://argoproj.github.io/argo-helm --force-update && \
   helm repo update argo && \
   helm upgrade --install argocd argo/argo-cd \
     --version $chart_version \
     --namespace $namespace \
     --create-namespace \
     --values $(basename "$here/values.yaml")" \
  "$here/values.yaml" ||
  {
    echo "install: the Argo CD Helm release failed" >&2
    exit 1
  }

echo "==> Deploy key"
if [ -f "$deploy_key_file" ]; then
  # The key crosses the AKS run-command service as a Secret file; request-body retention is undocumented.
  # Never embed it in the command string, and reject group/world-readable input files.
  # See README.md for deploy-key rotation if this trust boundary is unacceptable.
  key_mode=$(file_mode "$deploy_key_file")
  case "$key_mode" in
    # Reject group/other permissions while accepting owner-only modes such as 400 or 600.
    *00) ;;
    *)
      echo "install: $deploy_key_file has mode $key_mode, so accounts other than yours can read it." >&2
      echo "install: run 'chmod 600 $deploy_key_file' and try again." >&2
      exit 1
      ;;
  esac

  # Create the Secret manifest with owner-only permissions and delete it after upload.
  # The trap removes private-key material on failure or interruption too.
  secret_manifest=$(mktemp -t cronus-gitops-repo.XXXXXX)
  chmod 600 "$secret_manifest"
  trap 'rm -f "$secret_manifest"' EXIT INT TERM

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
  } >"$secret_manifest"

  apply_manifest "$secret_manifest" "the repository Secret"
  rm -f "$secret_manifest"
  trap - EXIT INT TERM


  run_remote "kubectl -n $namespace get secret cronus-gitops-repo" ||
    {
      echo "install: the repository Secret was not created" >&2
      exit 1
    }

  echo "    from $deploy_key_file"
else
  # Keep the controllers installed if the deploy key is missing; Applications will report source authentication failures.
  echo "    no key at $deploy_key_file, so nothing was applied" >&2
  echo "    Argo CD will not be able to read the repository until one exists; see README.md" >&2
fi

echo "==> AppProject"
# Create the project first so generated Applications can pass project authorization.
apply_manifest "$here/appproject.yaml"


echo "==> Environments ApplicationSet"
apply_manifest "$here/application-sets/environments.yaml"

echo "==> Platform ApplicationSet"
# Keep the platform set independent of workloads; its retry covers the Gateway namespace dependency.
apply_manifest "$here/application-sets/platform.yaml"

echo "==> Workloads ApplicationSet"
# Retry workload syncs until the separately reconciled foundation creates their ServiceAccounts.
apply_manifest "$here/application-sets/workloads.yaml"

echo "==> Verifying"
# Verify controller rollouts after the non-waiting Helm install.
# Use workload kinds: completed one-shot Job pods never become Ready.
run_remote "kubectl -n $namespace rollout status \
  deployment/argocd-server \
  deployment/argocd-repo-server \
  deployment/argocd-applicationset-controller \
  deployment/argocd-redis \
  statefulset/argocd-application-controller \
  --timeout=120s" ||
  { echo "install: the Argo CD workloads did not roll out" >&2; exit 1; }
# Known issue: chart 10.9.6 expires this Job 60s after completion.
# A later wait can fail after successful initialization; see README.md before treating absence as failure.
run_remote "kubectl -n $namespace wait --for=condition=complete job/argocd-redis-secret-init --timeout=120s" ||
  { echo "install: the Redis password Job did not complete" >&2; exit 1; }
run_remote "kubectl -n $namespace get appproject cronus-prod" ||
  { echo "install: the AppProject was not created" >&2; exit 1; }
run_remote "kubectl -n $namespace get applicationset cronus-prod-environments cronus-prod-platform cronus-prod-workloads" ||
  { echo "install: the ApplicationSets were not created" >&2; exit 1; }
echo "    Argo CD is serving, and the AppProject and all three ApplicationSets are present"

echo
echo "install: done"
echo
echo "This cluster's API server is private, so there is no port-forward and no UI from here. Read the"
echo "Applications the same way this script applied them:"
echo "    az aks command invoke -g $resource_group -n $cluster_name \\"
echo "      --command \"kubectl -n $namespace get applications\""
echo
echo "The environment Application creates the namespace and the ServiceAccounts the workloads need, so sync"
echo "it first and confirm it is healthy before expecting the workloads to. See README.md for the sequence."
echo
echo "The platform Application creates cronus-gateway and the Gateway, which is what asks Azure for a"
echo "public address. It appears as a LoadBalancer Service in that namespace a minute or two later:"
echo "    $ az aks command invoke -g $resource_group -n $cluster_name \\"
echo "        --command \"kubectl -n cronus-gateway get gateway,service\""
echo "That address answers on port 80 only once the production node subnet's network security group admits"
echo "it; environments/prod in cronus-infrastructure records the rule, and without it the address is"
echo "reachable from nowhere."
echo
echo "The three workload Applications will not sync until their image tags are set in"
echo "charts/*/values-prod.yaml. That is a prerequisite rather than a failure: no image has been published"
echo "to acrcronusprod yet."
