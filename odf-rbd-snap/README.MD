# odf-rbd-snap: HighRBDCloneSnapshotCount runbook

OpenShift Data Foundation (ODF) şu alarmı üretiyor:

> RBD clones/snapshots count has exceeded 200 for image `csi-vol-…` under namespace openshift-storage.

Bu klasör, alarmın sebebini bulmak ve gidermek için gereken araçları içerir. Bağımsızdır; başka bir projeye bağımlılığı yoktur.

| Dosya | Açıklama |
|---|---|
| `rbd-snap-report.sh` | Analiz scripti. Varsayılan olarak salt okunurdur; yalnızca `-X` verilirse flatten planını uygular. |
| `README.md` | Bu runbook. |

---

## 1. Alarmın anlamı

- Bir RBD image'ının **snapshot + clone (child)** sayısı eşiği (200) aşmış. Eşiği ve ifadeyi cluster'dan doğrulayın:

  ```bash
  oc get prometheusrule -n openshift-storage -o yaml | grep -B2 -A15 HighRBDCloneSnapshotCount
  ```

- Mesajdaki `openshift-storage`, alarmı üreten ODF namespace'idir. PVC'nin bulunduğu namespace bu olmayabilir.
- ceph-csi'de her PVC clone'u ve her VolumeSnapshot, kaynak image'ın altında bir **child image** oluşturur:
  - **PVC → PVC clone (CNV dahil):** `csi-vol-<uuid>-temp` ara image'ı, onun altında `csi-vol-<uuid>` diski.
  - **VolumeSnapshot:** `csi-snap-<uuid>` image'ı. Bu snapshot'tan restore edilen PVC'ler de onun altına bağlanır.
  - **Kaynak image'daki snapshot'lar:** Kaynak tarafında silinen snapshot'lar, clone'ları yaşadığı sürece `trash` namespace'inde kalır.
- **Etkisi:** Çok sayıda child ve snapshot, OSD'lerde metadata yükünü ve I/O gecikmesini artırır. Silme, flatten ve yeni clone/snapshot işlemlerini yavaşlatır.

## 2. Ön koşullar

- `oc` (cluster-admin) ve `jq`
- rook-ceph-tools pod'u. Yoksa açmak için:

  ```bash
  oc patch ocsinitialization ocsinit -n openshift-storage --type json \
    --patch '[{"op":"replace","path":"/spec/enableCephTools","value":true}]'
  oc -n openshift-storage get pod -l app=rook-ceph-tools
  ```

Manuel `rbd` komutları için kısayol:

```bash
TOOLS=$(oc -n openshift-storage get pod -l app=rook-ceph-tools -o name | head -1)
POOL=ocs-storagecluster-cephblockpool
IMG=csi-vol-8b2716cd-5655-41e7-99d2-5745902b0971
rbd() { oc -n openshift-storage exec "$TOOLS" -- rbd "$@"; }
```

## 3. Teşhis

```bash
chmod +x rbd-snap-report.sh

# Alarmdaki image
./rbd-snap-report.sh csi-vol-8b2716cd-5655-41e7-99d2-5745902b0971

# Tüm child'ları tek tek göster
./rbd-snap-report.sh -v csi-vol-8b2716cd-5655-41e7-99d2-5745902b0971

# JSON çıktı (arşiv / jq ile filtreleme için)
./rbd-snap-report.sh -o json csi-vol-8b2716cd-5655-41e7-99d2-5745902b0971 > rapor.json

# Pool'daki diğer riskli image'lar (toplam >= 150)
./rbd-snap-report.sh -a -t 150
```

Seçenekler:

- `-n` ODF namespace'i, `-p` pool, `-r` RADOS namespace'i
- `-T` liste uzunluğu
- `-L` alarm eşiği (varsayılan 200)
- `-N` flatten planındaki aday sayısı
- `-F` sadece flatten komutlarını yazdır
- `-X` / `--execute` flatten planını tek tek uygula (`-y` onay atla, `-s` bekleme sn, `-m` en düşük boş alan %)
- `-h` yardım

ceph-csi limitleri varsayılandan farklıysa `CSI_MIN_SNAPS` ve `CSI_MAX_SNAPS` ortam değişkenleriyle verilebilir.

Script'in yaptıkları:

1. Image'ı **PV → PVC → owner (DataVolume) → VirtualMachine** zincirine eşleştirir.
2. Kaynağın golden image olup olmadığını tespit eder:
   - CNV'nin yönettiği golden image ise ilgili **DataSource** ve **DataImportCron** kayıtlarını gösterir.
   - Custom bir template PVC'yse (kendisi VM diski değil, VM'lerin clone kaynağı) bunu ayrıca belirtir.
   - ceph-csi'nin otomatik flatten limitlerine (250/450) göre durumu, mgr kuyruğundaki flatten görevlerini ve bir **flatten planını** (adaylar + tahmini kapasite) gösterir.
3. `rbd snap ls --all` ve `rbd children --all --descendants` ile snapshot'ları ve child'ları listeler. Her child şu türlerden birine atanır:

| Tür | Anlamı |
|---|---|
| `pvc-clone` | PV'si olan bir PVC'nin diski. Varsa VM adı da gösterilir. |
| `clone-intermediate` | ceph-csi'nin `-temp` ara clone image'ı (hedef PVC'ye eşlenir). |
| `volumesnapshot` | Bir VolumeSnapshot'a ait `csi-snap-*` image'ı. |
| `vsc-only` | VolumeSnapshotContent duruyor ama VolumeSnapshot silinmiş (genelde `deletionPolicy: Retain`). |
| `orphan` | Ceph'te var, Kubernetes'te karşılığı yok. |
| `trash` | Image RBD trash'e taşınmış, kendi child'larının silinmesini bekliyor. |

4. Kaynak PVC'den alınmış VolumeSnapshot'ları (en eskiden yeniye) ve namespace bazında RBD VolumeSnapshot sayılarını gösterir.
5. Bulgulara göre aşağıdaki senaryolara yönlendiren öneriler üretir.

Faydalı `jq` filtreleri:

```bash
jq -r '.children[] | select(.kind=="orphan") | .image' rapor.json
jq -r '.children[] | select(.vm) | "\(.namespace)/\(.vm)"' rapor.json | sort -u
jq -r '.source_volumesnapshots[] | "\(.created) \(.name)"' rapor.json
```

> Not: Kaynak image'ın PV'si yoksa (rapor "PV bulunamadı" der), bu genellikle **eski bir golden image**'dır. DataImportCron yeni sürümü import ettiğinde eski PVC silinir, fakat child'ları olduğu için RBD image Ceph'te kalır. Child'lar yine de raporda VM'lerine eşlenir.

---

## 4. Düzeltme

> Genel kural: Temizlik **önce Kubernetes nesneleri üzerinden** yapılır (VM, DataVolume, PVC, VolumeSnapshot). ceph-csi'nin yönettiği image ve snapshot'ları `rbd rm` veya `rbd snap rm` ile doğrudan silmek PV ve VolumeSnapshotContent nesnelerini bozar. Doğrudan `rbd` müdahalesini yalnızca Senaryo D'de, doğrulamadan sonra yapın; mümkünse Red Hat desteğiyle teyit edin.

Her adımdan önce kapasiteyi ve sağlığı kontrol edin:

```bash
oc -n openshift-storage exec "$TOOLS" -- ceph -s
oc -n openshift-storage exec "$TOOLS" -- ceph df
```

### Senaryo A: CNV golden image veya custom template'den çok sayıda VM clone'lanmış

Raporda çok sayıda `clone-intermediate` / `pvc-clone` child görürsünüz ve VM adları dolu olur. `Golden image` satırı iki tür kaynağı ayırt eder:

- **`EVET (DataSource/DataImportCron)`:** CNV'nin otomatik import ettiği golden image.
- **`EVET (custom template PVC)`:** Kendisi bir VM diski olmayan, ama VM'lerin clone kaynağı olarak kullanılan PVC. Örnek: `os-templates/template-debian-12-latest`.

#### ceph-csi'nin snapshot limitleri (önemli)

ceph-csi, bir PVC'yi clone'larken kaynak image'da bir snapshot oluşturur ve bunu hemen trash'e taşır. Bu yüzden raporda kaynakta her VM için **bir `trash` snapshot** ve **bir `-temp` child** görürsünüz. Kaynaktan **yeni bir clone** oluşturulurken ceph-csi kaynaktaki snapshot sayısını kontrol eder:

| Durum | ceph-csi davranışı |
|---|---|
| sayı > `minsnapshotsonimage` (varsayılan **250**) | Tüm `-temp` child'lar için Ceph mgr'a flatten görevi (`ceph rbd task add flatten`) ekler; clone işlemi devam eder. |
| sayı > `maxsnapshotsonimage` (varsayılan **450**) | Aynı flatten görevlerini ekler, ama clone işlemini **`ResourceExhausted`** hatasıyla reddeder. Bu kaynaktan yeni VM oluşturulamaz. |

Kaynak: ceph-csi `flattenTemporaryClonedImages` (internal/rbd/controllerserver.go).

Rapordaki **"ceph-csi otomatik flatten durumu"** bölümü mevcut durumu gösterir. **Soft limit aşıldıysa**, şablondan oluşturulacak bir sonraki VM, yüzlerce flatten görevini aynı anda kuyruğa ekletir. Bu ani kapasite ve I/O yükü demektir. Bunu beklemeden kontrollü flatten yapın.

Kuyruktaki görevleri izlemek için:

```bash
oc -n openshift-storage exec "$TOOLS" -- ceph rbd task list
```

#### 1. Kullanılmayan VM'leri temizleyin

VM silindiğinde DataVolume ve PVC de silinir; ceph-csi child image'ı ve ona ait trash snapshot'ı kaldırır:

```bash
jq -r '.children[] | select(.vm) | "\(.namespace) \(.vm) \(.vm_status)"' rapor.json | sort -u
oc delete vm <vm> -n <ns>
```

#### 2. Kalacak VM disklerini kaynaktan ayırın (flatten)

Flatten, child'ın verisini kendine kopyalar ve parent bağını koparır. Her flatten edilen `-temp` child, kaynaktaki **child sayısını ve trash snapshot sayısını birer azaltır**.

Script, alarm eşiğinin altına inmek için gereken sayıda adayı seçer. Sıralama:

1. Durdurulmuş VM'ler
2. VM'e bağlı olmayan PVC'ler
3. Çalışan VM'ler

Her grupta en eski PVC önce gelir. Mgr kuyruğunda zaten bekleyen görevler gereken sayıdan düşülür.

Planı iki şekilde uygulayabilirsiniz.

**Önerilen: script'in kendisiyle (`-X` / `--execute`)**

```bash
# 1. Planı görün
./rbd-snap-report.sh -F csi-vol-8b2716cd-5655-41e7-99d2-5745902b0971

# 2. Parça parça çalıştırın (ör. her seferinde 20 image)
./rbd-snap-report.sh -X -N 20 csi-vol-8b2716cd-5655-41e7-99d2-5745902b0971

# Seçenekler: -s 30 (iki flatten arası 30 sn), -m 40 (boş alan %40'ın altına düşerse dur), -y (onay sorma)
```

`-X` modunun davranışı:

- **Onay:** Başlamadan önce planı gösterir ve onay için **kaynak image adını** yazmanızı ister. `-y` ile bu adım atlanır.
- **Her image için tek tek:**
  1. Pool boş alanını kontrol eder (`ceph df`). Varsayılan eşik **%50**; altındaysa durur. `-m 0` kontrolü kapatır.
  2. Image'ın hâlâ parent'ı olup olmadığına bakar. Parent yoksa image zaten flatten edilmiştir, atlanır.
  3. `rbd flatten` çalıştırır ve parent'ın kalktığını doğrular.
  4. Bir sonraki image'dan önce bekler (varsayılan **10 sn**, `-s` ile değişir).
- **Hata:** İlk hatada durur ve exit kodu 1 döner. Tekrar çalıştırdığınızda plan yeniden hesaplanır; tamamlanmış image'lar zaten plana girmez.
- **Ctrl-C:** Durdurur ve özet basar. Bir flatten tam çalışırken kesilirse, o image'ı `rbd info` ile kontrol edin.
- **Log:** Her adım ekrana ve `./rbd-flatten-<image>-<tarih>.log` dosyasına yazılır. Bitişte yapılan/atlanan/hata sayıları ve kaynaktaki yeni snapshot/child sayıları gösterilir.
- **Ne yapmaz:** Trash'teki snapshot'lara dokunmaz. VM disklerinin kendisini (`csi-vol-<uuid>`) değil, aradaki `-temp` image'ları flatten eder. VM'ler çalışmaya devam eder.

**Alternatif: komut dosyası üretip elle çalıştırmak**

```bash
# Plan (komutları yalnızca yazdırır, çalıştırmaz)
./rbd-snap-report.sh -F csi-vol-8b2716cd-5655-41e7-99d2-5745902b0971 > flatten-plan.sh
./rbd-snap-report.sh -F -N 100 csi-vol-…   # eşik yerine sabit 100 aday
./rbd-snap-report.sh -F -L 150 csi-vol-…   # hedef: 150'nin altı

# Gözden geçirin, kapasiteyi kontrol edin, sonra çalıştırın
less flatten-plan.sh
oc -n openshift-storage exec "$TOOLS" -- ceph df
bash flatten-plan.sh
```

Dikkat edilecekler:

- **Kapasite:** Flatten, thin olan clone'a kaynak image'ın verisini kopyalar. Raporda "Tahmini ek kapasite" satırı `kaynak used_size × adet` olarak bir üst sınır verir. Replica 3 pool'da ham kullanım bunun 3 katıdır.
- **I/O:** Flatten online yapılabilir (VM çalışırken), ama ek yük oluşturur. Planı mesai dışında çalıştırın ve parçalara bölün (`-X -N 20` veya `head -n 30 flatten-plan.sh`).
- **Kontrol:**

  ```bash
  rbd info "$POOL/csi-vol-<uuid>-temp" | grep parent   # çıktı boş olmalı
  ./rbd-snap-report.sh csi-vol-8b2716cd-5655-41e7-99d2-5745902b0971   # sayılar düşmeli
  ```

#### 3. Yeni VM'lerin aynı kaynağa birikmesini önleyin

**DataImportCron ile yönetilen golden image:** DataImportCron'un düzenli çalıştığını kontrol edin (`lastImport`, `schedule`). Yeni import'tan sonra yeni VM'ler yeni kaynağa bağlanır.

**Custom template PVC:** Template'i periyodik olarak **yeni bir sürüme döndürün**. Örneğin VM sayısı ~150'ye ulaştığında:

1. Mevcut template'ten yeni bir PVC oluşturun (ör. `template-debian-12-v2`). Bunu bir DataVolume ile, `source.pvc` olarak mevcut template'i göstererek yapın.
2. Yeni PVC'nin `-temp` image'ını `rbd flatten` ile flatten edin. Böylece yeni template eskisinden tamamen bağımsız olur.
3. VM oluşturma akışını (OpenShift Template, GitOps manifestleri, DataVolume `source.pvc`) yeni PVC'ye çevirin.
   - Önerilen yöntem: Template'e bir **DataSource** üzerinden erişin (`sourceRef: {kind: DataSource, name: debian-12, namespace: os-templates}`).
   - Bu durumda rotasyon için yalnızca DataSource'un `spec.source.pvc` alanını güncellemek yeterlidir.
4. Eski template'e bağlı VM'ler çalışmaya devam eder. Eski image'ın sayısı sabit kalır, artmaz.

**Alternatif:** İlgili StorageProfile'da `spec.cloneStrategy: copy` (host-assisted clone) kullanın. Bu durumda clone'lar parent'a hiç bağlanmaz. Dezavantajları: clone daha yavaştır, her disk tam boyutta yer kaplar ve ayar o StorageClass'ı kullanan **tüm** clone'ları etkiler.

```bash
oc get storageprofile <storageclass> -o yaml
```

### Senaryo B: Uygulama VolumeSnapshot'ları birikmiş

Raporda `volumesnapshot` child'ları ve "Bu PVC kaynaklı VolumeSnapshot'lar" listesi dolu olur.

1. Snapshot'ları eskiden yeniye listeleyin:

   ```bash
   oc get volumesnapshot -n <ns> --sort-by=.metadata.creationTimestamp \
     -o custom-columns=NAME:.metadata.name,PVC:.spec.source.persistentVolumeClaimName,CREATED:.metadata.creationTimestamp,READY:.status.readyToUse
   ```

2. Snapshot'ları kimin oluşturduğunu tespit edin: `ownerReferences`, label'lar ve uygulama ya da CronJob'lar. Sonra gereksiz olanları silin:

   ```bash
   oc delete volumesnapshot <snapshot> -n <ns>
   ```

   VolumeSnapshotClass'ın `deletionPolicy` değeri `Delete` ise Ceph tarafı da temizlenir:

   ```bash
   oc get volumesnapshotclass -o custom-columns=NAME:.metadata.name,DRIVER:.driver,POLICY:.deletionPolicy
   ```

3. **Kalıcı çözüm:** Snapshot'ı oluşturan uygulamada veya CronJob'da retention tanımlayın, ör. "son N snapshot'ı tut". Image başına toplam sayı 200'ün altında kalmalı.
4. Bu PVC'den restore edilmiş PVC'ler varsa, onlar da `csi-snap-*` image'ının child'ıdır. Uzun ömürlü olanları Senaryo A'daki gibi flatten etmeyi değerlendirin.

### Senaryo C: `vsc-only` (sahipsiz VolumeSnapshotContent)

VolumeSnapshot silinmiş ama `deletionPolicy: Retain` olduğu için VolumeSnapshotContent ve Ceph'teki snapshot kalmış.

1. Bu kaydın bilerek tutulup tutulmadığını doğrulayın (DR, yedek, manuel saklama vb.).
2. Gerekli değilse önce policy'yi `Delete` yapın, sonra VSC'yi silin. Ceph tarafındaki snapshot da silinir:

   ```bash
   oc patch volumesnapshotcontent <vsc> --type merge -p '{"spec":{"deletionPolicy":"Delete"}}'
   oc delete volumesnapshotcontent <vsc>
   ```

### Senaryo D: `orphan` veya `trash` kayıtlar

**`trash`:** ceph-csi, child'ı olan bir image'ı silerken onu RBD trash'e taşır. Image, son child'ı da gidince otomatik temizlenir. Genelde müdahale gerekmez; asıl çözüm, o image'ın child'larını (Senaryo A/B) temizlemektir.

```bash
rbd trash ls --all "$POOL"
```

**`orphan`:** Ceph'te olup Kubernetes'te karşılığı olmayan image. Silmeden önce şunları **mutlaka** doğrulayın:

1. Image başka bir cluster'a ait olmasın. Bunu özellikle external mode, aynı pool'u paylaşan cluster'lar ve Regional/Metro DR (mirroring) kurulumlarında kontrol edin:

   ```bash
   rbd mirror image status "$POOL/<image>" 2>/dev/null
   ```

2. Image'ı kullanan bir client olmasın. `Watchers: none` görmelisiniz:

   ```bash
   rbd status "$POOL/<image>"
   ```

3. Image'ın kendi child'ı veya snapshot'ı olmasın:

   ```bash
   rbd children --all "$POOL/<image>"
   rbd snap ls --all "$POOL/<image>"
   ```

4. Image'ı başka namespace'lerde veya PV'lerde de arayın (ör. `oc get pv -o yaml | grep <uuid>`). Script, cluster'daki tüm PV ve VolumeSnapshotContent'leri zaten tarar.

Doğrulandıktan sonra image'ı önce **geri alınabilir** şekilde trash'e taşıyın. Bir süre gözlemleyin, sorun yoksa kalıcı olarak silin:

```bash
rbd trash mv "$POOL/<image>"
rbd trash ls "$POOL"                      # ID'yi not edin
# Geri almak için:  rbd trash restore "$POOL/<id>"
# Kalıcı silmek için (gözlemden sonra):  rbd trash rm "$POOL/<id>"
```

> Orphan `csi-snap-*` image'larının kendi üzerlerinde de bir snapshot'ı ve restore edilmiş child'ları olabilir. Bu durumda önce o child'ları ele alın. Emin değilseniz Red Hat desteğine `odf-must-gather` ve script'in JSON çıktısıyla başvurun.

---

## 5. Doğrulama

```bash
./rbd-snap-report.sh csi-vol-8b2716cd-5655-41e7-99d2-5745902b0971   # toplam < 200 olmalı
oc -n openshift-storage exec "$TOOLS" -- ceph health detail
```

- Console'da **Observe → Alerting** ekranında `HighRBDCloneSnapshotCount` alarmının kapandığını kontrol edin. Metrik periyodik toplandığı için kapanması birkaç dakika sürebilir.
- Flatten veya silme işlemlerinden sonra `ceph df` ile kapasiteyi tekrar kontrol edin.

## 6. Kalıcı önlemler

- **Periyodik tarama:** `./rbd-snap-report.sh -a -t 150 -o json` komutunu bir cron/CI job'ında çalıştırın. Eşiğe yaklaşan image'ları alarm gelmeden yakalayın.
- **VolumeSnapshot retention:** Snapshot alan her uygulama veya job için "son N" kuralı tanımlayın. VolumeSnapshotClass `deletionPolicy` değerinin `Delete` olduğundan emin olun.
- **Custom template'ler:** Template'e DataSource üzerinden erişin ve VM sayısı ~150'ye ulaştığında template'i yeni bir sürüme döndürün (Senaryo A, adım 3). Snapshot sayısını ceph-csi soft limitinin (250) altında tutun.
- **CNV:** DataImportCron'ların düzenli çalıştığını izleyin. Uzun ömürlü ve çok sayıda VM aynı kaynaktan üretiliyorsa bu VM'lerin disklerini periyodik olarak flatten edin. Kullanılmayan VM'leri temizleyin.
- **Kayıt:** Her müdahaleden önce ve sonra `-o json` çıktısını arşivleyin.
