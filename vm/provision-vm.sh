#!/bin/bash
# Provision the geogram-dev VM via serial console + SSH.
set -euo pipefail

VM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="$VM_DIR/geogram-dev.qcow2"
PIPE_IN="$VM_DIR/.pipe_in"
LOG="$VM_DIR/.serial.log"
TMPKEY="$VM_DIR/.tmpkey"

cleanup() {
    exec 3>&- 2>/dev/null || true
    pkill -f "qemu-system.*geogram-dev" 2>/dev/null || true
    rm -f "$PIPE_IN" "$TMPKEY" "$TMPKEY.pub"
}
trap cleanup EXIT

# Temp SSH key
rm -f "$TMPKEY" "$TMPKEY.pub"
ssh-keygen -t ed25519 -f "$TMPKEY" -N "" -q
PUBKEY=$(cat "$TMPKEY.pub")

# Fresh disk
echo "[1/4] Preparing VM disk..."
cp "$VM_DIR/debian-12-nocloud-amd64.qcow2" "$IMAGE"
qemu-img resize "$IMAGE" 30G

rm -f "$PIPE_IN" "$LOG"
mkfifo "$PIPE_IN"

ACCEL="-cpu qemu64 -accel tcg"
[ -w /dev/kvm ] && ACCEL="-cpu host -enable-kvm"

echo "[2/4] Booting VM..."
qemu-system-x86_64 \
    -m 4G -smp 4 $ACCEL \
    -drive "file=$IMAGE,format=qcow2,if=virtio" \
    -netdev "user,id=net0,hostfwd=tcp::2222-:22" \
    -device virtio-net-pci,netdev=net0 \
    -nographic \
    < "$PIPE_IN" > "$LOG" 2>&1 &
QEMU_PID=$!
exec 3>"$PIPE_IN"

wait_for() {
    local pattern="$1" timeout="${2:-120}" elapsed=0
    while [ $elapsed -lt $timeout ]; do
        grep -q "$pattern" "$LOG" 2>/dev/null && return 0
        sleep 5; elapsed=$((elapsed + 5))
        (( elapsed % 30 == 0 )) && echo "  ... ${elapsed}s"
    done
    echo "TIMEOUT ($pattern)"; return 1
}

echo "[3/4] Waiting for boot..."
wait_for "login:" 300

echo "Logging in..."
printf '\r\nroot\r\n' >&3
sleep 8

if ! wait_for "root@" 30; then
    echo "Login failed"; tail -10 "$LOG"; exit 1
fi

echo "Setting up SSH (single script via serial)..."

# Write a setup script to the VM filesystem via serial, then execute it.
# This avoids all timing issues — we write the file first, then run it.
printf 'cat > /tmp/setup.sh << '"'"'SETUPEOF'"'"'\r\n' >&3
sleep 1
printf 'export DEBIAN_FRONTEND=noninteractive\r\n' >&3
# Install growpart and resize the GPT partition + filesystem
printf 'apt-get update -qq && apt-get install -y -qq cloud-guest-utils\r\n' >&3
printf 'growpart /dev/vda 1\r\n' >&3
printf 'resize2fs /dev/vda1\r\n' >&3
printf 'apt-get update -qq\r\n' >&3
printf 'apt-get install -y -qq openssh-server sudo\r\n' >&3
printf 'useradd -m -s /bin/bash dev 2>/dev/null\r\n' >&3
printf 'usermod -aG sudo dev 2>/dev/null\r\n' >&3
printf 'echo "dev:dev" | chpasswd\r\n' >&3
printf 'echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev\r\n' >&3
printf 'mkdir -p /home/dev/.ssh\r\n' >&3
printf 'chmod 700 /home/dev/.ssh\r\n' >&3
printf "echo '%s' > /home/dev/.ssh/authorized_keys\r\n" "$PUBKEY" >&3
printf 'chmod 600 /home/dev/.ssh/authorized_keys\r\n' >&3
printf 'chown -R dev:dev /home/dev/.ssh\r\n' >&3
printf 'sed -i "s/#PasswordAuthentication .*/PasswordAuthentication yes/" /etc/ssh/sshd_config\r\n' >&3
printf 'systemctl enable ssh\r\n' >&3
printf 'systemctl restart ssh\r\n' >&3
printf 'echo SERIAL_ALL_DONE\r\n' >&3
printf 'SETUPEOF\r\n' >&3
sleep 2
printf 'bash /tmp/setup.sh\r\n' >&3

echo "Waiting for SSH setup to complete..."
wait_for "SERIAL_ALL_DONE" 600

echo "[4/4] SSH ready — provisioning over SSH..."
SSH="ssh -i $TMPKEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -p 2222 dev@localhost"
SCP="scp -i $TMPKEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P 2222"

connected=false
for i in $(seq 1 20); do
    if $SSH "echo SSH_OK" 2>/dev/null; then
        echo "SSH connected!"
        connected=true
        break
    fi
    echo "  ... SSH attempt $i"; sleep 3
done

if ! $connected; then
    echo "SSH failed"; tail -30 "$LOG"; exit 1
fi

# Upload and run full provision script
$SCP "$VM_DIR/.provision.sh" dev@localhost:/tmp/provision.sh 2>/dev/null
$SSH "sudo bash /tmp/provision.sh" 2>&1 | while IFS= read -r line; do echo "  [vm] $line"; done

echo "Shutting down..."
$SSH "sudo poweroff" 2>/dev/null || true
wait $QEMU_PID 2>/dev/null || true
exec 3>&-

rm -f "$LOG" "$TMPKEY" "$TMPKEY.pub" "$PIPE_IN"

echo ""
echo "=== VM image ready: $IMAGE ==="
echo "Start: ./vm/start.sh | SSH: ssh dev@localhost -p 2222 (pass: dev)"
