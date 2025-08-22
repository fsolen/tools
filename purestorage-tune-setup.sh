#!/bin/bash
# Fatih Solen | 22 Aug 2025
# Full setup for persistent tuning of Pure Storage FA multipath block devices on Debian 11
# purestorage-tune-setup.sh

set -euo pipefail

echo "Step 1: Creating udev rule for underlying Pure Storage sd* devices..."
sudo tee /etc/udev/rules.d/99-purestorage.rules > /dev/null <<'EOF'
# Pure Storage Best Practice: Persistent tuning on underlying sd* devices
ACTION=="add|change", KERNEL=="sd*", SUBSYSTEM=="block", ENV{ID_VENDOR}=="PURE", ATTR{queue/nr_requests}="1024", ATTR{queue/read_ahead_kb}="128", ATTR{queue/write_cache}="write through"
EOF

sudo udevadm control --reload-rules
sudo udevadm trigger --type=devices --subsystem-match=block

echo "Step 2: Creating tuning shell script..."
sudo tee /usr/local/sbin/purestorage-tune.sh > /dev/null <<'EOF'
#!/bin/bash
# Persistent tuning for Pure Storage disks and multipath devices

# Tune underlying Pure sd* devices
for sd in /sys/block/sd*; do
    [ -e "$sd/device/vendor" ] || continue
    vendor=$(cat "$sd/device/vendor")
    [ "$vendor" = "PURE" ] || continue
    echo 1024 > "$sd/queue/nr_requests"
    echo 256  > "$sd/queue/read_ahead_kb"
    echo write-through > "$sd/queue/write_cache"
done

# Wait until multipath devices are available
for i in {1..10}; do
    if ls /dev/mapper/PureStorage-* >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

# Tune multipath dm-* devices
for dm in /dev/mapper/PureStorage-*; do
    [ -e "$dm" ] || continue
    blockdev --setra 256 "$dm"
done
EOF

sudo chmod +x /usr/local/sbin/purestorage-tune.sh

echo "Step 3: Creating systemd service..."
sudo tee /etc/systemd/system/purestorage-tune.service > /dev/null <<'EOF'
[Unit]
Description=Persistent tuning for Pure Storage devices
After=multipathd.service
Wants=multipathd.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/purestorage-tune.sh

[Install]
WantedBy=multi-user.target
EOF

echo "Step 4: Enabling and starting service..."
sudo systemctl daemon-reload
sudo systemctl enable --now purestorage-tune.service

echo "Setup complete!"
