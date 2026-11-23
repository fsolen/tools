#!/usr/bin/env bash
#
# rbd-snap-report.sh — ODF "HighRBDCloneSnapshotCount" alarmı için salt okunur analiz.
#
# Bir RBD image'ının snapshot'larını ve clone'larını (child) listeler.
# Her kaydı Kubernetes tarafındaki karşılığıyla eşleştirir:
# PV/PVC, VirtualMachine, VolumeSnapshot/VolumeSnapshotContent.
# Ceph'te olup Kubernetes'te karşılığı olmayan kayıtları ORPHAN olarak işaretler.
# Varsayılan olarak cluster üzerinde HİÇBİR değişiklik yapmaz: yalnızca "oc get"
# ve toolbox pod'unda "rbd info/ls/snap ls/children/du" komutlarını çalıştırır.
# İSTİSNA: -X / --execute verilirse flatten planındaki image'ları tek tek
# "rbd flatten" ile flatten eder (onay, kapasite kontrolü ve log ile).
#
# Gereksinimler: oc (cluster-admin), jq, Running durumda rook-ceph-tools pod'u.

set -euo pipefail

VERSION="1.0.0"
ODF_NS="openshift-storage"
POOL=""
RADOS_NS=""
OUTPUT="text"
SCAN=0
THRESHOLD=100
TOP=20
VERBOSE=0
IMAGE=""
DEFAULT_POOL="ocs-storagecluster-cephblockpool"
ALERT_LIMIT=200
PLAN_SIZE=""
CMDS_ONLY=0
EXECUTE=0
ASSUME_YES=0
SLEEP_SECS=10
MIN_FREE_PCT=50
# ceph-csi varsayılanları (--minsnapshotsonimage / --maxsnapshotsonimage)
CSI_MIN_SNAPS="${CSI_MIN_SNAPS:-250}"
CSI_MAX_SNAPS="${CSI_MAX_SNAPS:-450}"

usage() {
  cat <<EOF
Kullanım:
  $(basename "$0") [seçenekler] <image>          Tek image analizi
  $(basename "$0") [seçenekler] -a               Pool'daki tüm image'ları tara

<image>  RBD image adı (ör. csi-vol-8b2716cd-5655-41e7-99d2-5745902b0971)
         veya "pool/image" biçiminde.

Seçenekler:
  -n <ns>     ODF namespace'i              (varsayılan: ${ODF_NS})
  -p <pool>   RBD pool'u                   (varsayılan: PV'den bulunur, yoksa ${DEFAULT_POOL})
  -r <ns>     RADOS namespace'i            (varsayılan: PV'den bulunur, yoksa boş)
  -o <fmt>    Çıktı biçimi: text | json    (varsayılan: ${OUTPUT})
  -v          Tüm child'ları tek tek listele (text çıktısında)
  -a          Tarama modu: pool'daki tüm image'ların snapshot+child sayıları
  -t <n>      Tarama modunda işaretlenecek en düşük toplam (varsayılan: ${THRESHOLD})
  -T <n>      Listelerde gösterilecek en fazla satır       (varsayılan: ${TOP})
  -L <n>      Alarm eşiği (flatten planı bunun altına indirecek kadar aday seçer) (varsayılan: ${ALERT_LIMIT})
  -N <n>      Flatten planındaki aday sayısı (varsayılan: eşiğin altına inmek için gereken)
  -F          Sadece flatten planının komutlarını yazdır (çalıştırmaz; gözden geçirip uygulayın)

Flatten çalıştırma (CLUSTER'DA DEĞİŞİKLİK YAPAR):
  -X, --execute  Flatten planındaki image'ları tek tek "rbd flatten" ile flatten et
  -y          Başlangıç onayını atla
  -s <sn>     İki flatten arası bekleme, saniye   (varsayılan: ${SLEEP_SECS})
  -m <%>      Pool boş alanı bu yüzdenin altına düşerse dur; 0 = kontrol yok (varsayılan: ${MIN_FREE_PCT})

  -h          Bu yardım
  -V          Sürüm

Örnekler:
  $(basename "$0") csi-vol-8b2716cd-5655-41e7-99d2-5745902b0971
  $(basename "$0") -o json csi-vol-8b2716cd-5655-41e7-99d2-5745902b0971 > rapor.json
  $(basename "$0") -F csi-vol-8b2716cd-5655-41e7-99d2-5745902b0971 > flatten-plan.sh
  $(basename "$0") -X -N 20 csi-vol-8b2716cd-5655-41e7-99d2-5745902b0971
  $(basename "$0") -a -t 150

Ortam değişkenleri: CSI_MIN_SNAPS (250), CSI_MAX_SNAPS (450): ceph-csi flatten limitleri
EOF
}

die()  { echo "HATA: $*" >&2; exit 1; }
info() { echo ">> $*" >&2; }

ARGS=()
for a in "$@"; do
  case "$a" in
    --help) usage; exit 0 ;;
    --execute) ARGS+=("-X") ;;
    *) ARGS+=("$a") ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

while getopts ":n:p:r:o:t:T:L:N:s:m:FXyavhV" opt; do
  case "$opt" in
    n) ODF_NS="$OPTARG" ;;
    p) POOL="$OPTARG" ;;
    r) RADOS_NS="$OPTARG" ;;
    o) OUTPUT="$OPTARG" ;;
    t) THRESHOLD="$OPTARG" ;;
    T) TOP="$OPTARG" ;;
    L) ALERT_LIMIT="$OPTARG" ;;
    N) PLAN_SIZE="$OPTARG" ;;
    F) CMDS_ONLY=1 ;;
    X) EXECUTE=1 ;;
    y) ASSUME_YES=1 ;;
    s) SLEEP_SECS="$OPTARG" ;;
    m) MIN_FREE_PCT="${OPTARG%\%}" ;;
    a) SCAN=1 ;;
    v) VERBOSE=1 ;;
    h) usage; exit 0 ;;
    V) echo "$VERSION"; exit 0 ;;
    :) die "-$OPTARG bir değer bekliyor" ;;
    *) die "bilinmeyen seçenek: -$OPTARG (yardım için -h)" ;;
  esac
done
shift $((OPTIND - 1))

case "$OUTPUT" in text|json) ;; *) die "-o text veya json olmalı" ;; esac
case "$THRESHOLD" in ''|*[!0-9]*) die "-t sayı olmalı" ;; esac
case "$TOP" in ''|*[!0-9]*) die "-T sayı olmalı" ;; esac
case "$ALERT_LIMIT" in ''|*[!0-9]*) die "-L sayı olmalı" ;; esac
case "$PLAN_SIZE" in *[!0-9]*) die "-N sayı olmalı" ;; esac
case "$CSI_MIN_SNAPS$CSI_MAX_SNAPS" in *[!0-9]*) die "CSI_MIN_SNAPS / CSI_MAX_SNAPS sayı olmalı" ;; esac
case "$SLEEP_SECS" in ''|*[!0-9]*) die "-s sayı olmalı" ;; esac
case "$MIN_FREE_PCT" in ''|*[!0-9]*) die "-m 0-100 arası sayı olmalı" ;; esac
[ "$MIN_FREE_PCT" -le 100 ] || die "-m 0-100 arası sayı olmalı"
if [ "$EXECUTE" -eq 1 ]; then
  [ "$SCAN" -eq 0 ] || die "-X, -a ile birlikte kullanılamaz"
  [ "$CMDS_ONLY" -eq 0 ] || die "-X ve -F birlikte kullanılamaz"
fi

if [ "$SCAN" -eq 0 ]; then
  [ $# -eq 1 ] || { usage >&2; exit 1; }
  IMAGE="$1"
  case "$IMAGE" in
    */*) [ -n "$POOL" ] || POOL="${IMAGE%/*}"; IMAGE="${IMAGE##*/}" ;;
  esac
fi

for bin in oc jq; do
  command -v "$bin" >/dev/null 2>&1 || die "'$bin' bulunamadı"
done
oc whoami >/dev/null 2>&1 || die "oc oturumu yok (oc login / KUBECONFIG kontrol edin)"

TOOLS=$(oc -n "$ODF_NS" get pod -l app=rook-ceph-tools --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$TOOLS" ]; then
  cat >&2 <<EOF
HATA: ${ODF_NS} namespace'inde Running durumda rook-ceph-tools pod'u yok.
Toolbox'ı açmak için (ODF 4.15+):
  oc patch ocsinitialization ocsinit -n ${ODF_NS} --type json \\
    --patch '[{"op":"replace","path":"/spec/enableCephTools","value":true}]'
Bu script bu değişikliği kendisi YAPMAZ.
EOF
  exit 2
fi

rbd()  { oc -n "$ODF_NS" exec "$TOOLS" -- rbd "$@" </dev/null; }
ceph() { oc -n "$ODF_NS" exec "$TOOLS" -- ceph "$@" </dev/null; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/rbd-snap-report.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Tarama modu
# ---------------------------------------------------------------------------
if [ "$SCAN" -eq 1 ]; then
  [ -n "$POOL" ] || POOL="$DEFAULT_POOL"
  POOLSPEC="$POOL${RADOS_NS:+/$RADOS_NS}"
  info "Pool taranıyor: $POOLSPEC (image sayısına göre birkaç dakika sürebilir)"
  # Toolbox içinde tek exec; her satır: <image> <snapshot sayısı> <direct child sayısı>
  # shellcheck disable=SC2016
  oc -n "$ODF_NS" exec "$TOOLS" -- sh -c '
    p="$1"
    for i in $(rbd ls "$p"); do
      s=$(rbd snap ls --all --format json "$p/$i" 2>/dev/null | grep -o "\"name\":" | wc -l)
      c=$(rbd children --all --format json "$p/$i" 2>/dev/null | grep -o "\"image\":" | wc -l)
      echo "$i $s $c"
    done' sh "$POOLSPEC" > "$TMP/scan.txt" || die "pool taranamadı: $POOLSPEC"

  jq -R -s --arg pool "$POOLSPEC" --argjson thr "$THRESHOLD" --argjson top "$TOP" '
    [ split("\n")[] | select(length > 0) | split(" ") | map(select(length > 0))
      | { image: .[0], snapshots: (.[1] | tonumber), children: (.[2] | tonumber) }
      | .total = .snapshots + .children ]
    | sort_by(-.total) as $all
    | { pool: $pool, threshold: $thr, images_scanned: ($all | length),
        images_over_threshold: [ $all[] | select(.total >= $thr) ],
        top: $all[:$top] }' "$TMP/scan.txt" > "$TMP/scan.json"

  if [ "$OUTPUT" = "json" ]; then
    cat "$TMP/scan.json"
  else
    jq -r '
      def pad($n): tostring | if length >= $n then . else . + (" " * ($n - length)) end;
      .threshold as $thr
      | "Pool             : \(.pool)",
        "Taranan image    : \(.images_scanned)",
        "Eşik (>=)        : \($thr)  ->  \(.images_over_threshold | length) image",
        "",
        "\("IMAGE" | pad(52)) \("SNAP" | pad(6)) \("CHILD" | pad(6)) TOPLAM",
        ( .top[] | "\(.image | pad(52)) \(.snapshots | pad(6)) \(.children | pad(6)) \(.total)\(if .total >= $thr then "  <==" else "" end)" )
    ' "$TMP/scan.json"
    echo
    echo "Detay için: $(basename "$0") <image>"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Tek image analizi
# ---------------------------------------------------------------------------

# Zorunlu listeler: hata olursa dur.
get_required() { # <dosya> <oc get argümanları...>
  local f="$1"; shift
  oc get "$@" -o json > "$TMP/$f" 2>"$TMP/err" || die "oc get $* başarısız: $(cat "$TMP/err")"
}
# Opsiyonel listeler (CRD kurulu olmayabilir): hata olursa boş liste.
get_optional() {
  local f="$1"; shift
  oc get "$@" -o json > "$TMP/$f" 2>/dev/null || echo '{"items":[]}' > "$TMP/$f"
}

info "Kubernetes nesneleri okunuyor"
get_required pv.json  pv
get_required pvc.json pvc -A
get_optional vsc.json volumesnapshotcontents.snapshot.storage.k8s.io
get_optional vs.json  volumesnapshots.snapshot.storage.k8s.io -A
get_optional vm.json  virtualmachines.kubevirt.io -A
get_optional ds.json  datasources.cdi.kubevirt.io -A
get_optional dic.json dataimportcrons.cdi.kubevirt.io -A

PV_POOL=$(jq -r --arg i "$IMAGE" \
  '[.items[] | select(.spec.csi.volumeAttributes.imageName? == $i)][0].spec.csi.volumeAttributes.pool // ""' "$TMP/pv.json")
PV_RNS=$(jq -r --arg i "$IMAGE" \
  '[.items[] | select(.spec.csi.volumeAttributes.imageName? == $i)][0].spec.csi.volumeAttributes.radosNamespace // ""' "$TMP/pv.json")
[ -n "$POOL" ]     || POOL="$PV_POOL"
[ -n "$POOL" ]     || POOL="$DEFAULT_POOL"
[ -n "$RADOS_NS" ] || RADOS_NS="$PV_RNS"
SPEC="$POOL/${RADOS_NS:+$RADOS_NS/}$IMAGE"
DRIVER="${ODF_NS}.rbd.csi.ceph.com"

info "Ceph okunuyor: $SPEC (toolbox: $TOOLS)"
rbd info --format json "$SPEC" > "$TMP/info.json" 2>"$TMP/err" \
  || die "rbd info başarısız ($SPEC): $(cat "$TMP/err")"
rbd snap ls --all --format json "$SPEC" > "$TMP/snaps.json"
rbd children --all --format json "$SPEC" > "$TMP/children.json"
rbd children --all --descendants --format json "$SPEC" > "$TMP/desc.json"
# Opsiyonel: kaynak image'ın kullanılan boyutu (kapasite tahmini) ve mgr flatten görevleri
rbd du --format json "$SPEC" > "$TMP/du.json" 2>/dev/null || echo '{}' > "$TMP/du.json"
ceph rbd task list --format json > "$TMP/tasks.json" 2>/dev/null || echo '[]' > "$TMP/tasks.json"
for f in snaps children desc tasks; do
  [ -s "$TMP/$f.json" ] || echo '[]' > "$TMP/$f.json"
done
[ -s "$TMP/du.json" ] || echo '{}' > "$TMP/du.json"

info "Eşleştiriliyor"
jq -n \
  --arg image "$IMAGE" --arg pool "$POOL" --arg radosns "$RADOS_NS" --arg driver "$DRIVER" \
  --arg odfns "$ODF_NS" --arg tools "$TOOLS" --arg plansize "$PLAN_SIZE" \
  --argjson alertlimit "$ALERT_LIMIT" --argjson csimin "$CSI_MIN_SNAPS" --argjson csimax "$CSI_MAX_SNAPS" \
  --slurpfile du "$TMP/du.json" --slurpfile tasks "$TMP/tasks.json" \
  --slurpfile pv "$TMP/pv.json"   --slurpfile pvc "$TMP/pvc.json" \
  --slurpfile vsc "$TMP/vsc.json" --slurpfile vs "$TMP/vs.json" \
  --slurpfile vm "$TMP/vm.json"   --slurpfile ds "$TMP/ds.json" --slurpfile dic "$TMP/dic.json" \
  --slurpfile info "$TMP/info.json" --slurpfile snaps "$TMP/snaps.json" \
  --slurpfile children "$TMP/children.json" --slurpfile desc "$TMP/desc.json" '
  def uuid: [capture("(?<u>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$") | .u] | .[0];

  ( [ $pv[0].items[] | select(.spec.csi.volumeAttributes.imageName? != null)
      | { key: .spec.csi.volumeAttributes.imageName,
          value: { pv: .metadata.name, namespace: .spec.claimRef.namespace, pvc: .spec.claimRef.name,
                   phase: .status.phase, storageclass: .spec.storageClassName } } ]
    | from_entries ) as $pvmap
  | ( [ $pvc[0].items[]
      | { key: "\(.metadata.namespace)/\(.metadata.name)",
          value: { created: .metadata.creationTimestamp,
                   owner: ([.metadata.ownerReferences[]? | "\(.kind)/\(.name)"] | join(",")),
                   labels: (.metadata.labels // {}) } } ]
    | from_entries ) as $pvcmap
  | ( reduce $vm[0].items[] as $v ({};
        reduce ( $v.spec.template.spec.volumes[]? | (.persistentVolumeClaim.claimName // .dataVolume.name // empty) ) as $c
          (.; .["\($v.metadata.namespace)/\($c)"] = { name: $v.metadata.name, status: ($v.status.printableStatus // "-") }) ) ) as $vmmap
  | ( [ $vs[0].items[] | { key: "\(.metadata.namespace)/\(.metadata.name)", value: true } ] | from_entries ) as $vsmap
  | ( [ $vsc[0].items[] | select(.spec.driver == $driver and .status.snapshotHandle? != null)
      | { key: (.status.snapshotHandle | uuid),
          value: { vsc: .metadata.name, policy: .spec.deletionPolicy, created: .metadata.creationTimestamp,
                   vs_namespace: .spec.volumeSnapshotRef.namespace, vs: .spec.volumeSnapshotRef.name } } ]
    | map(select(.key != null)) | from_entries ) as $vscmap
  | ( [ $vsc[0].items[] | select(.spec.driver == $driver) | .metadata.name ] ) as $rbdvsc

  | def pvinfo($n):
      $pvmap[$n] as $p
      | if $p == null then null
        else $vmmap["\($p.namespace)/\($p.pvc)"] as $v
          | $p + { vm: $v.name, vm_status: $v.status,
                   pvc_created: $pvcmap["\($p.namespace)/\($p.pvc)"].created,
                   owner: ($pvcmap["\($p.namespace)/\($p.pvc)"].owner // "") }
        end;

    def snapinfo($n):
      ($n | uuid) as $u
      | (if $u == null then null else $vscmap[$u] end)
      | if . == null then null
        else . + { namespace: .vs_namespace, vs_exists: ($vsmap["\(.vs_namespace)/\(.vs)"] // false) }
        end;

    def classify:
      .image as $n
      | if (.trash // false) then
          { kind: "trash", note: "Image RBD trash içinde; kendi child\u0027larının silinmesini bekliyor" }
        elif ($n | test("^csi-vol-.+-temp$")) then
          pvinfo($n | sub("-temp$"; "")) as $p
          | if $p != null then $p + { kind: "clone-intermediate" }
            else { kind: "orphan", note: "Ara clone image; hedef PV yok" } end
        elif ($n | startswith("csi-vol-")) then
          pvinfo($n) as $p
          | if $p != null then $p + { kind: "pvc-clone" }
            else { kind: "orphan", note: "Bu image için PV yok" } end
        elif ($n | startswith("csi-snap-")) then
          snapinfo($n) as $s
          | if $s == null then { kind: "orphan", note: "Bu snapshot için VolumeSnapshotContent yok" }
            elif $s.vs_exists then $s + { kind: "volumesnapshot" }
            else $s + { kind: "vsc-only", note: "VolumeSnapshotContent \($s.vsc) var, VolumeSnapshot silinmiş (deletionPolicy: \($s.policy))" }
            end
        else { kind: "other", note: "CSI dışı image adı" }
        end;

    ([ $children[0][] | .image ]) as $direct
  | ([ $desc[0][] | { image: .image, pool: .pool, trash: (.trash // false),
                      direct: (.image as $i | $direct | index($i) != null) }
                    + classify ]) as $kids

  | pvinfo($image) as $src
  | ( if $src == null then [] else
        [ $ds[0].items[] | select((.spec.source.pvc.name // "") == $src.pvc
                                  and (.spec.source.pvc.namespace // .metadata.namespace) == $src.namespace)
          | { namespace: .metadata.namespace, name: .metadata.name } ]
      end ) as $srcds
  | ( [ $dic[0].items[] as $d | $srcds[]
        | select(.namespace == $d.metadata.namespace and .name == $d.spec.managedDataSource)
        | { namespace: $d.metadata.namespace, name: $d.metadata.name, schedule: $d.spec.schedule,
            importsToKeep: ($d.spec.importsToKeep // 3), lastImport: $d.status.lastImportTimestamp } ] ) as $srcdic
  | ( if $src == null then [] else
        [ $vs[0].items[] | select(.metadata.namespace == $src.namespace
                                  and .spec.source.persistentVolumeClaimName == $src.pvc)
          | { name: .metadata.name, created: .metadata.creationTimestamp, ready: .status.readyToUse,
              vsc: .status.boundVolumeSnapshotContentName } ]
        | sort_by(.created)
      end ) as $srcvs
  | ( [ $vs[0].items[] | select(.status.boundVolumeSnapshotContentName as $b | $b != null and ($rbdvsc | index($b) != null)) ]
      | group_by(.metadata.namespace)
      | map({ namespace: .[0].metadata.namespace, count: length,
              oldest: (map(.metadata.creationTimestamp) | min) })
      | sort_by(-.count) ) as $nsvs

  | ( [ $snaps[0][] | { name, id, protected, timestamp, type: (.namespace.type // "user") }
        + (snapinfo(.name) // {}) ] ) as $snaplist
  | ( $kids | group_by(.kind) | map({ key: .[0].kind, value: length }) | from_entries ) as $bykind
  | ( [ $kids[] | select(.vm != null) | "\(.namespace)/\(.vm)" ] | unique | length ) as $vmcount
  | ( ($bykind.volumesnapshot // 0) as $a | ($srcvs | length) as $b | if $a > $b then $a else $b end ) as $vscount
  | ( ($srcds | length) > 0
      or (($pvcmap["\($src.namespace)/\($src.pvc)"].labels // {}) | has("cdi.kubevirt.io/dataImportCron")) ) as $golden_cdi
  # Kendisi bir VM diski olmayıp VM clone kaynağı olan PVC = custom golden image / template
  | ( $src != null and $src.vm == null and $vmcount > 0 ) as $golden_custom
  | ( $golden_cdi or $golden_custom ) as $golden
  | ( if $golden_cdi then "DataSource/DataImportCron" elif $golden_custom then "custom template PVC" else null end ) as $golden_type

  | ( $snaplist | length ) as $nsnaps
  | ( [ $nsnaps, ($direct | length) ] | max ) as $count
  | ( [ $count - $alertlimit + 1, 0 ] | max ) as $needed
  | ( [ $du[0].images[]? | select(.snapshot == null and .name == $image) | .used_size ] | .[0] ) as $srcused
  | ( [ $tasks[0][]? | select(.refs.action == "flatten") | .refs.image_name ] ) as $flattasks
  | ( [ $kids[] | select(.direct and (.trash | not) and (.kind == "clone-intermediate" or .kind == "pvc-clone"))
        | . + { queued: (.image as $i | $flattasks | index($i) != null) } ]
      # Sıra: durdurulmuş VM diski, VM bağlantısız PVC, çalışan VM; her grupta en eski PVC önce.
      # mgr kuyruğunda olanlar zaten flatten edileceği için plana alınmaz.
      | sort_by([ .queued, (if .vm_status == "Stopped" then 0 elif .vm == null then 1 else 2 end), (.pvc_created // "") ]) ) as $candidates
  | ( [ $candidates[] | select(.queued) ] | length ) as $nqueued
  | ( if $plansize == "" then ([ $needed - $nqueued, 0 ] | max) else ($plansize | tonumber) end ) as $plann
  | ( $candidates | map(select(.queued | not)) | .[:$plann]
      | map({ image, pool, namespace, pvc, vm, vm_status, pvc_created,
              command: "oc -n \($odfns) exec \($tools) -- rbd flatten \(.pool)/\(.image)" }) ) as $plan

  | {
      generated: (now | todate),
      image: $image, pool: $pool, rados_namespace: $radosns, driver: $driver,
      source: ( ($src // { note: "Bu image için PV bulunamadı (image orphan olabilir)" })
                + { parent: $info[0].parent, size: $info[0].size, used_size: $srcused,
                    golden_image: $golden, golden_type: $golden_type,
                    datasources: $srcds, dataimportcrons: $srcdic } ),
      summary: {
        snapshots_total: ($snaplist | length),
        snapshots_by_type: ($snaplist | group_by(.type) | map({ key: .[0].type, value: length }) | from_entries),
        children_direct: ($direct | length),
        descendants_total: ($kids | length),
        descendants_by_kind: $bykind,
        vms_using_clones: $vmcount
      },
      cephcsi: {
        min_snapshots_on_image: $csimin, max_snapshots_on_image: $csimax,
        state: (if $nsnaps > $csimax then "hard-limit" elif $nsnaps > $csimin then "soft-limit" else "ok" end),
        flatten_tasks_queued: $nqueued,
        flatten_tasks_total: ($flattasks | length)
      },
      flatten_plan: {
        alert_limit: $alertlimit, current_count: $count, needed: $needed,
        candidates_total: ($candidates | length),
        estimated_capacity_bytes: (if $srcused then $srcused * ($plan | length) else null end),
        estimated_capacity_bytes_all: (if $srcused then $srcused * ($candidates | length) else null end),
        items: $plan
      },
      snapshots: $snaplist,
      children: $kids,
      source_volumesnapshots: $srcvs,
      rbd_volumesnapshots_by_namespace: $nsvs,
      hints: [
        ( select($nsnaps > $csimax)
          | "KRİTİK: image üzerinde \($nsnaps) snapshot var (> ceph-csi maxsnapshotsonimage=\($csimax)). Bu kaynaktan yeni clone/snapshot ResourceExhausted ile reddedilir; ceph-csi tüm ara clone\u0027lar için flatten görevi ekler. Hemen flatten planını uygulayın (README: Senaryo A)." ),
        ( select($nsnaps > $csimin and $nsnaps <= $csimax)
          | "UYARI: image üzerinde \($nsnaps) snapshot var (> ceph-csi minsnapshotsonimage=\($csimin)). Bu kaynaktan alınacak bir sonraki clone, \($candidates | length) ara clone\u0027un TAMAMI için mgr flatten görevi kuyruğa ekletir (ani kapasite + I/O yükü). Bunu beklemeden kontrollü flatten yapın: -F ile plan üretin (README: Senaryo A)." ),
        ( select($vmcount > 0 or $golden)
          | "CNV: \($vmcount) VM bu image\u0027dan clone edilmiş disk kullanıyor\(if $golden then " (golden image: \($golden_type))" else "" end). Alarm eşiğinin (\($alertlimit)) altına inmek için en az \($needed) direct child flatten edilmeli. Kullanılmayan VM\u0027leri silin veya seçili VM disklerini flatten edin; yeni VM\u0027ler için golden image yenilemesini kontrol edin (README: Senaryo A)." ),
        ( select($vscount > 0)
          | "VolumeSnapshot: bu PVC\u0027den \($vscount) snapshot alınmış. Eskileri oc delete volumesnapshot ile silin ve retention belirleyin (README: Senaryo B)." ),
        ( select(($bykind["vsc-only"] // 0) > 0)
          | "\($bykind["vsc-only"]) VolumeSnapshotContent sahipsiz (VolumeSnapshot yok). deletionPolicy=Delete yapıp VSC\u0027yi silin (README: Senaryo C)." ),
        ( select(($bykind.orphan // 0) > 0)
          | "\($bykind.orphan) ORPHAN image (Ceph\u0027te var, Kubernetes\u0027te yok). Doğrulamadan rbd ile silmeyin (README: Senaryo D)." ),
        ( select(($bykind.trash // 0) > 0)
          | "\($bykind.trash) child RBD trash içinde; kendi child\u0027ları temizlenince silinirler (README: Senaryo D)." )
      ]
    }' > "$TMP/report.json"

# ---------------------------------------------------------------------------
# Flatten çalıştırma (-X): flatten_plan.items listesini tek tek işler
# ---------------------------------------------------------------------------
pool_free_pct() {
  ceph df --format json 2>/dev/null | jq -r --arg p "$POOL" '
    ([.pools[]? | select(.name == $p) | .stats] | .[0]) as $s
    | if $s != null and $s.max_avail != null and (($s.stored // 0) + $s.max_avail) > 0
      then ($s.max_avail * 100 / (($s.stored // 0) + $s.max_avail) | floor)
      elif (.stats.total_bytes // 0) > 0
      then (.stats.total_avail_bytes * 100 / .stats.total_bytes | floor)
      else empty end'
}

image_parent() { # <spec> -> parent image adı (yoksa boş); okunamazsa exit 1
  rbd info --format json "$1" 2>/dev/null | jq -er '.parent.image // ""'
}

run_flatten() {
  local n total spec img label pct parent start dur
  local done_n=0 skipped=0 failed=0 stop=0
  local log
  log="./rbd-flatten-${IMAGE}-$(date +%Y%m%d-%H%M%S).log"
  total=$(jq '.flatten_plan.items | length' "$TMP/report.json")

  if [ "$total" -eq 0 ]; then
    echo "Flatten planı boş; yapılacak iş yok."
    return 0
  fi

  jq -r '
    "=== FLATTEN: \(.pool)/\(.image) ===",
    "Mevcut sayı \(.flatten_plan.current_count), alarm eşiği \(.flatten_plan.alert_limit), plandaki image: \(.flatten_plan.items | length)",
    "Tahmini ek kapasite (üst sınır): \(if .flatten_plan.estimated_capacity_bytes then "\(.flatten_plan.estimated_capacity_bytes / 1073741824 | floor) GiB" else "bilinmiyor" end)",
    ( .flatten_plan.items[] | "  \(.image)  \(.namespace // "-")/\(.vm // "-") (\(.vm_status // "-"))" )
  ' "$TMP/report.json"
  echo "Bekleme: ${SLEEP_SECS}s, en düşük boş alan: %${MIN_FREE_PCT}, log: $log"

  if [ "$ASSUME_YES" -eq 0 ]; then
    ( : </dev/tty ) 2>/dev/null || die "onay için terminal yok; otomasyonda -y kullanın"
    local answer
    printf '\nDevam etmek için kaynak image adını yazın (%s): ' "$IMAGE" > /dev/tty
    read -r answer < /dev/tty || answer=""
    [ "$answer" = "$IMAGE" ] || { echo "Onay verilmedi, çıkılıyor."; return 1; }
  fi

  log_line() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$log"; }
  trap 'stop=1; echo; echo ">> Durdurma istendi (Ctrl-C). Kesilen flatten varsa Ceph tarafında yarım kalmış olabilir; rbd info ile kontrol edin." >&2' INT

  log_line "BAŞLADI $POOL/${RADOS_NS:+$RADOS_NS/}$IMAGE plan=$total"
  n=0
  while IFS=$'\t' read -r img label; do
    n=$((n + 1))
    [ "$stop" -eq 0 ] || break
    spec="$POOL/${RADOS_NS:+$RADOS_NS/}$img"

    if [ "$MIN_FREE_PCT" -gt 0 ]; then
      pct=$(pool_free_pct || true)
      if [ -z "$pct" ]; then
        log_line "[$n/$total] DUR: ceph df okunamadı (kapasite kontrolü için -m 0 ile kapatılabilir)"; failed=$((failed + 1)); break
      fi
      if [ "$pct" -lt "$MIN_FREE_PCT" ]; then
        log_line "[$n/$total] DUR: pool boş alanı %$pct < %$MIN_FREE_PCT"; failed=$((failed + 1)); break
      fi
    fi

    if ! parent=$(image_parent "$spec"); then
      log_line "[$n/$total] HATA: rbd info okunamadı: $spec ($label)"; failed=$((failed + 1)); break
    fi
    if [ -z "$parent" ]; then
      log_line "[$n/$total] ATLANDI (parent yok, zaten flatten edilmiş): $img ($label)"
      skipped=$((skipped + 1)); continue
    fi

    log_line "[$n/$total] FLATTEN: $img ($label) parent=$parent boş=%${pct:-?}"
    start=$(date +%s)
    if ! rbd flatten --no-progress "$spec" >>"$log" 2>&1; then
      log_line "[$n/$total] HATA: rbd flatten başarısız: $img (ayrıntı: $log)"; failed=$((failed + 1)); break
    fi
    dur=$(( $(date +%s) - start ))

    if ! parent=$(image_parent "$spec") || [ -n "$parent" ]; then
      log_line "[$n/$total] HATA: flatten sonrası parent hâlâ var veya okunamadı: $img"; failed=$((failed + 1)); break
    fi
    done_n=$((done_n + 1))
    log_line "[$n/$total] TAMAM: $img ${dur}s"

    if [ "$n" -lt "$total" ] && [ "$stop" -eq 0 ] && [ "$SLEEP_SECS" -gt 0 ]; then
      sleep "$SLEEP_SECS" || true
    fi
  done < <(jq -r '.flatten_plan.items[] | [.image, "\(.namespace // "-")/\(.vm // .pvc // "-")"] | @tsv' "$TMP/report.json")
  trap - INT

  local snaps children
  snaps=$(rbd snap ls --all --format json "$SPEC" 2>/dev/null | jq 'length' 2>/dev/null || true)
  children=$(rbd children --all --format json "$SPEC" 2>/dev/null | jq 'length' 2>/dev/null || true)
  log_line "BİTTİ yapılan=$done_n atlanan=$skipped hata=$failed plan=$total | kaynakta şimdi: snapshot=${snaps:-?} direct_child=${children:-?}"
  [ "$failed" -eq 0 ] && [ "$stop" -eq 0 ]
}

if [ "$EXECUTE" -eq 1 ]; then
  run_flatten
  exit $?
fi

if [ "$CMDS_ONLY" -eq 1 ]; then
  jq -r '
    "#!/usr/bin/env bash",
    "# Flatten planı: \(.pool)/\(.image)  (\(.generated))",
    "# Mevcut sayı: \(.flatten_plan.current_count), alarm eşiği: \(.flatten_plan.alert_limit), gereken: \(.flatten_plan.needed), plandaki: \(.flatten_plan.items | length)",
    "# Tahmini ek kapasite: \(if .flatten_plan.estimated_capacity_bytes then "\(.flatten_plan.estimated_capacity_bytes / 1073741824 | floor) GiB (kaynak used_size x adet, üst sınır)" else "bilinmiyor" end)",
    "# Önce: ceph df ile kapasiteyi kontrol edin. Komutlar sırayla (tek tek) çalışır.",
    "set -euo pipefail",
    ( .flatten_plan.items[] | "\(.command)   # \(.namespace // "-")/\(.pvc // "-") vm=\(.vm // "-") (\(.vm_status // "-"))" )
  ' "$TMP/report.json"
  exit 0
fi

if [ "$OUTPUT" = "json" ]; then
  cat "$TMP/report.json"
  exit 0
fi

jq -r --argjson top "$TOP" --argjson verbose "$VERBOSE" --arg script "$(basename "$0")" '
  def pad($n): tostring | if length >= $n then . else . + (" " * ($n - length)) end;
  def nz: if . == null or . == "" then "-" else . end;
  def kv: to_entries | map("\(.key)=\(.value)") | join("  ");
  def gib: if . == null then "?" else "\(. / 1073741824 * 10 | floor / 10) GiB" end;
  def row: "  \(.image | pad(48)) \(.kind | pad(19)) \("\(.namespace | nz)/\(.pvc // .vs | nz)" | pad(45)) \(.vm | nz)\(if .note then "  # " + .note else "" end)";

  "=== HighRBDCloneSnapshotCount analizi (\(.generated)) ===",
  "Image          : \(.pool)/\(if .rados_namespace != "" then .rados_namespace + "/" else "" end)\(.image)",
  "PV / PVC       : \(.source.pv | nz)  \(.source.namespace | nz)/\(.source.pvc | nz)",
  "VM / Owner     : \(.source.vm | nz)  \(.source.owner | nz)",
  "Parent         : \(if .source.parent then "\(.source.parent.pool)/\(.source.parent.image)@\(.source.parent.snapshot)" else "-" end)",
  "Boyut          : \(.source.size | gib) (kullanılan: \(.source.used_size | gib))",
  "Golden image   : \(if .source.golden_image then "EVET (\(.source.golden_type))" else "hayır" end)",
  ( .source.datasources[]     | "  DataSource     : \(.namespace)/\(.name)" ),
  ( .source.dataimportcrons[] | "  DataImportCron : \(.namespace)/\(.name)  schedule=\(.schedule | nz)  importsToKeep=\(.importsToKeep)  lastImport=\(.lastImport | nz)" ),
  ( .source.note // empty | "Not            : \(.)" ),
  "",
  "--- Özet ---",
  "Snapshot (toplam)        : \(.summary.snapshots_total)   [\(.summary.snapshots_by_type | kv)]",
  "Direct child             : \(.summary.children_direct)",
  "Tüm child (descendants)  : \(.summary.descendants_total)   [\(.summary.descendants_by_kind | kv)]",
  "Clone kullanan VM sayısı : \(.summary.vms_using_clones)",
  "",
  "--- ceph-csi otomatik flatten durumu ---",
  "Snapshot sayısı \(.summary.snapshots_total) / soft limit \(.cephcsi.min_snapshots_on_image) / hard limit \(.cephcsi.max_snapshots_on_image)  ->  \(
     { "ok": "OK", "soft-limit": "SOFT LIMIT AŞILDI: bir sonraki clone tüm ara clone\u0027lar için flatten görevi ekletir",
       "hard-limit": "HARD LIMIT AŞILDI: yeni clone/snapshot reddedilir" }[.cephcsi.state])",
  "mgr flatten görevleri: bu image\u0027ın child\u0027ları için \(.cephcsi.flatten_tasks_queued), toplam \(.cephcsi.flatten_tasks_total)",
  "",
  "--- Flatten planı (alarm eşiği \(.flatten_plan.alert_limit)) ---",
  "Mevcut sayı \(.flatten_plan.current_count)  ->  eşiğin altına inmek için en az \(.flatten_plan.needed) direct child flatten edilmeli (aday: \(.flatten_plan.candidates_total), mgr kuyruğunda: \(.cephcsi.flatten_tasks_queued), planda: \(.flatten_plan.items | length))",
  "Tahmini ek kapasite: plan \(.flatten_plan.estimated_capacity_bytes | gib), tüm adaylar \(.flatten_plan.estimated_capacity_bytes_all | gib)  (kaynak used_size x adet, üst sınır)",
  ( if (.flatten_plan.items | length) == 0 then "  (plan boş)" else
      (.flatten_plan.items[:$top][] | "  \(.image | pad(50)) \("\(.namespace // "-")/\(.vm // "-")" | pad(40)) \(.vm_status // "-" | pad(10)) \(.pvc_created // "-")"),
      ( select((.flatten_plan.items | length) > $top) | "  ... toplam \(.flatten_plan.items | length) aday; tamamı için: -F" )
    end ),
  "Komutları üretmek için: \($script) -F \(.image) > flatten-plan.sh",
  "",
  "--- Namespace bazında child dağılımı (ilk \($top)) ---",
  ( [ .children[] | select(.kind == "pvc-clone" or .kind == "clone-intermediate" or .kind == "volumesnapshot") ]
    | if length == 0 then "  (yok)" else
        group_by(.namespace)
        | map({ ns: (.[0].namespace | nz), n: length, vms: ([.[].vm | select(. != null)] | unique | length) })
        | sort_by(-.n)[:$top][] | "  \(.ns | pad(40)) child=\(.n | pad(5)) vm=\(.vms)"
      end ),
  "",
  "--- Dikkat gerektirenler (orphan / trash / vsc-only) ---",
  ( [ .children[] | select(.kind == "orphan" or .kind == "trash" or .kind == "vsc-only") ]
    | if length == 0 then "  (yok)" else .[] | row end ),
  ( select($verbose == 1)
    | "", "--- Tüm child listesi ---",
      "  \("IMAGE" | pad(48)) \("TÜR" | pad(19)) \("NAMESPACE/PVC|VS" | pad(45)) VM",
      (.children[] | row) ),
  "",
  "--- Image üzerindeki snapshot\u0027lar (ilk \($top)) ---",
  ( if (.snapshots | length) == 0 then "  (yok)" else
      .snapshots[:$top][] | "  \(.name | pad(48)) \(.type | pad(6)) \(.timestamp | nz | pad(26)) \(if .vs then "VS=\(.vs_namespace)/\(.vs)" else "" end)"
    end ),
  "",
  "--- Bu PVC kaynaklı VolumeSnapshot\u0027lar (en eski \($top)) ---",
  ( if (.source_volumesnapshots | length) == 0 then "  (yok)" else
      .source_volumesnapshots[:$top][] | "  \(.name | pad(50)) \(.created | nz | pad(22)) ready=\(.ready)"
    end ),
  "",
  "--- Namespace bazında RBD VolumeSnapshot sayıları (ilk \($top)) ---",
  ( if (.rbd_volumesnapshots_by_namespace | length) == 0 then "  (yok)" else
      .rbd_volumesnapshots_by_namespace[:$top][] | "  \(.namespace | pad(40)) adet=\(.count | pad(5)) en_eski=\(.oldest)"
    end ),
  "",
  "--- Öneriler ---",
  ( if (.hints | length) == 0 then "  Belirgin bir sebep bulunamadı; -v ile tüm listeyi inceleyin." else .hints[] | "  * " + . end )
' "$TMP/report.json"
