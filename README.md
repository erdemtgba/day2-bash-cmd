# ACM Day-2 Label Generator

`acm-day2-label-generator.sh`, `acm-sot` içindeki policy overlay ve base
dizinlerini analiz ederek Hub cluster üzerinde çalıştırılacak
`oc label managedcluster` komutlarını üretir.

## Kullanım

```bash
chmod +x acm-day2-label-generator.sh
./acm-day2-label-generator.sh --repo /path/to/acm-sot --output labels.sh
```

Repo yolu `--repo` yerine `ACM_SOT_REPO` ortam değişkeniyle de verilebilir:

```bash
ACM_SOT_REPO=/path/to/acm-sot ./acm-day2-label-generator.sh
```

`whiptail` veya `dialog` bulunmuyorsa script standart `read` tabanlı CLI
akışına geçer. Gerçek repo yolu verilmezse lokal testler için istenen örnek
policy ağacını temsil eden mock envanter kullanılır.

Ortam seçimi bir kez yapılır. Seçilen ortamla aynı ada sahip overlay mevcutsa
ilgili policy otomatik seçilir; ortamla eşleşmeyen çoklu overlay'ler için
ayrıca menü gösterilir. Overlay bulunmayan policy'ler `sot/<policy>=base`
etiketiyle üretilir.
