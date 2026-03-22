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

## 🚀 Panduan Penggunaan

Pilih salah satu alur spesifik di bawah ini yang sesuai dengan kondisi server Anda:

### A. Alur Server Fresh (Semua Artefak dari Google Drive)
Jika Anda men-deploy ke VPS baru dan file masih tersimpan di Google Drive, Anda dapat menarik semuanya secara otomatis di *background*.

```bash
# 1. Clone repositori & masuk ke proyek (Gunakan root/sudo -i disarankan)
git clone https://github.com/kungfufafa/odoo-cs.git
cd odoo-cs

# 2. Download seluruh file instalasi (odoo, addons, database) dari GDrive
bash download_drive_folder.sh start 'URL_FOLDER_GDRIVE'

# 3. Pantau log download (Ctrl+C untuk keluar)
tail -f .logs/drive-folder-download.log

# 4. Setelah download selesai, eksekusi setup
chmod +x setup_odoo.sh
./setup_odoo.sh start
```

### B. Alur Cepat (Artefak Sudah Tersedia Secara Lokal)
Jika paket instalasi Odoo (`.deb`/`.tar.gz`/`.exe`), file custom addons, dan backup file database sudah ada sejajar dengan script ini.

**Linux / macOS:**
```bash
chmod +x setup_odoo.sh
./setup_odoo.sh start
```

**Windows (PowerShell):**
```powershell
.\setup_odoo.ps1 start
```

Script akan otomatis: mendeteksi OS, mendeteksi & ekstrak addons/backup database, men-setup PostgreSQL (`role` & `database`), melakukan _restore_, membuat file `odoo.conf`, dan menyalakan proses Odoo secara otomatis.

> 📝 **Catatan:** Setelah berhasil, Odoo dapat diakses pada `http://127.0.0.1:8069`. File rahasia seperti konfigurasi password *master* akan digenerate otomatis ke file `.odoo.secrets.env` (Linux/Mac) atau `.odoo.secrets.ps1` (Windows).

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

Perilaku script sangat dinamis dan bisa diatur sepenuhnya melalui *Environment Variables*. 
Contoh memaksa nama database khusus dan file backup spesifik di Linux:
```bash
DB_NAME=perusahaan_db BACKUP_INPUT="$PWD/backup-kemarin.zip" ./setup_odoo.sh start
```

**Variabel Penting yang Sering Digunakan:**
- `DB_NAME` (Default: `mkli_local`): Menentukan nama database PostgreSQL.
- `ODOO_HTTP_PORT` (Default: `8069`): Port HTTP untuk aplikasi Odoo.
- `BACKUP_INPUT` (Default: auto): Menggunakan spesifik file arsip database tertentu untuk proses restore.
- `RESTORE_MODE` (`required`, `auto`, `skip`): Menentukan seberapa wajib proses _restore_ ini diberlakukan.
- `CUSTOM_ADDONS_ZIP_PATTERNS` (Default: `*addons*.zip`): Pola nama file regex untuk custom plugins Odoo.
- `ODOO_WORKERS` (Default: auto): Men-setting auto-tuning jumlah *worker* otomatis berdasar Core CPU & RAM.

*(Gunakan `./setup_odoo.sh help` atau `.\setup_odoo.ps1 help` untuk melihat seluruh konfigurasi env yang didukung).*

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
