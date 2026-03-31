# Odoo 16.0e Setup & Management Scripts

> Deployment Odoo modular yang siap produksi (production-ready) untuk Linux, macOS, dan Windows.

Script ini menyederhanakan seluruh proses setup Odoo 16.0 Enterprise dari nol hanya dalam satu perintah. Operasi yang di-handle secara otomatis meliputi ekstraksi artefak, instalasi dependensi, provisioning PostgreSQL, restorasi database, serta pengelolaan *lifecycle* service Odoo.

---

## 📋 Prasyarat Sistem

Sebelum menjalankan script, pastikan sistem Anda memenuhi persyaratan berikut:

| Platform | Kebutuhan Utama |
|----------|-----------|
| **Ubuntu/Debian** | Akses `sudo`, `apt-get`, Python 3 |
| **macOS** | Homebrew, PostgreSQL 16, Python 3 |
| **Windows** | PowerShell 5.1+, antarmuka CLI `psql.exe` (PostgreSQL bisa dipasang otomatis via script menggunakan `winget`) |

**Artefak yang Diperlukan:**
Letakkan minimal **salah satu** file instalasi Odoo berikut sejajar dengan direktori script:
- `odoo_*.tar.gz` — Tarball source Odoo (Linux/macOS)
- `odoo_*.deb` — Paket Debian (Ubuntu/Debian)
- `odoo_*.exe` — Installer Windows

*(Opsional)* Anda juga dapat menaruh:
- File Custom Addons: `*addons*.zip` atau folder berisi `__manifest__.py`.
- File Backup Database: `dump.sql`, `*.dump`, `*.backup`, atau `.zip` yang berisi aset dump.

---

## 🚀 Mulai Dari Sini

Untuk **Linux production**, jalur yang paling aman biasanya seperti ini:

1. Clone repo ke `/opt/odoo-cs`, bukan ke `/root/odoo-cs`.
2. Jalankan proses panjang dari `tmux` atau `screen`, terutama `fetch-start`.
3. Jika artefak masih ada di Google Drive, gunakan `fetch-start`.
4. Jika artefak sudah ada lokal, gunakan `bootstrap`.

Contoh baseline yang direkomendasikan:

```bash
apt-get update && apt-get install -y tmux git
cd /opt
git clone https://github.com/kungfufafa/odoo-cs.git
cd /opt/odoo-cs
tmux new -s odoo
```

> 📝 **Kenapa `/opt/odoo-cs`?** Path di bawah `/root` sering memunculkan warning akses `_apt`, menyulitkan service non-root, dan kurang ideal untuk auto-start setelah reboot.

### Step-by-Step Linux (User Biasa + sudo)

Jika Anda login sebagai user biasa yang **bukan root** tetapi punya `sudo`, ikuti urutan ini:

```bash
# 1. Install tool dasar
sudo apt-get update
sudo apt-get install -y tmux git rsync

# 2. Clone repo ke /opt
cd /opt
sudo git clone https://github.com/kungfufafa/odoo-cs.git
sudo chown -R $USER:$USER /opt/odoo-cs

# 3. Masuk ke workspace
cd /opt/odoo-cs

# 4. Buka session tmux
tmux new -s odoo

# 5A. Jika artefak masih di Google Drive
chmod +x setup_odoo.sh download_drive_folder.sh
./setup_odoo.sh fetch-start 'URL_FOLDER_GDRIVE'

# 5B. Jika artefak sudah ada lokal
chmod +x setup_odoo.sh
./setup_odoo.sh bootstrap
```

Setelah `tmux` terbuka:
- detach tanpa mematikan proses: `Ctrl+B`, lalu `D`
- masuk lagi ke session: `tmux attach -t odoo`
- lihat daftar session: `tmux ls`

Jika `/opt/odoo-cs` sudah ada dan sebelumnya dibuat oleh `root`, cukup rapikan ownership lalu lanjut:

```bash
sudo chown -R $USER:$USER /opt/odoo-cs
cd /opt/odoo-cs
tmux new -s odoo
./setup_odoo.sh bootstrap
```

## 🚀 Panduan Penggunaan

Pilih salah satu alur spesifik di bawah ini yang sesuai dengan kondisi server Anda:

### A. Alur Server Fresh (Semua Artefak dari Google Drive)
Gunakan ini jika Odoo installer, custom addons, dan backup database masih ada di Google Drive.

```bash
# 1. Clone repositori ke path shared
cd /opt
git clone https://github.com/kungfufafa/odoo-cs.git
cd /opt/odoo-cs

# 2. Jalankan dari tmux agar aman saat SSH putus
apt-get update && apt-get install -y tmux
tmux new -s odoo

# 3. Download + bootstrap + start Odoo
chmod +x setup_odoo.sh download_drive_folder.sh
./setup_odoo.sh fetch-start 'URL_FOLDER_GDRIVE'
```

Perintah `fetch-start` akan (fase download dan bootstrap berjalan linear di shell aktif):
- melakukan pre-flight check
- mengunduh artefak dari Google Drive
- install dependency sistem
- restore database dan filestore
- menjalankan post-restore hardening
- start Odoo lewat launcher terkelola (detached/background)
- melakukan healthcheck
- menampilkan access summary (kredensial login)

Mode `fetch-start` juga akan otomatis membuka Odoo ke `0.0.0.0:8069` bila `ODOO_HTTP_INTERFACE` belum diisi, sehingga setelah bootstrap selesai Anda bisa langsung akses lewat IP server. Selain itu, script akan memilih satu user Odoo aktif, mereset password browser-nya ke secret bootstrap, lalu menuliskannya ke `.odoo.secrets.env` agar user bisa langsung login ke `/web/login` tanpa menebak kredensial hasil restore.

Karena fase download dan bootstrap `fetch-start` tetap berjalan di shell aktif, **pastikan menjalankannya dari `tmux`** agar proses tidak mati saat SSH terputus.

Jika Anda ingin mengubah bind host secara eksplisit:

```bash
ODOO_HTTP_INTERFACE=10.20.30.40 ./setup_odoo.sh fetch-start 'URL_FOLDER_GDRIVE'
```

### B. Alur Cepat (Artefak Sudah Tersedia Secara Lokal)
Gunakan ini jika paket instalasi Odoo, custom addons, dan backup file database **sudah ada lokal** di folder proyek.

**Linux / macOS:**
```bash
cd /opt/odoo-cs
tmux new -s odoo
chmod +x setup_odoo.sh
./setup_odoo.sh bootstrap
```

**Windows (PowerShell):**
```powershell
.\setup_odoo.ps1 start
```

Script akan otomatis: mendeteksi OS, mendeteksi & ekstrak addons/backup database, men-setup PostgreSQL (`role` & `database`), melakukan _restore_, membuat file `odoo.conf`, dan menyalakan proses Odoo secara otomatis.

> 📝 **Catatan:** Untuk first deployment via SSH, `fetch-start` atau `bootstrap` lebih aman karena fase bootstrap berjalan interaktif di shell aktif. Gunakan `start` jika Anda memang ingin bootstrap detached dari awal dan user deploy Anda sudah siap untuk sudo non-interaktif.

> 📝 **Catatan:** Command `start`/`bootstrap` default-nya tetap bind ke `127.0.0.1:8069`. Khusus `fetch-start`, script otomatis expose ke jaringan agar bisa langsung diakses lewat IP server. File rahasia seperti konfigurasi password *master* dan password login browser akan digenerate otomatis ke file `.odoo.secrets.env` (Linux/Mac) atau `.odoo.secrets.ps1` (Windows).

### C. Memilih Command Yang Tepat

Gunakan command berikut sesuai kondisi:

| Command | Kapan Dipakai | Catatan |
|---|---|---|
| `./setup_odoo.sh fetch-start '<URL>'` | Artefak masih di Google Drive | Rekomendasi untuk VPS baru; jalankan dari `tmux`; Odoo start detached setelah bootstrap |
| `./setup_odoo.sh bootstrap` | Artefak sudah ada lokal | Bootstrap + start Odoo detached (background) |
| `./setup_odoo.sh foreground` | Artefak lokal, ingin foreground | Bootstrap + Odoo foreground (`Ctrl+C` untuk stop) |
| `./setup_odoo.sh start` | Ingin bootstrap detached di background | Cocok jika sudo non-interaktif sudah siap |
| `./setup_odoo.sh run -d <db>` | Menyalakan Odoo lagi dengan config terakhir | Tidak melakukan bootstrap ulang |

---

## 🛠 Operasional Harian

Setelah Odoo berhasil berjalan, Anda bisa menggunakan perintah-perintah *shortcut* berikut untuk me-manage operasional Odoo dari terminal:

| Perintah | Linux/macOS (`./setup_odoo.sh`) | Windows (`.\setup_odoo.ps1`) | Fungsi |
|----------|---|---|---|
| **`status`** | `./setup_odoo.sh status` | `.\setup_odoo.ps1 status` | Mengecek ketersediaan port Odoo dan PID proses. |
| **`stop`** | `./setup_odoo.sh stop` | `.\setup_odoo.ps1 stop` | Menghentikan service odoo dan mematikan bootstrap. |
| **`run`** | `./setup_odoo.sh run` | `.\setup_odoo.ps1 run` | Menyalakan ulang Odoo menggunakan konfigurasi terakhir. |
| **`logs`** | `./setup_odoo.sh logs` | `.\setup_odoo.ps1 logs` | Melihat progress/log *bootstrap* sistem Odoo realtime. |

---

## ⚙ Variabel Lingkungan (Environment Overrides)

Perilaku script sangat dinamis dan bisa diatur sepenuhnya melalui *Environment Variables*. Script juga membaca file `.env` di root proyek bila tersedia; environment variable dari shell tetap menang atas nilai di `.env`.
Contoh memaksa nama database khusus dan file backup spesifik di Linux:
```bash
DB_NAME=perusahaan_db BACKUP_INPUT="$PWD/backup-kemarin.zip" ./setup_odoo.sh start
```

**Variabel Penting yang Sering Digunakan:**
- `DB_NAME` (Default: `mkli_local`): Menentukan nama database PostgreSQL.
- `ODOO_HTTP_PORT` (Default: `8069`): Port HTTP untuk aplikasi Odoo.
- `ODOO_EXPOSE_HTTP` (Default: `0`): Jika `1` dan `ODOO_HTTP_INTERFACE` tidak diisi, Odoo bind ke `0.0.0.0`.
- `ODOO_WEB_LOGIN` (Default: auto): Login user Odoo yang akan dipilih/reset agar browser langsung bisa masuk.
- `ODOO_WEB_LOGIN_PASSWORD` (Default: auto): Password login browser yang dipersist ke `.odoo.secrets.env`.
- `ODOO_WEB_LOGIN_RESET` (Default: `1`): Jika `1`, password user browser-ready akan direset ke secret bootstrap.
- `BACKUP_INPUT` (Default: auto): Menggunakan spesifik file arsip database tertentu untuk proses restore.
- `RESTORE_MODE` (`required`, `auto`, `skip`): Menentukan seberapa wajib proses _restore_ ini diberlakukan.
- `FETCH_START_REQUIRE_ODOO`, `FETCH_START_REQUIRE_BACKUP`, `FETCH_START_REQUIRE_ADDONS` (Default: `1`): Fail-fast bila folder Google Drive tidak berisi artefak minimum agar hasil akhir benar-benar siap dipakai.
- `CUSTOM_ADDONS_ZIP_PATTERNS` (Default: `*addons*.zip`): Pola nama file regex untuk custom plugins Odoo.
- `ODOO_WORKERS` (Default: auto): Men-setting auto-tuning jumlah *worker* otomatis berdasar Core CPU & RAM.
- `ODOO_RUNTIME_AUTO_REPAIR` (Default: `1`): Menentukan apakah runtime preflight boleh memperbaiki dependency Python yang hilang sebelum Odoo dijalankan.

*(Gunakan `./setup_odoo.sh help` atau `.\setup_odoo.ps1 help` untuk melihat seluruh konfigurasi env yang didukung).*

---

## 🔧 Troubleshooting

Jika log Odoo menampilkan error berikut saat start:

```text
ImportError: lxml.html.clean module is now a separate project lxml_html_clean.
```

versi script ini akan melakukan preflight dependency sebelum Odoo dijalankan, baik saat bootstrap maupun `run`:
- Install source/tarball: memeriksa virtualenv Odoo, lalu menambahkan `lxml_html_clean` bila runtime belum memilikinya.
- Install `.deb`: membaca interpreter dari shebang `odoo` yang terpasang, mencoba `apt-get install python3-lxml-html-clean`, lalu fallback ke `python3 -m pip install lxml_html_clean` bila paket distro belum cukup.
- Repair dijalankan dengan retry agar lebih tahan terhadap apt/pip transient failure.
- Pada shell non-interaktif, script akan gagal cepat bila butuh `sudo` tetapi tidak bisa prompt, sehingga tidak menggantung diam-diam di background.

Jika Anda ingin mode strict tanpa auto-install saat runtime, jalankan:

```bash
ODOO_RUNTIME_AUTO_REPAIR=0 ./setup_odoo.sh run -d <nama_db>
```

Untuk host yang sudah telanjur terpasang sebelum perbaikan ini, jalankan bootstrap/install ulang atau pasang dependensinya manual lalu start ulang Odoo:

```bash
sudo apt-get install -y python3-lxml-html-clean || sudo python3 -m pip install --break-system-packages lxml_html_clean
./setup_odoo.sh run -d <nama_db>
```

Jika bootstrap/background log menampilkan error berikut:

```text
sudo: a terminal is required to read the password
sudo: a password is required
```

artinya provisioning PostgreSQL mencoba jalur `sudo` di shell non-interaktif. Gunakan salah satu opsi berikut:
- Jalankan bootstrap interaktif agar prompt password bisa muncul: `./setup_odoo.sh bootstrap`
- Jalankan sebagai `root` atau aktifkan passwordless sudo untuk user deploy
- Pakai koneksi admin PostgreSQL via TCP: `DB_PROVISION_METHOD=tcp DB_ADMIN_PASSWORD='<password-admin-postgres>' ./setup_odoo.sh start`

Mode `DB_PROVISION_METHOD=auto` sekarang akan mencoba fallback ke TCP bila `sudo` lokal tidak bisa dipakai tanpa TTY, tetapi fallback tersebut tetap membutuhkan kredensial admin PostgreSQL yang valid.

Jika log `apt` menampilkan pesan seperti berikut:

```text
N: Download is performed unsandboxed as root ... couldn't be accessed by user '_apt'
```

itu biasanya berarti Anda menjalankan proyek dari `/root/odoo-cs`. Install masih bisa lanjut, tetapi itu bukan layout yang direkomendasikan. Pindahkan workspace ke `/opt/odoo-cs`, lalu jalankan ulang bootstrap dari sana agar instalasi paket dan service runtime lebih bersih.

---

## 🧩 Arsitektur Internal & Keamanan

Script ini dibangun dengan standar perangkat lunak level _Enterprise_:
1. **Modular (lib/)**: Logika script dipecah ke 11 file spesifik (logging, platform, secrets, validation, restore, config, service, database, dll).
2. **Robust Rollback**: Memiliki mekanisme `.rollback` yang aman (segera membatalkan kegagalan restorasi database separuh jika interupsi fatal terjadi).
3. **Auto-Tuning Engine**: Menghitung limit memori Odoo secara dinamis (70% memori OS soft limit, 120% hard limit).
4. **Secret Management**: *Master password* dan password _Database_ Odoo dibuat otomatis 32-karakter dan dikunci dengan hak akses aman (`chmod 600`).

---

## 🧪 Pengujian Otomatis & CI/CD

Setup deployment diproteksi oleh integrasi uji tuntas (*Test Suite*) komprehensif.

### Bash (ShellCheck & BATS)
Menjalankan spesifikasi uji untuk ekosistem Linux/macOS:
```bash
./tests/run_tests.sh
```

### PowerShell (Pester)
Menjalankan spesifikasi uji lokal untuk ekosistem Windows:
```powershell
.\tests\run_tests.ps1
```

Workflow GitHub Actions (`.github/workflows/ci.yml`) siap memeriksa (lint) dan mengamankan (integration-test) repository ini ke `main` menggunakan *runner* multi-platform.
