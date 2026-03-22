# Script Setup Odoo 16.0e

> Deployment Odoo modular yang siap produksi untuk Linux, macOS, dan Windows.

Satu perintah untuk mengekstrak artefak, melakukan provisioning PostgreSQL, me-restore backup database, dan mengelola lifecycle service Odoo.

## Mulai Cepat

```bash
# Linux / macOS
chmod +x setup_odoo.sh
./setup_odoo.sh start

# Windows (PowerShell)
.\setup_odoo.ps1 start
```

## Prasyarat

| Platform | Kebutuhan |
|----------|-----------|
| **Ubuntu/Debian** | Akses `sudo`, `apt-get`, Python 3 |
| **macOS** | Homebrew, PostgreSQL 16, Python 3 |
| **Windows** | PowerShell 5.1+, PostgreSQL (bisa dipasang otomatis via winget) |

Letakkan salah satu artefak berikut di direktori yang sama dengan script:
- `odoo_*.tar.gz` — Tarball source Odoo (Linux/macOS)
- `odoo_*.deb` — Paket Debian (Ubuntu/Debian)
- `odoo_*.exe` — Installer Windows

## Arsitektur

```text
setup_odoo.sh          ← Dispatcher CLI tipis
├── lib/
│   ├── _bootstrap.sh  ← Loader modul (urut berdasarkan dependensi)
│   ├── logging.sh     ← Logging terstruktur (DEBUG/INFO/WARN/ERROR/FATAL)
│   ├── validation.sh  ← Validasi input dan sanitasi
│   ├── platform.sh    ← Deteksi OS, CPU, RAM, dan disk
│   ├── secrets.sh     ← Pembuatan dan penyimpanan secret secara aman
│   ├── database.sh    ← Manajemen role/database PostgreSQL dengan retry
│   ├── install.sh     ← Instalasi Odoo multi-mode
│   ├── restore.sh     ← Deteksi backup dan restore database
│   ├── config.sh      ← Pembuatan odoo.conf dengan auto-tuning
│   ├── service.sh     ← Lifecycle proses dan healthcheck
│   └── rollback.sh    ← Rollback otomatis saat bootstrap gagal
└── tests/             ← Unit test dan integration test berbasis BATS
```

## Perintah

| Perintah | Deskripsi |
|----------|-----------|
| `start` | Menjalankan bootstrap di background lalu menyalakan Odoo secara detached |
| `bootstrap` | Menjalankan bootstrap di shell aktif lalu menyalakan Odoo secara detached |
| `foreground` | Menjalankan bootstrap lalu menyalakan Odoo attached (cocok untuk Docker/systemd) |
| `run` | Menyalakan Odoo dengan konfigurasi terakhir yang sudah dibuat |
| `status` | Menampilkan status PID dan port |
| `logs` | Mengikuti log bootstrap |
| `stop` | Menghentikan proses Odoo dan bootstrap |
| `--version` | Menampilkan versi script |
| `help` | Menampilkan penggunaan lengkap |

## Variabel Environment

### Database

| Variabel | Default | Deskripsi |
|----------|---------|-----------|
| `DB_NAME` | `mkli_local` | Nama database target |
| `DB_USER` | `odoo` | Role PostgreSQL untuk Odoo |
| `DB_PASSWORD` | *(dibuat otomatis)* | Password role |
| `DB_HOST` | `127.0.0.1` | Host PostgreSQL |
| `DB_PORT` | `5432` | Port PostgreSQL |
| `DB_ADMIN_USER` | `postgres` | User admin untuk provisioning |
| `DB_ADMIN_PASSWORD` | *(kosong)* | Password user admin |
| `DB_ROLE_CAN_CREATEDB` | `1` | Mengizinkan role membuat database |
| `DB_ROLE_SUPERUSER` | `0` | Memberi hak superuser ke role |
| `DB_PROVISION_METHOD` | `auto` | `auto\|sudo\|tcp` |
| `DB_CONNECT_RETRIES` | `3` | Jumlah percobaan koneksi |
| `DB_CONNECT_RETRY_DELAY` | `5` | Jeda antar percobaan dalam detik |

### Odoo

| Variabel | Default | Deskripsi |
|----------|---------|-----------|
| `ODOO_HTTP_PORT` | `8069` | Port HTTP |
| `ODOO_GEVENT_PORT` | `8072` | Port gevent/longpolling |
| `ODOO_HTTP_INTERFACE` | `127.0.0.1` | Interface bind |
| `ODOO_ADMIN_PASSWD` | *(dibuat otomatis)* | Master password Odoo |
| `ODOO_WORKERS` | `auto` | Jumlah worker (auto-tuning) |
| `ODOO_PROXY_MODE` | `1` | Mengaktifkan proxy mode |
| `ODOO_LIST_DB` | `0` | Mengizinkan daftar database tampil |
| `ODOO_PACKAGE_SHA256` | *(kosong)* | Verifikasi checksum paket |

### Restore

| Variabel | Default | Deskripsi |
|----------|---------|-----------|
| `BACKUP_INPUT` | *(dideteksi otomatis)* | Path file atau direktori backup |
| `RESTORE_MODE` | `required` | `required\|auto\|skip` |
| `RESTORE_STRATEGY` | `refresh` | `refresh\|reuse\|fail` |
| `FILESTORE_STRATEGY` | `mirror` | `mirror\|merge\|skip` |
| `CUSTOM_ADDONS_DIR` | *(dideteksi otomatis)* | Path custom addons |
| `CUSTOM_ADDONS_ZIP_PATTERNS` | `*addons*.zip\|...` | Pola glob untuk zip addons |

### Logging dan Perilaku

| Variabel | Default | Deskripsi |
|----------|---------|-----------|
| `LOG_LEVEL` | `INFO` | `DEBUG\|INFO\|WARN\|ERROR` |
| `LOG_FORMAT` | `text` | `text\|json` |
| `MIN_FREE_GB` | `20` | Batas minimum ruang disk kosong |
| `HEALTHCHECK_TIMEOUT` | `120` | Waktu tunggu healthcheck dalam detik |
| `STOP_TIMEOUT` | `30` | Timeout graceful shutdown dalam detik |
| `DRY_RUN` | `0` | Mode pratinjau (belum diimplementasikan) |

## Fitur

### Logging Terstruktur

```bash
# Default: format terbaca manusia dengan timestamp
[2026-03-22T12:00:00+0700] [INFO] [setup-odoo] memulai bootstrap...

# Output JSON untuk log aggregator
LOG_FORMAT=json ./setup_odoo.sh start
```

### Validasi Input

Semua nilai konfigurasi divalidasi saat startup:
- Port: rentang 1–65535
- Boolean: harus `0` atau `1`
- Enum: dicek terhadap nilai yang diizinkan
- Nama DB: mengikuti aturan identifier PostgreSQL

### Mekanisme Rollback

Jika bootstrap gagal, aksi undo yang terdaftar dijalankan otomatis dalam urutan terbalik:
1. Trap `ERR` dan jalur fatal eksplisit sama-sama memicu rollback.
2. State rollback disimpan ke `.rollback/` untuk pemulihan setelah crash.
3. State rollback dibersihkan otomatis setelah bootstrap sukses.

### Manajemen Secret

- Membuat secret kriptografis 32 karakter secara otomatis
- Menyimpan ke `.odoo.secrets.env` dengan `chmod 600`
- Memvalidasi permission file sebelum memuat isi
- Memberi peringatan jika password kurang dari 16 karakter
- Override dari environment selalu diprioritaskan

### Auto-Tuning

Jumlah worker dan limit memori dihitung dari resource sistem:
- **Workers**: `min(cpu×2+1, ram_gb-1)`, minimal 2 (atau 0 jika RAM < 4GB)
- **Memory soft**: 70% dari total RAM, minimal 2GB
- **Memory hard**: 120% dari soft limit

### Provisioning Database yang Sadar Host

- `DB_PROVISION_METHOD=auto` hanya memakai `sudo` untuk PostgreSQL lokal
- Jika `DB_HOST` mengarah ke host remote, provisioning admin otomatis beralih ke koneksi TCP
- Jika `DB_HOST` berupa direktori socket Unix, script tetap dapat memakai jalur lokal

### Restore `refresh` yang Lebih Aman

- Strategy `refresh` me-restore dump ke database staging terlebih dulu
- Database target baru diganti setelah restore staging selesai
- Ini mencegah database aktif terhapus lebih awal saat dump ternyata rusak atau tidak lengkap

## Pengujian

```bash
# Pasang BATS
brew install bats-core        # macOS
sudo apt install bats         # Ubuntu

# Jalankan semua test
./tests/run_tests.sh

# Jalankan dengan output verbose
./tests/run_tests.sh --verbose
```

## CI/CD

Workflow GitHub Actions ada di `.github/workflows/ci.yml`:
- **Lint**: ShellCheck (bash), PSScriptAnalyzer (PowerShell)
- **Test**: BATS pada matriks Ubuntu + macOS
- **Trigger**: push ke `main`, pull request

## Lisensi

Untuk penggunaan internal. Lihat dokumentasi proyek untuk ketentuan lebih lanjut.
