#!/usr/bin/env bash
# Poll the cluster's Kubernetes API until enough nodes matching a label selector
# have registered (they need not be Ready). Used to gate a CNI Helm install (e.g.
# kube-ovn) that requires nodes to exist before it can bootstrap. All inputs come
# from the environment; writes an isolated temp kubeconfig so it never clobbers
# the caller's.
set -euo pipefail

: "${CLUSTER_NAME:?CLUSTER_NAME is required}"
: "${REGION:?REGION is required}"
SELECTOR="${SELECTOR:-}"
COUNT="${COUNT:-1}"
TIMEOUT="${TIMEOUT:-600}"

kubeconfig="$(mktemp)"
trap 'rm -f "$kubeconfig"' EXIT
export KUBECONFIG="$kubeconfig"

aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" --kubeconfig "$kubeconfig" >/dev/null

selector_args=()
[ -n "$SELECTOR" ] && selector_args=(-l "$SELECTOR")

label_desc="${SELECTOR:-<any>}"
deadline=$(( $(date +%s) + TIMEOUT ))

while :; do
  n="$(kubectl get nodes "${selector_args[@]}" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')"
  n="${n:-0}"
  if [ "$n" -ge "$COUNT" ]; then
    echo "cni-bootstrap: found $n node(s) matching '$label_desc' (needed $COUNT)"
    exit 0
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "cni-bootstrap: timed out after ${TIMEOUT}s waiting for $COUNT node(s) matching '$label_desc' (found $n)" >&2
    exit 1
  fi
  echo "cni-bootstrap: waiting for $COUNT node(s) matching '$label_desc' (found $n)..."
  sleep 10
done
