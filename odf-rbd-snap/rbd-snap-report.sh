#!/usr/bin/env bash
#
# rbd-snap-report.sh — ODF "HighRBDCloneSnapshotCount" alarmı için salt okunur analiz.
#
# Bir RBD image'ının snapshot'larını ve clone'larını (child) listeler.
# Her kaydı Kubernetes tarafındaki karşılığıyla eşleştirir:
# PV/PVC, VirtualMachine, VolumeSnapshot/VolumeSnapshotContent.
# Ceph'te olup Kubernetes'te karşılığı olmayan kayıtları ORPHAN olarak işaretler.
# Cluster üzerinde HİÇBİR değişiklik yapmaz: yalnızca "oc get" ve toolbox
# pod'unda "rbd info/ls/snap ls/children" komutlarını çalıştırır.
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
  -h          Bu yardım
  -V          Sürüm

Örnekler:
  $(basename "$0") csi-vol-8b2716cd-5655-41e7-99d2-5745902b0971
  $(basename "$0") -o json csi-vol-8b2716cd-5655-41e7-99d2-5745902b0971 > rapor.json
  $(basename "$0") -a -t 150
EOF
}

die()  { echo "HATA: $*" >&2; exit 1; }
info() { echo ">> $*" >&2; }

if [ "${1:-}" = "--help" ]; then usage; exit 0; fi

while getopts ":n:p:r:o:t:T:avhV" opt; do
  case "$opt" in
    n) ODF_NS="$OPTARG" ;;
    p) POOL="$OPTARG" ;;
    r) RADOS_NS="$OPTARG" ;;
    o) OUTPUT="$OPTARG" ;;
    t) THRESHOLD="$OPTARG" ;;
    T) TOP="$OPTARG" ;;
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

rbd() { oc -n "$ODF_NS" exec "$TOOLS" -- rbd "$@"; }

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
for f in snaps children desc; do
  [ -s "$TMP/$f.json" ] || echo '[]' > "$TMP/$f.json"
done

info "Eşleştiriliyor"
jq -n \
  --arg image "$IMAGE" --arg pool "$POOL" --arg radosns "$RADOS_NS" --arg driver "$DRIVER" \
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
          value: { owner: ([.metadata.ownerReferences[]? | "\(.kind)/\(.name)"] | join(",")),
                   labels: (.metadata.labels // {}) } } ]
    | from_entries ) as $pvcmap
  | ( reduce $vm[0].items[] as $v ({};
        reduce ( $v.spec.template.spec.volumes[]? | (.persistentVolumeClaim.claimName // .dataVolume.name // empty) ) as $c
          (.; .["\($v.metadata.namespace)/\($c)"] = $v.metadata.name) ) ) as $vmmap
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
        else $p + { vm: $vmmap["\($p.namespace)/\($p.pvc)"],
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
      or (($pvcmap["\($src.namespace)/\($src.pvc)"].labels // {}) | has("cdi.kubevirt.io/dataImportCron")) ) as $golden

  | {
      generated: (now | todate),
      image: $image, pool: $pool, rados_namespace: $radosns, driver: $driver,
      source: ( ($src // { note: "Bu image için PV bulunamadı (image orphan olabilir)" })
                + { parent: $info[0].parent, size: $info[0].size, golden_image: $golden,
                    datasources: $srcds, dataimportcrons: $srcdic } ),
      summary: {
        snapshots_total: ($snaplist | length),
        snapshots_by_type: ($snaplist | group_by(.type) | map({ key: .[0].type, value: length }) | from_entries),
        children_direct: ($direct | length),
        descendants_total: ($kids | length),
        descendants_by_kind: $bykind,
        vms_using_clones: $vmcount
      },
      snapshots: $snaplist,
      children: $kids,
      source_volumesnapshots: $srcvs,
      rbd_volumesnapshots_by_namespace: $nsvs,
      hints: [
        ( select($vmcount > 0 or $golden)
          | "CNV: \($vmcount) VM bu image\u0027dan clone edilmiş disk kullanıyor\(if $golden then " (golden image)" else "" end). Kullanılmayan VM\u0027leri silin veya seçili VM disklerini flatten edin; yeni VM\u0027ler için golden image yenilemesini kontrol edin (README: Senaryo A)." ),
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

if [ "$OUTPUT" = "json" ]; then
  cat "$TMP/report.json"
  exit 0
fi

jq -r --argjson top "$TOP" --argjson verbose "$VERBOSE" '
  def pad($n): tostring | if length >= $n then . else . + (" " * ($n - length)) end;
  def nz: if . == null or . == "" then "-" else . end;
  def kv: to_entries | map("\(.key)=\(.value)") | join("  ");
  def row: "  \(.image | pad(48)) \(.kind | pad(19)) \("\(.namespace | nz)/\(.pvc // .vs | nz)" | pad(45)) \(.vm | nz)\(if .note then "  # " + .note else "" end)";

  "=== HighRBDCloneSnapshotCount analizi (\(.generated)) ===",
  "Image          : \(.pool)/\(if .rados_namespace != "" then .rados_namespace + "/" else "" end)\(.image)",
  "PV / PVC       : \(.source.pv | nz)  \(.source.namespace | nz)/\(.source.pvc | nz)",
  "VM / Owner     : \(.source.vm | nz)  \(.source.owner | nz)",
  "Parent         : \(if .source.parent then "\(.source.parent.pool)/\(.source.parent.image)@\(.source.parent.snapshot)" else "-" end)",
  "Golden image   : \(if .source.golden_image then "EVET" else "hayır" end)",
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
