# Ag Kontrol - iPad ve iPhone

Gercek iOS uygulamasi: yerel IPv4, ag baglanti yolu, genel IP, HTTPS gecikmesi, DNS cozumleme, yaklasik indirme hizi ve tani raporu.

## Ne yapar?

- **Canli baglanti yolu:** Network framework ile Wi-Fi/hucresel/Ethernet yolu ve dusuk veri modunu gosterir.
- **Yerel IPv4:** `getifaddrs` ile mevcut arayuzlerden okur.
- **Genel IP:** Kullanici butona bastiginda `api.ipify.org` uzerinden sorgular.
- **HTTPS gecikmesi:** Cloudflare uzerinde uc kucuk HTTPS isteginin ortalama toplam yanit suresini olcer. **ICMP ping DEGILDIR**.
- **DNS:** Cihazin sistem cozumleyicisi `getaddrinfo` ile alan adini cozerek IP adreslerini gosterir; sure onbellekten etkilenebilir.
- **Yaklasik indirme hizi:** Kullanici ayri butona bastiginda `speed.cloudflare.com/__down` adresinden yaklasik 2 MB indirir. Bu tek baglantili hiz gostergesi, resmi/ayrintili hiz testi degildir.
- **Raporu kopyalama:** Sonuc metnini cihaz panosuna kopyalar.

Uygulama bir hizmete kayit olmaz, sunucu tarafinda kullanici verisi tutmaz. Kontroller sadece butona basinca ag istegi yapar. Genel IP ve Cloudflare istekleri, bu servisler tarafindan gorulebilir. Mobil veri kullanimi icin kullanim ucreti olabilir.

## Sinirlar

- Gercek ICMP ping, Wi-Fi kanal tarama, router icin varsayilan ag gecidi ve baska cihazlari tarama bu surumde **yok**. Apple iOS ag API'leri ile bu islevler masaustu bilgisayarlarindan farklidir.
- `NWPathMonitor.status == satisfied` yalnizca kullanilabilir bir ag yolu oldugunu gosterir, internetin garanti oldugunu **soylemez**.
- Yerel IP aktif VPN ve arayuzlere gore degisebilir.
- Siri/Location/Local Network ayricalikli izinleri talep edilmez.

## Windows'tan IPA olusturma (GitHub Actions)

1. GitHub'da `AgKontrol-iOS` adinda bos repository olustur (`README` olusturmayin).
2. Bu ZIP'i ayiklayip klasor icerigini repository'ye yukleyin. ZIP'i tek dosya olarak yuklemeyin.
3. **Onemli:** `.github/workflows/ipados.yml` dosyasinin tam yolu GitHub'da bu sekilde olmali. Yukleme sirasinda `ipados.yml` kok dizine dustuyse GitHub Edit>Rename ile bu yola tasiyin.
4. `Commit changes` ile kaydedin.
5. **Actions > Ag Kontrol iOS IPA** sonucunu acin. Success ise run sayfasinin altindaki **Artifacts > AgKontrol-iOS-IPA** dosyasini ZIP olarak indirin.
6. ZIP'ten `AgKontrol-unsigned.ipa` dosyasini cikarin.
7. **Sideloadly** ile imzalayip iPad veya iPhone'a kurun. Ucretsiz Apple ID ile imzanin yenilenmesi genellikle 7 gunde bir gerekir.

## Dosya yapisi

```text
AgKontrol_iOS_Proje/
  .github/workflows/ipados.yml
  AgKontrol/Sources/AgKontrolApp.swift
  AgKontrol/Assets.xcassets/
  project.yml
  README.md
```

## Derleme

`project.yml`, XcodeGen tarafindan Xcode projesine cevrilir. Workflow `macos-15` ustunde `xcodebuild` ile iPhone ve iPad icin imzasiz IPA paketi uretir. Yerel macOS/Xcode olmadan Linux container'da cihaz derlemesi dogrulanamaz; gercek test GitHub Actions'ta gerceklesir.
