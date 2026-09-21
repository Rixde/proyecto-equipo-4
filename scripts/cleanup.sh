#!/usr/bin/env bash
# Desinstala Falco/Falcosidekick y limpia recursos de este proyecto.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

helm uninstall falco -n falco || true
kubectl delete namespace falco --ignore-not-found

kubectl delete namespace frontend backend database --ignore-not-found
