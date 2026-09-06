#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
render_dir="$(mktemp -d)"
trap 'rm -rf "$render_dir"' EXIT
make_pin() { awk -v name="$1" '$1 == "override" && $2 == name {print $4}' Makefile; }
render_chart() {
  local release="$1" chart="$2" version="$3" repository="$4"
  shift 4
  [[ -n "$version" ]] || { echo 'Missing chart version pin' >&2; return 1; }
  if [[ -n "${HELM_CHART_CACHE:-}" && -f "$HELM_CHART_CACHE/$chart-$version.tgz" ]]; then
    helm template "$release" "$HELM_CHART_CACHE/$chart-$version.tgz" "$@"
  else
    helm template "$release" "$chart" --repo "$repository" --version "$version" "$@"
  fi
}
render_chart prometheus kube-prometheus-stack "$(make_pin PROMETHEUS_CHART_VERSION)" https://prometheus-community.github.io/helm-charts --namespace monitoring --values platform/observability/prometheus/values.yaml > "$render_dir/prometheus.yaml"
render_chart kubecost kubecost "$(make_pin KUBECOST_CHART_VERSION)" https://kubecost.github.io/kubecost/ --namespace monitoring --values platform/observability/kubecost/values.yaml --set-string global.clusterId=idp-validation > "$render_dir/kubecost.yaml"
render_chart external-secrets external-secrets "$(make_pin ESO_CHART_VERSION)" https://charts.external-secrets.io --namespace external-secrets > "$render_dir/external-secrets.yaml"
render_chart reloader reloader "$(make_pin RELOADER_CHART_VERSION)" https://stakater.github.io/stakater-charts --namespace reloader --values platform/bootstrap/reloader/values.yaml > "$render_dir/reloader.yaml"
render_chart argocd argo-cd 10.1.4 https://argoproj.github.io/argo-helm --namespace argocd --values platform/gitops/argocd/install/values.yaml > "$render_dir/argocd.yaml"
render_chart aws-load-balancer-controller aws-load-balancer-controller 3.5.0 https://aws.github.io/eks-charts --namespace kube-system --set clusterName=idp-validation --set region=us-east-1 --set vpcId=vpc-0123456789abcdef0 > "$render_dir/alb-controller.yaml"
kubectl kustomize platform/observability/grafana > "$render_dir/grafana-dashboard.yaml"
python3 - "$render_dir" <<'PY'
import pathlib,sys
out = pathlib.Path(sys.argv[1])
for path in pathlib.Path('tenants').glob('**/*.yaml'):
    text = path.read_text().replace('${DATA_SUBNET_PEERS}', '[{"ipBlock":{"cidr":"10.0.20.0/24"}},{"ipBlock":{"cidr":"10.0.21.0/24"}}]').replace('${PUBLIC_SUBNET_PEERS}', '[{"ipBlock":{"cidr":"10.0.0.0/24"}},{"ipBlock":{"cidr":"10.0.1.0/24"}}]')
    (out / ('tenant-' + path.parent.name + '-' + path.name)).write_text(text)
PY
for directory in apps/*/*; do
  if [[ -f "$directory/kustomization.yaml" ]]; then
    kubectl kustomize "$directory" > "$render_dir/app-${directory//\//-}.yaml"
  fi
done
for language in nodejs-service python-fastapi; do
  node platform/validation/render-templates.js "templates/backstage/$language/skeleton" "$render_dir/$language" '{"component_id":"validation-service","owner":"identity-platform","namespace":"identity-platform","description":"Validation fixture"}'
  cp "$render_dir/$language/deployment.yaml" "$render_dir/template-$language.yaml"
  rm -r "${render_dir:?}/${language:?}"
done
if ! command -v kubeconform >/dev/null 2>&1; then
  go install github.com/yannh/kubeconform/cmd/kubeconform@v0.7.0
  tool_root="$(go env GOPATH)"
  export PATH="$tool_root/bin:$PATH"
fi
# Custom APIs use upstream locked schema tests; built-in APIs remain strict.
kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version 1.35.0 "$render_dir"
