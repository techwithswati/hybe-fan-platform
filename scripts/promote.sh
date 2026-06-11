#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║   HYBE Fan Platform — GitOps Image Promotion Script                          ║
# ║                                                                              ║
# ║   Called by GitHub Actions CI after a successful Docker build + ECR push.    ║
# ║   Updates the image tags in helm/values.yaml → commits → pushes to Git.      ║
# ║   ArgoCD detects the drift and syncs EKS automatically (pull-based).         ║
# ║                                                                              ║
# ║   Usage:                                                                     ║
# ║     ./scripts/promote.sh <new-image-tag>                                     ║
# ║     ./scripts/promote.sh 20250420-a1b2c3d                                    ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

# ── Validation ─────────────────────────────────────────────────────────────────
NEW_TAG="${1:-}"
VALUES_FILE="helm/hybe-platform/values.yaml"

if [[ -z "${NEW_TAG}" ]]; then
  echo "ERROR: Usage: $0 <new-image-tag>"
  echo "       Example: $0 20250420-a1b2c3d"
  exit 1
fi

if [[ ! -f "${VALUES_FILE}" ]]; then
  echo "ERROR: ${VALUES_FILE} not found. Run from repo root."
  exit 1
fi

echo "🚀 Promoting image tag: ${NEW_TAG}"
echo "   File: ${VALUES_FILE}"

# ── Show current tags ─────────────────────────────────────────────────────────
echo ""
echo "Current tags:"
grep -E "^\s+tag:" "${VALUES_FILE}" | head -5

# ── Update image tags using sed ───────────────────────────────────────────────
# This is the KEY GitOps action: updating values.yaml is what triggers ArgoCD.
#
# Strategy: Replace ALL service image tags (ticket, merch, api-gateway) to keep
# them in lockstep. In a mono-repo approach, all services share the same version.

OS_TYPE=$(uname -s)

if [[ "${OS_TYPE}" == "Darwin" ]]; then
  # macOS: BSD sed requires -i ''
  SED_CMD="sed -i ''"
else
  # Linux: GNU sed
  SED_CMD="sed -i"
fi

# Update ticketService image tag
${SED_CMD} "/ticketService:/,/tag:/{
  s/tag: .*/tag: \"${NEW_TAG}\"/
}" "${VALUES_FILE}"

# Update merchService image tag
${SED_CMD} "/merchService:/,/tag:/{
  s/tag: .*/tag: \"${NEW_TAG}\"/
}" "${VALUES_FILE}"

# Update apiGateway image tag
${SED_CMD} "/apiGateway:/,/tag:/{
  s/tag: .*/tag: \"${NEW_TAG}\"/
}" "${VALUES_FILE}"

# ── Verify changes ─────────────────────────────────────────────────────────
echo ""
echo "Updated tags:"
grep -E "^\s+tag:" "${VALUES_FILE}" | head -5

# Confirm all 3 services were updated
TAG_COUNT=$(grep -c "tag: \"${NEW_TAG}\"" "${VALUES_FILE}" || true)
if [[ "${TAG_COUNT}" -lt 3 ]]; then
  echo "ERROR: Expected 3 tag updates, found ${TAG_COUNT}. Check values.yaml structure."
  exit 1
fi

echo ""
echo "✅ Promotion complete: ${TAG_COUNT} services updated to ${NEW_TAG}"
echo "   ArgoCD will detect drift and sync EKS within ~3 minutes."
echo "   Watch: argocd app get hybe-fan-platform"
