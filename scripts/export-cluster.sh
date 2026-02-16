#!/usr/bin/env bash
#
# export-cluster.sh - Export clean YAMLs from a running Kubernetes cluster
#
# Usage: KUBECONFIG=<cluster>/kubeconfig bash scripts/export-cluster.sh <cluster-dir>
#
# Exports deployments, services, ingresses, and secret templates for all active
# app deployments. Also exports Helm values for infrastructure components.
#
set -euo pipefail

CLUSTER_DIR="${1:?Usage: export-cluster.sh <cluster-dir>}"

# Namespaces/deployments to skip (infrastructure, test, legacy)
SKIP_NAMESPACES="kube-system|cert-manager|nats|temporal|tailscale|ingress-nginx"
SKIP_DEPLOYMENTS="redis"

echo "=== Exporting cluster to ${CLUSTER_DIR}/ ==="
echo "Using KUBECONFIG=${KUBECONFIG:-default}"
echo ""

# ─── Helper: strip managed/runtime fields from a resource ───
clean_resource() {
    jq 'del(
        .metadata.managedFields,
        .metadata.resourceVersion,
        .metadata.uid,
        .metadata.creationTimestamp,
        .metadata.generation,
        .metadata.selfLink,
        .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"],
        .metadata.annotations["deployment.kubernetes.io/revision"],
        .metadata.annotations["field.cattle.io/publicEndpoints"],
        .status
    ) |
    # Remove empty annotations object if we cleared everything
    if .metadata.annotations == {} then del(.metadata.annotations) else . end'
}

# ─── Helper: convert JSON to clean YAML (uses yq) ───
to_yaml() {
    yq -P -o yaml
}

# ─── Helper: create a secret template from a real secret (reads JSON from stdin) ───
secret_to_template() {
    jq '
        del(
            .metadata.managedFields,
            .metadata.resourceVersion,
            .metadata.uid,
            .metadata.creationTimestamp,
            .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"]
        ) |
        .data = (.data | to_entries | map({key: .key, value: "FIXME"}) | from_entries)
    '
}

# ─── Export infrastructure Helm values ───
echo "--- Exporting infrastructure Helm values ---"

# cert-manager
if kubectl get clusterissuer letsencrypt-prod &>/dev/null; then
    echo "  Exporting ClusterIssuer..."
    kubectl get clusterissuer letsencrypt-prod -o json | clean_resource | to_yaml > "${CLUSTER_DIR}/infra/cert-manager/cluster-issuer.yaml"
fi

# Get cert-manager helm values
if helm status cert-manager -n cert-manager &>/dev/null; then
    echo "  Exporting cert-manager Helm values..."
    helm get values cert-manager -n cert-manager -o yaml > "${CLUSTER_DIR}/infra/cert-manager/helm-values.yaml"
fi

# NATS
if helm status nats -n nats &>/dev/null; then
    echo "  Exporting NATS Helm values..."
    helm get values nats -n nats -o yaml > "${CLUSTER_DIR}/infra/nats/helm-values.yaml"
fi

# Temporal
if helm status temporal -n temporal &>/dev/null; then
    echo "  Exporting Temporal Helm values..."
    helm get values temporal -n temporal -o yaml > "${CLUSTER_DIR}/infra/temporal/helm-values.yaml"
fi

# Tailscale
if helm status tailscale-operator -n tailscale &>/dev/null; then
    echo "  Exporting Tailscale Helm values..."
    helm get values tailscale-operator -n tailscale -o yaml > "${CLUSTER_DIR}/infra/tailscale/helm-values.yaml"
fi

echo ""

# ─── Export regcred (Docker registry credential) ───
if kubectl get secret regcred -n default &>/dev/null; then
    echo "--- Exporting regcred template ---"
    kubectl get secret regcred -n default -o json | secret_to_template | to_yaml > "${CLUSTER_DIR}/apps/regcred.yaml.tmpl"
fi

# ─── Build a map of app-name -> deployments ───
echo "--- Discovering deployments ---"

# Get all deployments across all namespaces, excluding infra
ALL_DEPLOYMENTS=$(kubectl get deployments -A -o json | jq -r "
    .items[] |
    select(
        (.metadata.namespace | test(\"${SKIP_NAMESPACES}\") | not) and
        (.metadata.name | test(\"${SKIP_DEPLOYMENTS}\") | not)
    ) |
    [.metadata.namespace, .metadata.name] | @tsv
")

echo "$ALL_DEPLOYMENTS" | while IFS=$'\t' read -r ns deploy_name; do
    [ -z "$ns" ] && continue

    # Determine app directory name from deployment name
    # Strip common suffixes to group related deployments
    app_dir="$deploy_name"
    for suffix in -backend -frontend -server -workers -worker -api -treq-worker; do
        stripped="${deploy_name%${suffix}}"
        if [ "$stripped" != "$deploy_name" ]; then
            app_dir="$stripped"
            break
        fi
    done

    # Create app directory if needed
    app_path="${CLUSTER_DIR}/apps/${app_dir}"
    mkdir -p "$app_path"

    echo "  Exporting deployment: ${ns}/${deploy_name} -> apps/${app_dir}/"

    # Export deployment
    kubectl get deployment "$deploy_name" -n "$ns" -o json | clean_resource | to_yaml \
        > "${app_path}/deployment-${deploy_name##*-}.yaml"

    # If the deployment name doesn't have a suffix, just call it deployment.yaml
    if [ "$app_dir" = "$deploy_name" ]; then
        mv "${app_path}/deployment-${deploy_name##*-}.yaml" "${app_path}/deployment.yaml"
    fi

    # Export associated service (try exact name match first, then app label)
    if kubectl get svc "$deploy_name" -n "$ns" &>/dev/null; then
        kubectl get svc "$deploy_name" -n "$ns" -o json | clean_resource | to_yaml \
            > "${app_path}/service-${deploy_name##*-}.yaml"
        if [ "$app_dir" = "$deploy_name" ]; then
            mv "${app_path}/service-${deploy_name##*-}.yaml" "${app_path}/service.yaml"
        fi
    fi

    # Export associated ingress (try exact name match)
    if kubectl get ingress "$deploy_name" -n "$ns" &>/dev/null; then
        kubectl get ingress "$deploy_name" -n "$ns" -o json | clean_resource | to_yaml \
            > "${app_path}/ingress-${deploy_name##*-}.yaml"
        if [ "$app_dir" = "$deploy_name" ]; then
            mv "${app_path}/ingress-${deploy_name##*-}.yaml" "${app_path}/ingress.yaml"
        fi
    # Also try app_dir name for ingress
    elif [ "$app_dir" != "$deploy_name" ] && kubectl get ingress "$app_dir" -n "$ns" &>/dev/null; then
        if [ ! -f "${app_path}/ingress.yaml" ]; then
            kubectl get ingress "$app_dir" -n "$ns" -o json | clean_resource | to_yaml \
                > "${app_path}/ingress.yaml"
        fi
    fi

    # Export referenced secrets (from envFrom and env valueFrom)
    secret_names=$(kubectl get deployment "$deploy_name" -n "$ns" -o json | jq -r '
        [
            .spec.template.spec.containers[].envFrom[]?.secretRef.name,
            .spec.template.spec.containers[].env[]?.valueFrom?.secretKeyRef?.name
        ] | map(select(. != null)) | unique | .[]
    ' 2>/dev/null || true)

    for secret_name in $secret_names; do
        [ -z "$secret_name" ] && continue
        [ "$secret_name" = "regcred" ] && continue  # Already exported separately
        if kubectl get secret "$secret_name" -n "$ns" &>/dev/null; then
            tmpl_file="${app_path}/secret-${secret_name}.yaml.tmpl"
            if [ ! -f "$tmpl_file" ]; then
                echo "    Secret template: ${secret_name}"
                kubectl get secret "$secret_name" -n "$ns" -o json | secret_to_template | to_yaml \
                    > "$tmpl_file"
            fi
        fi
    done

done

echo ""

# ─── Export any ingresses not yet captured ───
echo "--- Checking for standalone ingresses ---"
kubectl get ingress -A -o json | jq -r '
    .items[] |
    select(.metadata.namespace | test("'"${SKIP_NAMESPACES}"'") | not) |
    [.metadata.namespace, .metadata.name] | @tsv
' | while IFS=$'\t' read -r ns ingress_name; do
    [ -z "$ns" ] && continue

    # Determine app directory
    app_dir="$ingress_name"
    for suffix in -backend -frontend -server -api; do
        stripped="${ingress_name%${suffix}}"
        if [ "$stripped" != "$ingress_name" ]; then
            app_dir="$stripped"
            break
        fi
    done

    app_path="${CLUSTER_DIR}/apps/${app_dir}"
    if [ -d "$app_path" ] && ! ls "${app_path}"/ingress*.yaml &>/dev/null; then
        echo "  Standalone ingress: ${ns}/${ingress_name} -> apps/${app_dir}/"
        mkdir -p "$app_path"
        kubectl get ingress "$ingress_name" -n "$ns" -o json | clean_resource | to_yaml \
            > "${app_path}/ingress.yaml"
    fi
done

echo ""
echo "=== Export complete ==="
echo "Review files in ${CLUSTER_DIR}/ and clean up as needed."
