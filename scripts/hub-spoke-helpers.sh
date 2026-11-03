# Helpers for docs/hub-spoke-cert-rotation.md. Source this file; do not run it.
# Requires HUB_KUBECONFIG, SPOKE_KUBECONFIG and SPOKE_NAME to be set.

: "${HUB_KUBECONFIG:?set HUB_KUBECONFIG}" "${SPOKE_KUBECONFIG:?set SPOKE_KUBECONFIG}" "${SPOKE_NAME:?set SPOKE_NAME}"

export KUBECONFIG="$HUB_KUBECONFIG"
HUB_API_HOST="$(oc whoami --show-server | sed -E 's#https://([^:/]+).*#\1#')"
export HUB_API_HOST

# Print fields of the certificate the hub API serves right now,
# for example: hub_served_cert -issuer -serial
hub_served_cert() {
  echo | openssl s_client -connect "$HUB_API_HOST:6443" -servername "$HUB_API_HOST" 2>/dev/null \
    | openssl x509 -noout "$@"
}

# Wait (every 20s, up to 30 minutes) until the served certificate's issuer or
# serial contains the given text. Works while the API is restarting.
wait_for_served_cert() {
  for _ in $(seq 1 90); do
    if hub_served_cert -issuer -serial 2>/dev/null | grep -qiF "$1"; then
      hub_served_cert -subject -issuer -serial -enddate
      return 0
    fi
    sleep 20
  done
  echo "timed out waiting for served certificate matching: $1" >&2
  return 1
}

# Print the subject of every certificate in a PEM bundle on stdin.
pem_subjects() {
  openssl crl2pkcs7 -nocrl -certfile /dev/stdin | openssl pkcs7 -print_certs -noout | grep subject
}

# CA bundle in the bootstrap kubeconfig the hub sends to the spoke.
hub_bootstrap_ca() {
  oc -n "$SPOKE_NAME" get manifestwork "$SPOKE_NAME-klusterlet" \
    -o jsonpath='{.spec.workload.manifests[?(@.metadata.name=="bootstrap-hub-kubeconfig")].data.kubeconfig}' \
    | base64 -d | awk '/certificate-authority-data/ {print $2}' | base64 -d
}

# CA bundle in the bootstrap kubeconfig the spoke actually has.
spoke_bootstrap_ca() {
  oc --kubeconfig "$SPOKE_KUBECONFIG" -n open-cluster-management-agent \
    get secret bootstrap-hub-kubeconfig -o jsonpath='{.data.kubeconfig}' \
    | base64 -d | awk '/certificate-authority-data/ {print $2}' | base64 -d
}

# Serial of the certificate cert-manager last issued for the hub API.
issued_serial() {
  oc -n openshift-config get secret hub-api-cert -o jsonpath='{.data.tls\.crt}' \
    | base64 -d | openssl x509 -noout -serial | cut -d= -f2
}

echo "Hub API: $HUB_API_HOST"
oc get managedcluster "$SPOKE_NAME"
