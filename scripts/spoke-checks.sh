#!/usr/bin/env bash
# Spoke communication checks for docs/hub-spoke-cert-rotation.md.
#
# Usage: ./spoke-checks.sh [log-window]
#   log-window: how far back to scan klusterlet logs for TLS errors (default 15m)
#
# Requires HUB_KUBECONFIG, SPOKE_KUBECONFIG and SPOKE_NAME, and
# hub-spoke-helpers.sh in the same directory. Exits non-zero if any check fails.

set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=hub-spoke-helpers.sh
source "$here/hub-spoke-helpers.sh" >/dev/null

since="${1:-15m}"
failures=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
spoke() { oc --kubeconfig "$SPOKE_KUBECONFIG" "$@"; }

served_issuer="$(hub_served_cert -issuer | sed 's/^issuer=//')"
echo "Hub serves: issuer=$served_issuer $(hub_served_cert -serial)"
echo

# 1. The hub sees the spoke as available.
if oc wait managedcluster "$SPOKE_NAME" \
    --for=condition=ManagedClusterConditionAvailable=True --timeout=10m >/dev/null; then
  pass "1 ManagedCluster $SPOKE_NAME is AVAILABLE"
else
  fail "1 ManagedCluster $SPOKE_NAME is not AVAILABLE after 10m"
fi

# 2. The spoke keeps renewing its lease (about once a minute).
lease() { oc -n "$SPOKE_NAME" get lease managed-cluster-lease -o jsonpath='{.spec.renewTime}'; }
before="$(lease)"
sleep 75
after="$(lease)"
if [ -n "$after" ] && [ "$before" != "$after" ]; then
  pass "2 lease renewed ($before -> $after)"
else
  fail "2 lease not renewed within 75s (renewTime $after)"
fi

# 3. Every add-on is available.
addons="$(oc -n "$SPOKE_NAME" get managedclusteraddons \
  -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="Available")].status}{"\n"}{end}')"
not_ready="$(echo "$addons" | grep -v '=True$' | grep -v '^$' | tr '\n' ' ')"
if [ -n "$addons" ] && [ -z "$not_ready" ]; then
  pass "3 all $(echo "$addons" | grep -c .) add-ons available"
else
  fail "3 add-ons not available: $not_ready"
fi

# 4. The hub can deliver new work: a ManifestWork creates a ConfigMap on the spoke.
probe_id="$(date +%s)"
oc apply -f - >/dev/null <<EOF
apiVersion: work.open-cluster-management.io/v1
kind: ManifestWork
metadata:
  name: cert-rotation-probe
  namespace: ${SPOKE_NAME}
spec:
  workload:
    manifests:
    - apiVersion: v1
      kind: ConfigMap
      metadata:
        name: cert-rotation-probe
        namespace: default
      data:
        probe: "${probe_id}"
EOF
if oc -n "$SPOKE_NAME" wait manifestwork/cert-rotation-probe --for=condition=Available --timeout=5m >/dev/null; then
  got="$(spoke -n default get configmap cert-rotation-probe -o jsonpath='{.data.probe}')"
  if [ "$got" = "$probe_id" ]; then
    pass "4 ManifestWork round trip (probe $probe_id)"
  else
    fail "4 ManifestWork applied but the spoke ConfigMap holds '$got', expected $probe_id"
  fi
else
  fail "4 ManifestWork probe not Available within 5m"
fi
oc -n "$SPOKE_NAME" delete manifestwork cert-rotation-probe >/dev/null

# 5. No TLS verification errors in any klusterlet pod. Check every pod:
# oc logs deploy/... reads only one replica.
tls_errors=0
for pod in $(spoke -n open-cluster-management-agent get pod -o name); do
  n="$(spoke -n open-cluster-management-agent logs "$pod" --all-containers --since="$since" \
    | grep -ciE 'x509|unknown authority')"
  if [ "$n" -gt 0 ]; then
    echo "      $pod: $n TLS errors"
    tls_errors=$((tls_errors + n))
  fi
done
if [ "$tls_errors" -eq 0 ]; then
  pass "5 no x509 errors in klusterlet logs (last $since)"
else
  fail "5 $tls_errors x509 errors in klusterlet logs (last $since)"
fi

# 6. The spoke's bootstrap kubeconfig matches what the hub sends, and trusts
# the issuer of the certificate the hub serves.
spoke_subjects="$(spoke_bootstrap_ca | pem_subjects)"
hub_subjects="$(hub_bootstrap_ca | pem_subjects)"
echo "$spoke_subjects" | while read -r line; do echo "      spoke trusts: $line"; done
if [ "$spoke_subjects" != "$hub_subjects" ]; then
  fail "6 spoke bootstrap CA differs from the hub's klusterlet ManifestWork"
elif ! echo "$spoke_subjects" | grep -qxF "subject=$served_issuer"; then
  fail "6 spoke bootstrap CA does not include the served issuer ($served_issuer)"
else
  pass "6 spoke bootstrap CA matches the hub and trusts the served issuer"
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "All checks passed."
else
  echo "$failures check(s) failed. See Troubleshooting in the guide."
  exit 1
fi
