#!/usr/bin/env bash

set -x

killall watch
killall kubectl
k3d cluster delete
k3d cluster create

kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: kubewarden
EOF

kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.5.3/cert-manager.yaml
kubectl wait --for=condition=Available deployment --timeout=2m -n cert-manager --all
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
kubectl wait --for=condition=Available deployment --timeout=2m -n opentelemetry-operator-system --all
helm install --wait --create-namespace --namespace prometheus --values prometheus-values.yaml prometheus prometheus-community/kube-prometheus-stack
helm install --wait --namespace kubewarden kubewarden-crds helm-charts/charts/kubewarden-crds
helm install --wait --namespace kubewarden --values kubewarden-values.yaml kubewarden-controller helm-charts/charts/kubewarden-controller
kubectl apply -f - <<EOF
apiVersion: policies.kubewarden.io/v1alpha2
kind: PolicyServer
metadata:
  name: ha-policy-server
spec:
  annotations:
    sidecar.opentelemetry.io/inject: "true"
  env:
  - name: KUBEWARDEN_LOG_LEVEL
    value: info
  - name: KUBEWARDEN_LOG_FMT
    value: otlp
  - name: KUBEWARDEN_ENABLE_METRICS
    value: "1"
  image: registry.ereslibre.net/kubewarden/policy-server:latest
  replicas: 3
  serviceAccountName: policy-server
EOF
kubectl apply -f - <<EOF
apiVersion: policies.kubewarden.io/v1alpha2
kind: ClusterAdmissionPolicy
metadata:
  name: safe-labels
spec:
  policyServer: ha-policy-server
  module: registry://ghcr.io/kubewarden/policies/safe-labels:v0.1.6
  settings:
    mandatory_labels:
    - team
  rules:
    - apiGroups:
        - ""
      apiVersions:
        - v1
      resources:
        - pods
      operations:
        - CREATE
        - UPDATE
  mutating: false
EOF
kubectl wait --for=condition=PolicyActive clusteradmissionpolicy safe-labels

kubectl port-forward -n prometheus --address 0.0.0.0 svc/prometheus-operated 9090 &> /dev/null &
kubectl port-forward -n prometheus --address 0.0.0.0 svc/prometheus-grafana 8080:80 &> /dev/null &
kubectl port-forward -n kubewarden svc/policy-server-ha-policy-server 8889:8889 &> /dev/null &
kubectl port-forward -n kubewarden svc/policy-server-ha-policy-server 8443:8443 &> /dev/null &
watch -n1 curl -k -L -XPOST -d '@request-pod-multiple-containers-bad.json' -H 'Content-Type: application/json' https://localhost:8443/validate/safe-labels &> /dev/null &
watch -n0.5 curl -k -L -XPOST -d '@request-pod-multiple-containers-good.json' -H 'Content-Type: application/json' https://localhost:8443/validate/safe-labels &> /dev/null &

set +x

echo
echo
echo "Bad request:"
echo "curl -vvv -k -L -XPOST -d '@request-pod-multiple-containers-bad.json' -H 'Content-Type: application/json' https://localhost:8443/validate/safe-labels"
echo "Good request:"
echo "curl -vvv -k -L -XPOST -d '@request-pod-multiple-containers-good.json' -H 'Content-Type: application/json' https://localhost:8443/validate/safe-labels"
