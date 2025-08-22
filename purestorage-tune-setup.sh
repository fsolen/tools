sudo tee /etc/udev/rules.d/99-purestorage.rules >/dev/null <<'EOF'
# --- Pure sd* devices (underlying paths) ---
ACTION=="add|change", KERNEL=="sd*", SUBSYSTEM=="block", ENV{ID_VENDOR}=="PURE", ATTR{queue/nr_requests}="1024", ATTR{queue/read_ahead_kb}="128", ATTR{queue/write_cache}="write through"
# --- Multipath dm-* maps (any multipath device, no host-specific names) ---
# Match by device-mapper UUID: "mpath-..." is used for multipath maps
ACTION=="add|change", KERNEL=="dm-[0-9]*", SUBSYSTEM=="block", ENV{DM_UUID}=="mpath-*", ATTR{bdi/read_ahead_kb}="128"
# (Some kernels expose read_ahead_kb under queue/, harmless if missing)
ACTION=="add|change", KERNEL=="dm-[0-9]*", SUBSYSTEM=="block", ENV{DM_UUID}=="mpath-*", ATTR{queue/read_ahead_kb}="128"
EOF
