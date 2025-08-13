# gpu-setup (Ansible)

Cài NVIDIA Driver + CUDA Toolkit (online/offline), tự động chọn phiên bản theo GPU/kiến trúc:
- Tự phát hiện GPU, map sang kiến trúc/SM → chọn **toolkit major** & **nhánh driver tối thiểu** từ `vars/gpu_matrix.yml`
- Hỗ trợ **offline** CUDA runfile (`.run`) và (tuỳ bạn) local-repo cho driver
- Có bước **verify**: `nvidia-smi`, `nvcc --version`
- (Tùy chọn) **MIG** cho A100/H100/H200…

## Chuẩn bị
```bash
# Cài Galaxy role chính chủ của NVIDIA (driver)
ansible-galaxy collection install nvidia.nvidia_driver  # nếu dùng bản collection
# hoặc: ansible-galaxy install nvidia.nvidia_driver     # nếu là role (tùy cách đóng gói hiện tại)

# Sửa hosts.ini, group_vars/all.yml theo môi trường

#Bootstrap Python máy remote

# Ubuntu/Debian
ansible bare1 -i runner/inventory/hosts -b -m raw -a "apt-get update && apt-get install -y python3"
# RHEL/Rocky
ansible bare1 -i runner/inventory/hosts -b -m raw -a "dnf install -y python3"

