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

فایل‌های پروژه را روی هر دو سرور کپی کنید (مثلاً با `git clone` یا `scp` کل پوشه).

### گام ۱ — روی سرور **خارج** (EXIT، ۸۳)

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

همین کارها با خط فرمان هم ممکن است:
```bash
whmcs-proxy status
whmcs-proxy useradd myuser --apply
whmcs-proxy passwd whmcs --apply
whmcs-proxy list-users
whmcs-proxy set-port https 8443 --apply
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

## ۸) اگر تانل به خارج فیلتر شد (پلن B)

حالت پیش‌فرض (`relay+tls`) معمولاً کار می‌کند. اگر هاپِ ایران→خارج مختل شد، سراغ ترنسپورت
مقاوم‌تر بروید (WebSocket روی TLS، قابل عبور از CDN). راهنما در
[`docs/TROUBLESHOOTING.md`](TROUBLESHOOTING.md) بخش «Tunnel resilience».

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
