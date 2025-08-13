#!/usr/bin/env bash
set -euo pipefail

# --- CI no-GPU smoke test for your Ansible Runner project ---
# What it does:
#   1) Creates a fake CUDA .run installer that only drops a mock 'nvcc' (release 13.0)
#   2) Writes env/extravars to skip GPU-only parts and run CUDA toolkit offline
#   3) Generates a temporary playbook 'site.ci_no_gpu.yml' (toolkit [+ cudnn optional] + verify)
#   4) Runs ansible-runner twice (run01, run02) and checks idempotence (changed=0 on 2nd run)
#
# Usage:
#   ./ci_no_gpu_smoketest.sh [--runner-dir PATH] [--inventory PATH] [--cuda-version 13.0] [--with-cudnn]
#
# Defaults:
RUNNER_DIR="."
INVENTORY="./inventory/hosts"
CUDA_VER="13.0"
WITH_CUDNN="0"

# --- Arg parse ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runner-dir) RUNNER_DIR="$2"; shift 2;;
    --inventory)  INVENTORY="$2"; shift 2;;
    --cuda-version) CUDA_VER="$2"; shift 2;;
    --with-cudnn) WITH_CUDNN="1"; shift 1;;
    -h|--help)
      sed -n '1,30p' "$0"; exit 0;;
    *)
      echo "Unknown arg: $1" >&2; exit 2;;
  esac
done

# --- Paths ---
PDD="$RUNNER_DIR"             # private_data_dir
PROJECT="$PDD/project"
EXTRAVARS="$PDD/env/extravars"
CMDLINE="$PDD/env/cmdline"
ART="$PDD/artifacts"
CUDA_FILES="$PROJECT/roles/cuda_toolkit/files"
CUDNN_FILES="$PROJECT/roles/cudnn/files"

# --- Preconditions ---
[[ -x "$(command -v ansible-runner)" ]] || { echo "ERROR: ansible-runner not found in PATH"; exit 3; }
[[ -d "$PROJECT" ]] || { echo "ERROR: Not a Runner private_data_dir (missing project/): $PDD"; exit 3; }
[[ -f "$INVENTORY" ]] || { echo "ERROR: inventory not found: $INVENTORY"; exit 3; }

mkdir -p "$CUDA_FILES"
mkdir -p "$CUDNN_FILES"
mkdir -p "$PDD/env"
mkdir -p "$ART"

# --- 1) Fake CUDA runfile (creates nvcc with release $CUDA_VER) ---
RUNFILE="cuda_${CUDA_VER}_linux.run"
cat > "${CUDA_FILES}/${RUNFILE}" <<'EOF'
#!/bin/sh
set -eu
ver="__CUDA_VER__"
if printf '%s\n' "$@" | grep -q -- '--toolkit'; then
  mkdir -p "/usr/local/cuda-${ver}/bin"
  cat > "/usr/local/cuda-${ver}/bin/nvcc" <<'EONVCC'
#!/bin/sh
echo "Cuda compilation tools, release __CUDA_VER__, V__CUDA_VER__.0"
exit 0
EONVCC
  chmod +x "/usr/local/cuda-${ver}/bin/nvcc"
fi
exit 0
EOF
# patch placeholders with chosen version
sed -i "s/__CUDA_VER__/${CUDA_VER}/g" "${CUDA_FILES}/${RUNFILE}"
chmod +x "${CUDA_FILES}/${RUNFILE}"

# --- 2) env/extravars: CI no GPU, offline toolkit, disable dcgm/exporter ---
cat > "${EXTRAVARS}" <<YAML
ci_no_gpu: true
cuda_install_mode: "offline"
cuda_version_major_minor: "${CUDA_VER}"
cuda_runfile: "${RUNFILE}"
dcgm_install_mode: "none"
dcgm_exporter_mode: "none"
YAML

# Optionally add cuDNN tarball mode (fake tarball with cudnn.h and a dummy .so)
if [[ "${WITH_CUDNN}" == "1" ]]; then
  # create fake cuDNN tarball
  TMPD="$(mktemp -d)"
  mkdir -p "${TMPD}/cudnn/include" "${TMPD}/cudnn/lib"
  echo "/* fake cudnn.h for CI */" > "${TMPD}/cudnn/include/cudnn.h"
  : > "${TMPD}/cudnn/lib/libcudnn.so"
  tar -C "${TMPD}" -czf "${CUDNN_FILES}/cudnn-linux-x86_64-ci_cuda${CUDA_VER}.tgz" cudnn
  rm -rf "${TMPD}"
  cat >> "${EXTRAVARS}" <<YAML
cudnn_install_mode: "tarball"
cudnn_tarball: "roles/cudnn/files/cudnn-linux-x86_64-ci_cuda${CUDA_VER}.tgz"
YAML
  PLAY_WITH_CUDNN="true"
else
  PLAY_WITH_CUDNN="false"
fi

# --- 3) Temporary playbook that only runs what we can verify without GPU ---
PLAYBOOK="${PROJECT}/site.ci_no_gpu.yml"
{
  echo "- hosts: gpu_nodes"
  echo "  become: true"
  echo "  any_errors_fatal: true"
  echo "  roles:"
  echo "    - cuda_toolkit"
  if [[ "${PLAY_WITH_CUDNN}" == "true" ]]; then
    echo "    - cudnn"
  fi
  echo "    - verify_cuda"
} > "${PLAYBOOK}"

# clear cmdline to avoid stray --tags from previous runs
: > "${CMDLINE}"

# --- 4) Run twice and check idempotence ---
echo "===> RUN #1 (converge)"
ansible-runner run "${PDD}" -p "$(basename "${PLAYBOOK}")" --ident run01 --inventory "${INVENTORY}"
echo "===> RUN #2 (idempotence)"
ansible-runner run "${PDD}" -p "$(basename "${PLAYBOOK}")" --ident run02 --inventory "${INVENTORY}"

# --- 5) Evaluate results ---
RC1="$(cat "${ART}/run01/rc" || echo 1)"
RC2="$(cat "${ART}/run02/rc" || echo 1)"
[[ "${RC1}" == "0" && "${RC2}" == "0" ]] || { echo "ERROR: runner RC failed (run01=${RC1}, run02=${RC2})"; exit 4; }

# Sum up all 'changed=' from the final PLAY RECAP of run02
RECAP_LINE="$(grep -n 'PLAY RECAP' -n "${ART}/run02/stdout" | tail -n1 | cut -d: -f1)"
if [[ -n "${RECAP_LINE}" ]]; then
  TAIL="$(tail -n +${RECAP_LINE} "${ART}/run02/stdout")"
else
  TAIL="$(tail -n 50 "${ART}/run02/stdout")"
fi
CHANGED_SUM="$(printf "%s\n" "${TAIL}" | grep -oE 'changed=[0-9]+' | awk -F= '{s+=$2} END{print s+0}')"

echo "===> Idempotence check: changed sum on 2nd run = ${CHANGED_SUM}"
if [[ "${CHANGED_SUM}" != "0" ]]; then
  echo "ERROR: Not idempotent (changed > 0 on second run)"
  exit 5
fi

echo
echo "=== SUCCESS ==="
echo "Artifacts:"
echo "  - ${ART}/run01/{status,rc,stdout}"
echo "  - ${ART}/run02/{status,rc,stdout}"
echo
echo "Tips:"
echo "  * This used a TEMP playbook: project/$(basename "${PLAYBOOK}")"
echo "  * No need to edit site.yml or tags for this CI smoke test."
echo "  * If you prefer --tags on site.yml, add tags to roles and run normal site.yml."
