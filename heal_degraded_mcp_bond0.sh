#!/usr/bin/env bash
# Author: Fatih Şölen
# Purpose: Copy ifcfg-bond0 to nodes with content mismatch annotation

set -euo pipefail

SRC_FILE="/home/kni/ifcfg-bond0"
DST_DIR="/etc/sysconfig/network-scripts/"
TMP_PATH="/tmp/ifcfg-bond0"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

RED="\033[0;31m"; GREEN="\033[0;32m"; BLUE="\033[1;34m"; NC="\033[0m"

echo -e "${BLUE}[INFO] Node annotation kontrol ediliyor...${NC}"

# Tüm nodeları oku
NODE_JSON=$(oc get nodes -o json)

# İlgili annotation’a sahip nodeları filtrele
NODES=$(echo "$NODE_JSON" | jq -r '.items[]
  | select(.metadata.annotations["machineconfiguration.openshift.io/reason"]
  | test("content mismatch for file \"/etc/sysconfig/network-scripts/ifcfg-bond0\""))
  | .metadata.name')

if [[ -z "$NODES" ]]; then
  echo -e "${GREEN}[OK] İlgili annotation’a sahip node bulunamadı.${NC}"
  exit 0
fi

for NODE in $NODES; do
  echo -e "${RED}[WARN] ${NODE} üzerinde ifcfg-bond0 content mismatch tespit edildi.${NC}"
  echo -e "${BLUE}[INFO] ${NODE} sunucusuna ifcfg-bond0 dosyası gönderiliyor...${NC}"

  # Dosyayı geçici dizine gönder
  scp $SSH_OPTS "$SRC_FILE" core@"${NODE}":/tmp/ || {
    echo -e "${RED}[ERROR] ${NODE}: SCP başarısız.${NC}"
    continue
  }

  # Root path’e taşı ve izinleri ayarla
  ssh $SSH_OPTS core@"${NODE}" "
    sudo mv $TMP_PATH ${DST_DIR} && \
    sudo chown root:root ${DST_DIR}/ifcfg-bond0 && \
    sudo chmod 600 ${DST_DIR}/ifcfg-bond0
  " && \
  echo -e "${GREEN}[OK] ${NODE}: Dosya başarıyla taşındı ve izinler ayarlandı.${NC}" || \
  echo -e "${RED}[ERROR] ${NODE}: Dosya taşıma veya izin ayarlama başarısız.${NC}"
done
