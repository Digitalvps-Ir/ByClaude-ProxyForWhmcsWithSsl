# راهنمای کامل — پروکسی SSL برای WHMCS (SOCKS + HTTPS)

این پروژه یک پروکسی **SOCKS5 و HTTPS با SSL معتبر** برای WHMCS می‌سازد که خطاهایی مثل
`cURL error 35: OpenSSL SSL_connect: SSL_ERROR_SYSCALL` را از بین می‌برد و درخواست‌های
ماژول‌های پرداخت (مثل CryptoExchangePay که به `bsc-dataseed*.binance.org` وصل می‌شود) را
از ایران به خارج می‌رساند.

---

## ۱) معماری (چطور کار می‌کند)

```
 WHMCS ──(HTTPS/SOCKS، آی‌پی ایران، SSL معتبر)──▶  سرور ورودی (ENTRY / ایران، ۱۰۹)
                                                        │
                                                        │  تانل رمزنگاری‌شده‌ی TLS (relay + mux)
                                                        ▼
                                                   سرور خروجی (EXIT / خارج، ۸۳) ──▶ اینترنت / Binance
```

- **سرور ایران (ENTRY):** همان جایی است که یوزر/پسورد/پورت پروکسی را در WHMCS وارد می‌کنید.
  آی‌پی ایران دارد، گواهی SSL معتبر دارد، و ترافیک را از داخل تانل به سرور خارج می‌فرستد.
- **سرور خارج (EXIT):** فقط انتهای تانل است و به اینترنت وصل می‌شود (Binance و…).
- **تانل:** با **gost v3** ساخته می‌شود؛ تک‌باینری Go، سبک، پرسرعت، مالتی‌پلکس، و روی TLS با
  گواهی معتبر (شبیه ترافیک عادی HTTPS، مقاوم‌تر در برابر اختلال).

> چرا gost و نه leproxy؟ leproxy (Node.js) یک پروکسی TLS ساده و خوب است، اما نه تانل
> سرور‑به‑سرورِ مالتی‌پلکس‌شده دارد و نه ترنسپورت‌های ضدفیلتر. برای «تانل پرسرعت بین دو
> سرور» gost سبک‌تر (بدون رانتایم Node)، سریع‌تر و منعطف‌تر است (tls / ws / wss / CDN).

---

## ۲) چرا SSL به «ساب‌دامین» نیاز دارد؟

گواهی معتبر (Let's Encrypt) فقط برای یک **نام دامنه** صادر می‌شود، نه برای IP خام.
وقتی WHMCS با cURL به پروکسی وصل می‌شود، گواهی را با **نامی که به آن وصل شده** مقایسه می‌کند
(بررسی SNI و hostname). اگر با IP وصل شوید، این تطبیق شکست می‌خورد و همان خطای SSL برمی‌گردد.

پس به دو ساب‌دامین نیاز داریم (نمونه):

| نقش | ساب‌دامین نمونه | باید به کدام سرور اشاره کند |
|-----|------------------|------------------------------|
| ENTRY (ایران) | `proxy.digitalvps.ir` | `109.122.244.5` |
| EXIT (خارج)   | `tunnel.digitalvps.ir` | `83.245.45.6` |

هر دو رکورد **A** ساده هستند (بدون پروکسی ابری/نارنجیِ Cloudflare در حالت پیش‌فرض تا صدور
گواهی با روش HTTP ساده باشد). فقط این دو رکورد را در DNS بسازید.

> نکته درباره‌ی لاگ شما: آدرس `185.118.15.125` یک آی‌پی **داخل ایران** است و اتصال TLS به آن
> حتی به‌صورت داخلی هم RST می‌خورد — یعنی پروکسی فعلی‌تان اصلاً TLS سالم سرو نمی‌کرده (خراب یا
> غلط‌کانفیگ). این پروژه آن هاپ را با گواهی معتبر و سرویس درست بازسازی می‌کند.

---

## ۳) پیش‌نیازها

- دو سرور Ubuntu/Debian با دسترسی root (شما دارید: ۱۰۹ ایران، ۸۳ خارج).
- دو ساب‌دامین طبق جدول بالا.
- پورت **۸۰/TCP** روی هر سرور موقتاً باز باشد (برای صدور گواهی). اگر نمی‌شود، از روش
  `--cert-mode dns-cloudflare` استفاده کنید (پایین توضیح داده شده).

---

## ۴) نصب — گام به گام

### روش سریع (نصب تک‌خطی از گیت‌هاب)

روی هر سرور، به‌صورت root این یک خط را بزنید؛ خودش پروژه را کلون و نصب می‌کند و چند سؤال می‌پرسد:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Digitalvps-Ir/ByClaude-ProxyForWhmcsWithSsl/claude/whmcs-proxy-ssl-setup-obed47/install.sh)
```

> اگر خطای **404** گرفتید، یعنی ریپو **private** است (raw برای ریپوی خصوصی ۴۰۴ می‌دهد).
> دو راه دارید:
> - **ساده‌ترین:** ریپو را public کنید (هیچ رمز/سکرتی داخلش نیست) و همان یک‌خط را دوباره بزنید؛ یا
> - با یک **توکن read-only** کلون کنید و محلی اجرا کنید (دیگر کلون مجدد نمی‌کند):
> ```bash
> git clone -b claude/whmcs-proxy-ssl-setup-obed47 \
>   https://<TOKEN>@github.com/Digitalvps-Ir/ByClaude-ProxyForWhmcsWithSsl.git
> cd ByClaude-ProxyForWhmcsWithSsl && sudo ./install.sh
> ```
> ساخت توکن: GitHub → Settings → Developer settings → **Fine-grained tokens** → دسترسی
> فقط به همین ریپو با مجوز **Contents: Read-only**.

نصب‌کننده اول روی **سرور خارج (EXIT)** و بعد **سرور ایران (ENTRY)** اجرا می‌شود. اگر ترجیح
می‌دهید دستی و با فلگ‌ها اجرا کنید، ادامه را ببینید.

### روش دستی — گام ۱: روی سرور **خارج** (EXIT، ۸۳)

```bash
sudo ./setup.sh --role exit \
  --domain tunnel.digitalvps.ir \
  --email you@example.com
```

خروجی، مقادیر تانل را چاپ می‌کند (این‌ها را برای گام بعد نگه دارید):

```
--exit-host  tunnel.digitalvps.ir
--exit-port  8443
--tunnel-user tunnel
--tunnel-pass XXXXXXXXXXXXXXXXXXXX
```

### گام ۲ — روی سرور **ایران** (ENTRY، ۱۰۹)

با همان مقادیر تانلِ چاپ‌شده:

```bash
sudo ./setup.sh --role entry \
  --domain proxy.digitalvps.ir \
  --email you@example.com \
  --exit-host tunnel.digitalvps.ir \
  --tunnel-user tunnel \
  --tunnel-pass XXXXXXXXXXXXXXXXXXXX
```

در پایان، اطلاعاتی که در WHMCS وارد می‌کنید چاپ و در `/root/whmcs-proxy-credentials.txt`
ذخیره می‌شود:

```
HTTPS proxy : https://proxy.digitalvps.ir:443   (type=HTTPS)
SOCKS5      : socks5h://proxy.digitalvps.ir:1080
proxy user  : whmcs
proxy pass  : ....
DASHBOARD   : https://proxy.digitalvps.ir:9443  (admin/....)
```

همین. تمام.

---

## ۵) تنظیم در WHMCS / ماژول

در تنظیمات پروکسیِ ماژول (یا `configuration.php`) این مقادیر را بگذارید:

- **نوع پروکسی:** HTTPS
- **هاست:** `proxy.digitalvps.ir`
- **پورت:** `443`
- **یوزر/پسورد:** همان‌ها که چاپ شد

اگر ماژول فقط رشته‌ی cURL می‌گیرد:
```
https://whmcs:PASSWORD@proxy.digitalvps.ir:443
```
اگر ماژول فقط SOCKS دارد:
```
socks5h://whmcs:PASSWORD@proxy.digitalvps.ir:1080
```

جزئیات بیشتر و تست: فایل [`docs/WHMCS.md`](WHMCS.md).

### تست سریع قبل از WHMCS
از روی سرور ایران:
```bash
curl -x https://whmcs:PASSWORD@proxy.digitalvps.ir:443 -I https://bsc-dataseed4.binance.org/
```
یا با اسکریپت آماده:
```bash
examples/test-proxy.sh proxy.digitalvps.ir 443 whmcs 'PASSWORD'
php examples/whmcs-proxy-test.php https://whmcs:PASSWORD@proxy.digitalvps.ir:443
```

---

## ۶) داشبورد مدیریت (وب UI)

آدرس: `https://proxy.digitalvps.ir:9443` — با یوزر/پسورد ادمینی که چاپ شد.

از داشبورد می‌توانید:
- یوزرهای پروکسی را **بسازید/حذف/غیرفعال** کنید و پسورد را ریست کنید،
- **پورت‌ها** را عوض کنید،
- تنظیمات **تانل** به سرور خارج را ویرایش کنید،
- وضعیت سرویس و **تاریخ انقضای گواهی** را ببینید،
- و با دکمه‌ی **Apply** سرویس را با تنظیمات جدید ری‌استارت کنید.

> امنیت: پورت داشبورد را فقط به آی‌پی خودتان باز کنید:
> ```bash
> ufw allow from <آی‌پی-شما> to any port 9443 proto tcp
> ```

بخش **📜 Logs** داشبورد، درخواست‌های عبوری از پروکسی را نشان می‌دهد: **آی‌پی مبدأ**، یوزر،
سرویس (HTTPS/SOCKS)، مقصد و حجم — با رفرش خودکار.

می‌توانید یک **ساب‌دامین جدا برای داشبورد** هم تعریف کنید و حتی از داخل خود داشبورد
(بخش «Domains & SSL») ساب‌دامین پروکسی یا داشبورد را عوض کنید؛ گواهی جدید **خودکار** صادر و
همه‌جا اعمال می‌شود.

## ۶.۱) کنسول تحت SSH — دستور `whmcsproxy`

کافی است در SSH بزنید:

```bash
whmcsproxy
```

یک منوی کامل (شبیه پنل x-ui) باز می‌شود با گزینه‌ها:

```
 1) Status & endpoints          6) Tunnel (exit / transport / benchmark)
 2) Proxy users                 7) Network performance tuning (BBR)
 3) Ports                       8) Request logs (source IP → destination)
 4) Change proxy SSL subdomain  9) SSL (info / renew now / auto-renew)
 5) Change dashboard subdomain 10) Services   11) Credentials   12) Uninstall
```

گزینه‌ی ۴ و ۵ ساب‌دامین را عوض می‌کنند و **گواهی را خودکار صادر/جابجا و روی کل کانفیگ‌ها
اعمال** می‌کنند. بدون منو هم کار می‌کند:
```bash
whmcsproxy status
whmcsproxy useradd myuser --apply
whmcsproxy passwd whmcs --apply
whmcsproxy set-port https 8443 --apply
whmcsproxy benchmark            # پینگ/جیتر/پکت‌لاس/پهنای‌باند تانل
whmcsproxy logtail --limit 40   # لاگ درخواست‌ها
whmcsproxy migrate-proxy-domain proxy2.yourdomain.com you@mail.com standalone
```

---

## ۷) تمدید خودکار SSL (Auto-Renew)

نصب‌کننده این‌ها را **به‌صورت خودکار** فعال می‌کند:
- تایمر `certbot.timer` که روزی دو بار گواهی‌های نزدیک به انقضا را تمدید می‌کند،
- یک **hook** در `/etc/letsencrypt/renewal-hooks/deploy/` که بعد از هر تمدید، سرویس‌های
  `gost` و داشبورد را ری‌استارت می‌کند تا گواهی جدید بارگذاری شود.

هیچ کار دستی لازم نیست. برای تست:
```bash
certbot renew --dry-run
```

---

## ۸) پرفورمنس تانل (سرعت، پینگ، جیتر، پکت‌لاس)

نصب‌کننده برای بیشترین throughput و کمترین تأخیر این‌ها را **خودکار** انجام می‌دهد:
- **BBR** به‌عنوان congestion control + صف‌بندی **fq**،
- بافرهای سوکت بزرگ (تا ۶۴MB) برای لینک‌های راه‌دور،
- **TCP Fast Open**، غیرفعال‌کردن slow-start-after-idle، **MTU probing**، افزایش backlog و
  سقف فایل‌دیسکریپتور،
- **مالتی‌پلکس (mux)** روی تانل تا هر درخواست هندشیک TLS جدید نخواهد (تأخیر پایین‌تر) و
  **keepalive** تا تانل گرم بماند و قطعی/دراپ نداشته باشد.

اندازه‌گیری کیفیت تانل (روی سرور ایران):
```bash
whmcsproxy benchmark
```
خروجی شامل: پکت‌لاس و جیتر مسیر تا خروجی، **تأخیر و jitter درخواست از داخل تانل** (۲۰ نمونه)،
**پهنای‌باند** (دانلود ۱۰MB)، و آی‌پی خروجی که اینترنت می‌بیند.

اگر خواستید ترنسپورت را عوض کنید (مثلاً `wss` برای عبور از CDN):
```bash
whmcsproxy set-transport --transport wss --mux on --keepalive 15s --apply
```
(روی هر دو سرور یکسان تنظیم کنید.)

## ۹) دامنه روی CDN — ArvanCloud و Cloudflare

نکته‌ی مهم که حتماً رعایت کنید:

> **پروکسی forward و تانل از داخل CDN عبور نمی‌کنند.** هیچ CDN‌ای (نه آروان‌کلود نه کلادفلر)
> ترافیک CONNECT/SOCKS/تانلِ دلخواه را روی پورت دلخواه رله نمی‌کند. پس رکورد **A** ساب‌دامینِ
> **پروکسی** و **تانل** باید **DNS-only / ابر خاموش (Cloud OFF / grey-cloud)** باشد و مستقیم به
> آی‌پی سرور اشاره کند.

اما **گواهی SSL** را حتی وقتی دامنه‌تان روی این CDNها میزبانی می‌شود می‌توانید با **DNS-01**
بگیرید (به پورت ۸۰ هم نیاز ندارد). موقع نصب، cert-mode را انتخاب کنید:

- دامنه روی **Cloudflare**:
  ```bash
  sudo ./setup.sh --role entry --domain proxy.yourdomain.com \
    --cert-mode dns-cloudflare --cf-token <CLOUDFLARE_API_TOKEN> \
    --exit-host tunnel.yourdomain.com --tunnel-user U --tunnel-pass P
  ```
  توکن با دسترسی `Zone:DNS:Edit`.

- دامنه روی **ArvanCloud (arvancloud.ir)**:
  ```bash
  sudo ./setup.sh --role entry --domain proxy.yourdomain.ir \
    --cert-mode dns-arvan --arvan-token <ARVANCLOUD_API_KEY> \
    --exit-host tunnel.yourdomain.ir --tunnel-user U --tunnel-pass P
  ```
  کلید API را از پنل آروان‌کلود بردارید. اسکریپت خودکار رکورد `_acme-challenge` را از طریق
  API آروان می‌سازد، گواهی را می‌گیرد و رکورد را پاک می‌کند. اگر zone به‌درستی تشخیص داده
  نشد، با `ARVAN_ZONE=yourdomain.ir` آن را دستی بدهید. تمدید خودکار هم با همین هوک انجام می‌شود.

خلاصه‌ی CDN: **گواهی از طریق DNS-01 ✅ ، ولی رکورد پروکسی/تانل حتماً DNS-only باشد ✅**.
اگر تانل فیلتر شد، از `--transport wss` استفاده کنید تا شبیه ترافیک وب معمولی شود (بخش ۸).

---

## ۹) دستورات مفید

```bash
systemctl status gost                 # وضعیت تانل/پروکسی
journalctl -u gost -f                  # لاگ زنده
systemctl status whmcs-proxy-dashboard # وضعیت داشبورد
whmcs-proxy show-config                # کانفیگ نهایی gost
cat /root/whmcs-proxy-credentials.txt  # خلاصه و کلمات عبور
```

حذف کامل:
```bash
sudo ./uninstall.sh            # حذف سرویس‌ها و کانفیگ (گواهی می‌ماند)
sudo ./uninstall.sh --purge-certs --domain=proxy.digitalvps.ir
```
